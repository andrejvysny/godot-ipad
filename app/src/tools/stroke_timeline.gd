class_name StrokeTimeline
extends RefCounted
## World-XZ stroke samples in time order, grouped into segments (spec §11.3, §12.1, §13.1).
## A segment is valid from its first sample until it is paused; an open segment holds its last
## position after its last sample (a stationary pencil keeps sculpting). Gaps between segments
## are never interpolated: a paused interval produces no brush work.
## Timestamps are seconds on the caller's clock and must be non-decreasing; earlier values are
## clamped to the last timestamp and counted in `clamped_count`.

var clamped_count: int = 0

var _t := PackedFloat64Array()
var _x := PackedFloat64Array()
var _z := PackedFloat64Array()
var _pf := PackedFloat64Array()
var _seg_first := PackedInt32Array()  # first sample index of each segment
var _seg_end := PackedFloat64Array()  # close time of each segment; INF while open


func sample_count() -> int:
	return _t.size()


func segment_count() -> int:
	return _seg_first.size()


func is_open() -> bool:
	return not _seg_end.is_empty() and _seg_end[_seg_end.size() - 1] == INF


func last_time() -> float:
	return _t[_t.size() - 1] if not _t.is_empty() else -INF


## Time up to which the timeline is complete: later input can only extend it past this point.
## The last sample of an open segment, or the close time of the last segment; -INF when empty.
func known_until() -> float:
	if _seg_end.is_empty():
		return -INF
	return last_time() if is_open() else _seg_end[_seg_end.size() - 1]


## Appends to the open segment; starts a new segment when none is open. Returns false when
## the timestamp had to be clamped.
func add_sample(t: float, pos: Vector2, pf: float) -> bool:
	if not is_open():
		return resume(t, pos, pf)
	var ok := _check_time(t)
	_append(maxf(t, last_time()), pos, pf)
	return ok


## Closes the open segment at `t` (tool pause or invalid terrain hit). No-op when paused.
func pause(t: float) -> bool:
	if not is_open():
		return true
	var ok := _check_time(t)
	_seg_end[_seg_end.size() - 1] = maxf(t, last_time())
	return ok


## Starts a new segment at `pos`; the gap since the previous segment is never bridged.
func resume(t: float, pos: Vector2, pf: float) -> bool:
	var ok := _check_time(t)
	var tc := maxf(t, last_time())
	if is_open():
		_seg_end[_seg_end.size() - 1] = tc
	_seg_first.append(_t.size())
	_seg_end.append(INF)
	_append(tc, pos, pf)
	return ok


## {valid, pos, pf}; invalid before the first sample and inside paused gaps.
func position_at(t: float) -> Dictionary:
	var s := _segment_at(t)
	if s < 0:
		return {"valid": false, "pos": Vector2(NAN, NAN), "pf": NAN}
	var i := _index_at(s, t)
	var p := _interp(s, i, t)
	return {"valid": true, "pos": Vector2(p[0], p[1]), "pf": p[2]}


## Sub-intervals of [t0, t1] covered by valid segment time, split at sample times:
## [{t_a, t_b, p_a, p_b, pf_a, pf_b}]. Zero-duration intervals are omitted.
func segments_between(t0: float, t1: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if t1 <= t0:
		return out
	for s in _seg_first.size():
		var first := _seg_first[s]
		var seg_start := _t[first]
		var a := maxf(t0, seg_start)
		var b := minf(t1, _seg_end[s])
		if b <= a:
			continue
		var j := _index_at(s, a)
		var last := _last_index(s)
		var ta := a
		var pa := _interp(s, j, a)
		while ta < b:
			var tb := b
			if j < last and _t[j + 1] < b:
				tb = _t[j + 1]
			var jb := _index_at(s, tb)
			var pb := _interp(s, jb, tb)
			if tb > ta:
				out.append({"t_a": ta, "t_b": tb, "p_a": Vector2(pa[0], pa[1]), "p_b": Vector2(pb[0], pb[1]),
						"pf_a": pa[2], "pf_b": pb[2]})
			ta = tb
			pa = pb
			j = jb
	return out


func _check_time(t: float) -> bool:
	if t < last_time():
		clamped_count += 1
		return false
	return true


func _append(t: float, pos: Vector2, pf: float) -> void:
	_t.append(t)
	_x.append(pos.x)
	_z.append(pos.y)
	_pf.append(pf)


func _last_index(s: int) -> int:
	return (_seg_first[s + 1] if s + 1 < _seg_first.size() else _t.size()) - 1


func _segment_at(t: float) -> int:
	for s in range(_seg_first.size() - 1, -1, -1):
		if t >= _t[_seg_first[s]]:
			return s if t <= _seg_end[s] else -1
	return -1


## Last sample index of segment `s` with time <= t (the latest of equal timestamps).
func _index_at(s: int, t: float) -> int:
	var i := _t.bsearch(t, false) - 1
	return clampi(i, _seg_first[s], _last_index(s))


## [x, z, pf] at time t given the segment's sample index i with _t[i] <= t.
func _interp(s: int, i: int, t: float) -> PackedFloat64Array:
	if i >= _last_index(s) or _t[i + 1] <= _t[i]:
		return PackedFloat64Array([_x[i], _z[i], _pf[i]])
	var u := clampf((t - _t[i]) / (_t[i + 1] - _t[i]), 0.0, 1.0)
	return PackedFloat64Array([lerpf(_x[i], _x[i + 1], u), lerpf(_z[i], _z[i + 1], u), lerpf(_pf[i], _pf[i + 1], u)])
