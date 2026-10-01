class_name BrushKernels
extends RefCounted
## Continuous-segment brush kernels operating on WorldDocument through an EditTransaction
## (spec §12, §13.1). Only existing global samples inside the capsule around the segment and
## inside the document layout's global sample range are visited; regions are never created.
## Each region map is captured once, immediately before its first changed sample.
## Results: {dirty_heights, dirty_controls, dirty_colors: Array[Vector2i], rect: Rect2,
## error: "" | "budget" | "invalid_input"}. `rect` is the world-XZ bounds of the changed samples
## grown by one SAMPLE_SPACING, so Rect2.has_point holds for every point whose bilinearly
## interpolated value changed (follow-terrain anchors, spec §13.4); empty when nothing changed.

const ERROR_BUDGET := "budget"
## Non-finite position, radius, strength or amount: nothing is written.
const ERROR_INVALID := "invalid_input"
const _U32 := 0xFFFFFFFF
const _EDGE_EPS := 1e-9


## Per-stroke paint working state. Coverage lives in separate float buffers (never in control
## bits); `start_control` / `start_color` are the stroke-start maps, so painting is a pure function
## of the maximum coverage and holding still never accumulates. `op` is one of OPS.
class PaintStrokeState extends RefCounted:
	const OPS: Array[String] = ["paint", "erase", "spray", "erase_spray", "tint", "untint"]
	const SPRAY_SCALE := 0.35
	const SPRAY_GAP_SCALE := 0.2

	var doc: WorldDocument
	var tx: EditTransaction
	var target_blend: float = 1.0
	var op := "paint"
	var layer := 1
	var tint_rgb := Vector3i(255, 255, 255)
	var shape := "soft"
	var alpha_mode := "circle"
	var seed := 0.0
	var angle := 0.0  # stamp direction of the latest segment
	var coverage: Dictionary = {}  # Vector2i -> PackedFloat32Array
	var start_control: Dictionary = {}  # Vector2i -> PackedInt32Array
	var start_color: Dictionary = {}  # Vector2i -> PackedByteArray

	func _init(p_doc: WorldDocument, p_tx: EditTransaction, p_target_blend: float) -> void:
		doc = p_doc
		tx = p_tx
		target_blend = clampf(p_target_blend, 0.0, 1.0)
		layer = 1 if target_blend >= 0.5 else 0

	func is_color() -> bool:
		return op == "tint" or op == "untint"

	## Lazily snapshots the region on first visit, before this stroke can have written it.
	func ensure_region(loc: Vector2i) -> void:
		if coverage.has(loc):
			return
		var buf := PackedFloat32Array()
		buf.resize(WorldConstants.REGION_SAMPLE_COUNT)
		coverage[loc] = buf
		if is_color():
			start_color[loc] = doc.get_region(loc).color.duplicate()
		else:
			start_control[loc] = doc.get_region(loc).control.duplicate()

	## Per-sample coverage multiplier: spray breaks coverage up by a per-stroke hash of the sample.
	func strength_mult(gx: int, gz: int) -> float:
		if op == "spray":
			var m := 1.0 if BrushAlpha.hash01(float(gx) + seed, float(gz) - seed) > 0.5 else SPRAY_GAP_SCALE
			return SPRAY_SCALE * m
		return SPRAY_SCALE if op == "erase_spray" else 1.0

	func control_value(before: int, cov: float) -> int:
		if op == "erase" or op == "erase_spray":
			return ControlCodec.erase_paint(before, cov)
		return ControlCodec.paint_layer(before, layer, cov)

	func color_value(before: int, cov: float) -> int:
		return TintCodec.tint(before, tint_rgb, cov) if op == "tint" else TintCodec.untint(before, cov)

	func clear() -> void:
		coverage = {}
		start_control = {}
		start_color = {}


static func empty_result() -> Dictionary:
	var dh: Array[Vector2i] = []
	var dc: Array[Vector2i] = []
	var dcol: Array[Vector2i] = []
	return {"dirty_heights": dh, "dirty_controls": dc, "dirty_colors": dcol, "rect": Rect2(), "error": ""}


## Merges kernel result `src` into `dst` (union of dirty regions, merged rect, first error).
static func merge_result(dst: Dictionary, src: Dictionary) -> void:
	if _has_rect(src):
		var r: Rect2 = src.rect
		dst.rect = (dst.rect as Rect2).merge(r) if _has_rect(dst) else r
	for key in ["dirty_heights", "dirty_controls", "dirty_colors"]:
		var into: Array[Vector2i] = dst[key]
		for loc: Vector2i in src[key]:
			if not into.has(loc):
				into.append(loc)
	if dst.error == "" and src.error != "":
		dst.error = src.error


static func _has_rect(res: Dictionary) -> bool:
	return not (res.dirty_heights as Array).is_empty() or not (res.dirty_controls as Array).is_empty() \
			or not (res.dirty_colors as Array).is_empty()


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
	var geo := Capsule.new(p_a, p_b, radius, doc.layout)
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


## Coverage-max paint of the segment a-b (PaintKernels): see there for the alpha handling.
static func paint_segment(state: PaintStrokeState, p_a: Vector2, p_b: Vector2, radius: float,
		strength: float, pf_a: float, pf_b: float) -> Dictionary:
	return PaintKernels.paint_segment(state, p_a, p_b, radius, strength, pf_a, pf_b)


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
	var sample_min: Vector2i  # layout clip range, global samples (x = X axis, y = Z axis)
	var sample_max: Vector2i
	var ux := 1.0  # unit direction a->b; arbitrary (+X) for a point dab, where length == 0
	var uz := 0.0

	func _init(a: Vector2, b: Vector2, radius: float, layout: WorldLayout) -> void:
		sample_min = layout.global_sample_min()
		sample_max = layout.global_sample_max()
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
		return Vector2i(maxi(lo, sample_min.y), mini(hi, sample_max.y))

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
		var g0 := maxi(ceili(lo / sp - BrushKernels._EDGE_EPS), sample_min.x)
		var g1 := mini(floori(hi / sp + BrushKernels._EDGE_EPS), sample_max.x)
		return Vector2i(g0, g1)

	## Solutions t of lo <= k * t + c <= hi as [min, max]; [INF, -INF] when none.
	static func _linear_interval(k: float, c: float, lo: float, hi: float) -> PackedFloat64Array:
		if absf(k) < 1e-12:
			return PackedFloat64Array([-INF, INF] if c >= lo and c <= hi else [INF, -INF])
		var t0 := (lo - c) / k
		var t1 := (hi - c) / k
		return PackedFloat64Array([minf(t0, t1), maxf(t0, t1)])
