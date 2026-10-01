class_name BrushKernels
extends RefCounted
## Continuous-segment brush kernels operating on WorldDocument through an EditTransaction
## (spec §12, §13.1). Only existing global samples inside the capsule around the segment and
## inside [GLOBAL_SAMPLE_MIN, GLOBAL_SAMPLE_MAX] are visited; regions are never created.
## Each region map is captured once, immediately before its first changed sample.
## Results: {dirty_heights: Array[Vector2i], dirty_controls: Array[Vector2i], rect: Rect2,
## error: "" | "budget" | "invalid_input"}. `rect` is the world-XZ bounds of the changed samples
## grown by one SAMPLE_SPACING, so Rect2.has_point holds for every point whose bilinearly
## interpolated value changed (follow-terrain anchors, spec §13.4); empty when nothing changed.

const ERROR_BUDGET := "budget"
## Non-finite position, radius, strength or amount: nothing is written.
const ERROR_INVALID := "invalid_input"
const _U32 := 0xFFFFFFFF
const _EDGE_EPS := 1e-9


## Per-stroke paint working state. Coverage lives in separate float buffers (never in control
## bits); `start_control` is the stroke-start map, so painting is a pure function of the
## maximum coverage and holding still never accumulates.
class PaintStrokeState extends RefCounted:
	var doc: WorldDocument
	var tx: EditTransaction
	var target_blend: float = 1.0
	var coverage: Dictionary = {}  # Vector2i -> PackedFloat32Array
	var start_control: Dictionary = {}  # Vector2i -> PackedInt32Array

	func _init(p_doc: WorldDocument, p_tx: EditTransaction, p_target_blend: float) -> void:
		doc = p_doc
		tx = p_tx
		target_blend = clampf(p_target_blend, 0.0, 1.0)

	## Lazily snapshots the region on first visit, before this stroke can have written it.
	func ensure_region(loc: Vector2i) -> void:
		if coverage.has(loc):
			return
		var buf := PackedFloat32Array()
		buf.resize(WorldConstants.REGION_SAMPLE_COUNT)
		coverage[loc] = buf
		start_control[loc] = doc.get_region(loc).control.duplicate()

	func clear() -> void:
		coverage = {}
		start_control = {}


static func empty_result() -> Dictionary:
	var dh: Array[Vector2i] = []
	var dc: Array[Vector2i] = []
	return {"dirty_heights": dh, "dirty_controls": dc, "rect": Rect2(), "error": ""}


## Merges kernel result `src` into `dst` (union of dirty regions, merged rect, first error).
static func merge_result(dst: Dictionary, src: Dictionary) -> void:
	if _has_rect(src):
		var r: Rect2 = src.rect
		dst.rect = (dst.rect as Rect2).merge(r) if _has_rect(dst) else r
	for key in ["dirty_heights", "dirty_controls"]:
		var into: Array[Vector2i] = dst[key]
		for loc: Vector2i in src[key]:
			if not into.has(loc):
				into.append(loc)
	if dst.error == "" and src.error != "":
		dst.error = src.error


static func _has_rect(res: Dictionary) -> bool:
	return not (res.dirty_heights as Array).is_empty() or not (res.dirty_controls as Array).is_empty()


## Raises (height_rate > 0) or lowers every sample within `radius` of segment a-b by
## height_rate * strength * pf_avg * dt * mean falloff along the segment.
static func sculpt_segment(doc: WorldDocument, tx: EditTransaction, p_a: Vector2, p_b: Vector2,
		radius: float, height_rate: float, strength: float, pf_avg: float, dt: float) -> Dictionary:
	var res := empty_result()
	var amount := height_rate * strength * pf_avg * dt
	if not (is_finite(amount) and is_finite(radius) and p_a.is_finite() and p_b.is_finite()):
		res.error = ERROR_INVALID
		return res
	if amount == 0.0 or radius <= 0.0:
		return res
	var geo := Capsule.new(p_a, p_b, radius)
	var bounds := geo.row_range()
	var dirty: Array[Vector2i] = res.dirty_heights
	var ext := _new_extent()
	var sp := WorldConstants.SAMPLE_SPACING
	var hmin := WorldConstants.HEIGHT_MIN
	var hmax := WorldConstants.HEIGHT_MAX
	var ax := geo.ax
	var az := geo.az
	var ux := geo.ux
	var uz := geo.uz
	var seg_len := geo.length
	for gz in range(bounds.x, bounds.y + 1):
		var z := gz * sp
		var span := geo.row_span(z)
		var row := (gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES
		var rz := z - az
		var gx := span.x
		while gx <= span.y:
			var loc := Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT)
			var gx_end := mini(span.y, (loc.x << WorldConstants.REGION_SHIFT) + WorldConstants.REGION_MASK)
			var region := doc.get_region(loc)
			if region == null:
				gx = gx_end + 1
				continue
			var heights: PackedFloat32Array = region.heights
			var ready := tx.has_captured_heights(loc)
			var wrote := false
			var g_lo := 0
			var g_hi := 0
			for g in range(gx, gx_end + 1):
				var rx := g * sp - ax
				var along := rx * ux + rz * uz
				var perp := rz * ux - rx * uz
				var f := BrushMath.integrated_falloff(perp * perp, along, seg_len, radius)
				if f <= 0.0:
					continue
				var i := row + (g & WorldConstants.REGION_MASK)
				var old := heights[i]
				var nv := clampf(old + amount * f, hmin, hmax)
				if nv == old:
					continue
				if not ready:
					if not tx.capture_heights(loc):
						res.error = ERROR_BUDGET
						res.rect = _extent_rect(ext)
						return res
					ready = true
				heights[i] = nv
				if not wrote:
					g_lo = g
				g_hi = g
				wrote = true
			if wrote:
				_mark(dirty, ext, loc, g_lo, g_hi, gz)
				doc.invalidate_height_range(loc)
			gx = gx_end + 1
	res.rect = _extent_rect(ext)
	return res


## Coverage-max paint of the segment a-b into the stroke's working buffers: the continuous limit
## of dabs along the segment with the pressure factor interpolated linearly from pf_a to pf_b.
## The "path" falloff evaluates the pressure factor at the closest point, which is exact only for
## a constant factor; PaintStroke always passes a constant one (pressure is off for paths, §15.5).
static func paint_segment(state: PaintStrokeState, p_a: Vector2, p_b: Vector2, radius: float,
		strength: float, pf_a: float, pf_b: float, falloff_kind: String) -> Dictionary:
	var res := empty_result()
	if not (is_finite(strength) and is_finite(radius) and is_finite(pf_a) and is_finite(pf_b)
			and p_a.is_finite() and p_b.is_finite()):
		res.error = ERROR_INVALID
		return res
	if strength <= 0.0 or radius <= 0.0:
		return res
	var use_path := falloff_kind == "path"
	var geo := Capsule.new(p_a, p_b, radius)
	var bounds := geo.row_range()
	var dirty: Array[Vector2i] = res.dirty_controls
	var ext := _new_extent()
	var sp := WorldConstants.SAMPLE_SPACING
	var r2 := radius * radius
	var inv_r := 1.0 / radius
	var target := state.target_blend
	var ax := geo.ax
	var az := geo.az
	var ux := geo.ux
	var uz := geo.uz
	var seg_len := geo.length
	var inv_len := 1.0 / seg_len if seg_len >= BrushMath.MIN_SEGMENT_LENGTH else 0.0
	var varying_pf := pf_a != pf_b and seg_len > 0.0
	var pf_max := maxf(pf_a, pf_b)
	for gz in range(bounds.x, bounds.y + 1):
		var z := gz * sp
		var span := geo.row_span(z)
		var row := (gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES
		var rz := z - az
		var gx := span.x
		while gx <= span.y:
			var loc := Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT)
			var gx_end := mini(span.y, (loc.x << WorldConstants.REGION_SHIFT) + WorldConstants.REGION_MASK)
			var region := state.doc.get_region(loc)
			if region == null:
				gx = gx_end + 1
				continue
			state.ensure_region(loc)
			var cov_buf: PackedFloat32Array = state.coverage[loc]
			var start: PackedInt32Array = state.start_control[loc]
			var ctrl: PackedInt32Array = region.control
			var ready := state.tx.has_captured_controls(loc)
			var wrote := false
			var g_lo := 0
			var g_hi := 0
			for g in range(gx, gx_end + 1):
				var rx := g * sp - ax
				var along_raw := rx * ux + rz * uz
				var perp := rz * ux - rx * uz
				var along := clampf(along_raw, 0.0, seg_len)
				var d2 := perp * perp + (along_raw - along) * (along_raw - along)
				if d2 >= r2:
					continue
				var q := sqrt(d2) * inv_r
				var i := row + (g & WorldConstants.REGION_MASK)
				var cov: float
				if use_path or not varying_pf:
					var f := BrushMath.path_falloff(q) if use_path else BrushMath.falloff(q)
					cov = strength * lerpf(pf_a, pf_b, along * inv_len) * f
				else:
					# The closest point maximises falloff, so pf_max * falloff bounds the true max.
					if strength * pf_max * BrushMath.falloff(q) <= cov_buf[i]:
						continue
					cov = strength * BrushMath.max_weighted_falloff(perp * perp, along_raw, seg_len, radius, pf_a, pf_b)
				if cov <= cov_buf[i]:
					continue
				cov_buf[i] = cov
				cov = cov_buf[i]  # blend is a function of the stored (float32) coverage only
				var before := start[i] & _U32
				var bb := ControlCodec.dirt_blend01(before)
				var nv := ControlCodec.encode_paint(before, ControlCodec.quantize_blend(bb + (target - bb) * cov))
				if nv == (ctrl[i] & _U32):
					continue
				if not ready:
					if not state.tx.capture_controls(loc):
						res.error = ERROR_BUDGET
						res.rect = _extent_rect(ext)
						return res
					ready = true
				ctrl[i] = nv
				if not wrote:
					g_lo = g
				g_hi = g
				wrote = true
			if wrote:
				_mark(dirty, ext, loc, g_lo, g_hi, gz)
			gx = gx_end + 1
	res.rect = _extent_rect(ext)
	return res


## Tracks changed samples as [gx_min, gx_max, gz_min, gz_max] in `ext` and the dirty region list.
static func _mark(dirty: Array[Vector2i], ext: PackedInt32Array, loc: Vector2i, gx0: int, gx1: int, gz: int) -> void:
	if not dirty.has(loc):
		dirty.append(loc)
	ext[0] = mini(ext[0], gx0)
	ext[1] = maxi(ext[1], gx1)
	ext[2] = mini(ext[2], gz)
	ext[3] = maxi(ext[3], gz)


static func _new_extent() -> PackedInt32Array:
	return PackedInt32Array([1 << 30, -(1 << 30), 1 << 30, -(1 << 30)])


static func _extent_rect(ext: PackedInt32Array) -> Rect2:
	if ext[0] > ext[1]:
		return Rect2()
	var sp := WorldConstants.SAMPLE_SPACING
	return Rect2((ext[0] - 1) * sp, (ext[2] - 1) * sp, (ext[1] - ext[0] + 2) * sp, (ext[3] - ext[2] + 2) * sp)


## Capsule geometry (segment a-b dilated by radius) and its exact per-row X extent.
class Capsule extends RefCounted:
	var ax: float
	var az: float
	var bx: float
	var bz: float
	var r: float
	var length: float
	var ux := 1.0  # unit direction a->b; arbitrary (+X) for a point dab, where length == 0
	var uz := 0.0

	func _init(a: Vector2, b: Vector2, radius: float) -> void:
		ax = a.x
		az = a.y
		bx = b.x
		bz = b.y
		r = radius
		length = sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
		if length >= BrushMath.MIN_SEGMENT_LENGTH:
			ux = (bx - ax) / length
			uz = (bz - az) / length
		else:
			length = 0.0

	## Global sample rows (min, max) clipped to the world; min > max when empty.
	func row_range() -> Vector2i:
		var sp := WorldConstants.SAMPLE_SPACING
		var lo := ceili((minf(az, bz) - r) / sp - BrushKernels._EDGE_EPS)
		var hi := floori((maxf(az, bz) + r) / sp + BrushKernels._EDGE_EPS)
		return Vector2i(maxi(lo, WorldConstants.GLOBAL_SAMPLE_MIN), mini(hi, WorldConstants.GLOBAL_SAMPLE_MAX))

	## Global sample columns (min, max) of the row at world z, clipped; min > max when empty.
	## The capsule is convex, so the union of both end discs and the side band is one interval.
	func row_span(z: float) -> Vector2i:
		var lo := INF
		var hi := -INF
		var r2 := r * r
		var dza := z - az
		if dza * dza < r2:
			var wa := sqrt(r2 - dza * dza)
			lo = ax - wa
			hi = ax + wa
		var dzb := z - bz
		if dzb * dzb < r2:
			var wb := sqrt(r2 - dzb * dzb)
			lo = minf(lo, bx - wb)
			hi = maxf(hi, bx + wb)
		if length > 0.0:
			# along(x) = (x - ax) * ux + dza * uz in [0, L]; perp(x) = dza * ux - (x - ax) * uz in [-r, r]
			var s1 := _linear_interval(ux, dza * uz, 0.0, length)
			var s2 := _linear_interval(-uz, dza * ux, -r, r)
			var blo := maxf(s1[0], s2[0])
			var bhi := minf(s1[1], s2[1])
			if blo <= bhi:
				lo = minf(lo, ax + blo)
				hi = maxf(hi, ax + bhi)
		if lo > hi:
			return Vector2i(1, 0)
		var sp := WorldConstants.SAMPLE_SPACING
		var g0 := maxi(ceili(lo / sp - BrushKernels._EDGE_EPS), WorldConstants.GLOBAL_SAMPLE_MIN)
		var g1 := mini(floori(hi / sp + BrushKernels._EDGE_EPS), WorldConstants.GLOBAL_SAMPLE_MAX)
		return Vector2i(g0, g1)

	## Solutions t of lo <= k * t + c <= hi as [min, max]; [INF, -INF] when none.
	static func _linear_interval(k: float, c: float, lo: float, hi: float) -> PackedFloat64Array:
		if absf(k) < 1e-12:
			return PackedFloat64Array([-INF, INF] if c >= lo and c <= hi else [INF, -INF])
		var t0 := (lo - c) / k
		var t1 := (hi - c) / k
		return PackedFloat64Array([minf(t0, t1), maxf(t0, t1)])
