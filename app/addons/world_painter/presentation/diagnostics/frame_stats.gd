class_name FrameStats
extends RefCounted
## Ring buffer of frame intervals plus named timing samples (spec §18.1, §18.3).

var _capacity: int
var _frames := PackedFloat64Array()
var _next := 0
var _timers: Dictionary = {}  ## name -> {"buf": PackedFloat64Array, "next": int}
var _open: Dictionary = {}  ## name -> start usec


func _init(capacity: int = 600) -> void:
	_capacity = maxi(capacity, 1)


func add(interval_ms: float) -> void:
	_push(_frames, _next, interval_ms)
	_next = (_next + 1) % _capacity


func _push(buf: PackedFloat64Array, idx: int, v: float) -> void:
	if buf.size() < _capacity:
		buf.append(v)
	else:
		buf[idx] = v


func count() -> int:
	return _frames.size()


## Nearest-rank percentile, q in [0, 1]; 0 when empty.
static func percentile(data: PackedFloat64Array, q: float) -> float:
	if data.is_empty():
		return 0.0
	var s := data.duplicate()
	s.sort()
	var rank := clampi(ceili(q * s.size()) - 1, 0, s.size() - 1)
	return s[rank]


func p50() -> float:
	return percentile(_frames, 0.5)


func p95() -> float:
	return percentile(_frames, 0.95)


func p99() -> float:
	return percentile(_frames, 0.99)


func max_ms() -> float:
	var m := 0.0
	for v in _frames:
		m = maxf(m, v)
	return m


func count_over(ms: float) -> int:
	var n := 0
	for v in _frames:
		if v > ms:
			n += 1
	return n


func add_sample(sample_name: String, ms: float) -> void:
	if not _timers.has(sample_name):
		_timers[sample_name] = {"buf": PackedFloat64Array(), "next": 0}
	var t: Dictionary = _timers[sample_name]
	var buf: PackedFloat64Array = t["buf"]
	var idx: int = t["next"]
	_push(buf, idx, ms)
	t["buf"] = buf
	t["next"] = (idx + 1) % _capacity


func begin_sample(sample_name: String) -> void:
	_open[sample_name] = Time.get_ticks_usec()


func end_sample(sample_name: String) -> void:
	if not _open.has(sample_name):
		return
	var start: int = _open[sample_name]
	_open.erase(sample_name)
	add_sample(sample_name, float(Time.get_ticks_usec() - start) / 1000.0)


func sample_p95(sample_name: String) -> float:
	if not _timers.has(sample_name):
		return 0.0
	return percentile(_timers[sample_name]["buf"], 0.95)


func snapshot() -> Dictionary:
	var timers := {}
	for n: String in _timers:
		timers[n] = {"count": (_timers[n]["buf"] as PackedFloat64Array).size(), "p95_ms": sample_p95(n)}
	return {
		"frames": count(), "p50_ms": p50(), "p95_ms": p95(), "p99_ms": p99(), "max_ms": max_ms(),
		"over_16_7": count_over(16.7), "over_33_4": count_over(33.4), "timers": timers,
	}
