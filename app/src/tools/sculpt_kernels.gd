class_name SculptKernels
extends RefCounted
## Sculpt-family kernels for any alpha (docs/editor-v2.md §3, §5). One piece = one stroke
## segment over `dt`. Each visited sample gets W = mean alpha weight over the segment: the exact
## continuous integral for soft + circle, otherwise the mean over discrete dabs, which splits the
## amount evenly over the dabs. All kinds are linear or exponential in W, so dab order never matters.
## Heights are clamped, captured before the first write, and regions are never created.

const FLATTEN_K := 4.0
const NOISE_RATE_M_PER_S := 1.5
const NOISE_FREQ := 0.35
const SMOOTH_FACTOR := 6.0
const _NEIGHBORS: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]


## One segment's geometry, alpha and per-kind gain. `gain` is height_rate * strength * pf * dt for
## raise (signed) and strength * pf * dt for flatten, noise and smooth.
class Piece extends RefCounted:
	var kind: String
	var geo: BrushKernels.Capsule
	var radius: float
	var shape: String
	var alpha_mode: String
	var angle: float
	var gain := 0.0
	var dt := 0.0
	var target := 0.0
	var exact: bool
	var finite: bool
	var dab_pos := PackedVector2Array()

	func _init(p_kind: String, a: Vector2, b: Vector2, p_radius: float, p_shape: String, p_mode: String,
			p_angle: float) -> void:
		kind = p_kind
		radius = p_radius
		shape = p_shape
		alpha_mode = p_mode
		angle = p_angle
		finite = a.is_finite() and b.is_finite() and is_finite(p_radius)
		geo = BrushKernels.Capsule.new(a, b, p_radius)
		exact = BrushAlpha.is_exact_soft(shape, alpha_mode)
		if not exact:
			dab_pos = BrushDabs.centers(a, b, BrushDabs.count(geo.length, radius))

	func weight(x: float, z: float) -> float:
		if not exact:
			return BrushDabs.mean_weight(shape, alpha_mode, x, z, dab_pos, radius, angle)
		var rx := x - geo.ax
		var rz := z - geo.az
		var along := rx * geo.ux + rz * geo.uz
		var perp := rz * geo.ux - rx * geo.uz
		return BrushMath.integrated_falloff(perp * perp, along, geo.length, radius)


## `snaps` (Vector2i -> PackedFloat32Array) holds the pre-step heights smooth reads; the caller
## passes one dictionary per fixed step so pieces of a step share it.
static func sculpt_piece(doc: WorldDocument, tx: EditTransaction, p: Piece, snaps: Dictionary) -> Dictionary:
	var res := BrushKernels.empty_result()
	if not (p.finite and is_finite(p.gain) and is_finite(p.target)):
		res.error = BrushKernels.ERROR_INVALID
		return res
	if p.gain == 0.0 or p.radius <= 0.0:
		return res
	var bounds := p.geo.row_range()
	var ext := BrushKernels._new_extent()
	var sp := WorldConstants.SAMPLE_SPACING
	for gz in range(bounds.x, bounds.y + 1):
		var span := p.geo.row_span(gz * sp)
		var gx := span.x
		while gx <= span.y:
			var loc := Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT)
			var gx_end := mini(span.y, (loc.x << WorldConstants.REGION_SHIFT) + WorldConstants.REGION_MASK)
			if doc.get_region(loc) != null and not _span(doc, tx, p, snaps, loc, gx, gx_end, gz, res, ext):
				break
			gx = gx_end + 1
		if res.error != "":
			break
	res.rect = BrushKernels._extent_rect(ext)
	return res


static func _span(doc: WorldDocument, tx: EditTransaction, p: Piece, snaps: Dictionary, loc: Vector2i,
		gx0: int, gx1: int, gz: int, res: Dictionary, ext: PackedInt32Array) -> bool:
	var heights: PackedFloat32Array = doc.get_region(loc).heights
	if p.kind == "smooth":
		_snapshot(doc, snaps, loc)  # before this step writes the region
	var row := (gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES
	var z := gz * WorldConstants.SAMPLE_SPACING
	var lo := 0
	var hi := 0
	var wrote := false
	for g in range(gx0, gx1 + 1):
		var w := p.weight(g * WorldConstants.SAMPLE_SPACING, z)
		if w <= 0.0:
			continue
		var i := row + (g & WorldConstants.REGION_MASK)
		var old := heights[i]
		var nv := clampf(_next_height(doc, snaps, p, g, gz, old, w), WorldConstants.HEIGHT_MIN, WorldConstants.HEIGHT_MAX)
		if nv == old or is_nan(nv):
			continue
		if not tx.capture_heights(loc):
			res.error = BrushKernels.ERROR_BUDGET
			break
		heights[i] = nv
		if not wrote:
			lo = g
		hi = g
		wrote = true
	if wrote:
		BrushKernels._mark(res.dirty_heights, ext, loc, lo, hi, gz)
		doc.invalidate_height_range(loc)
	return res.error == ""


static func _next_height(doc: WorldDocument, snaps: Dictionary, p: Piece, gx: int, gz: int, old: float, w: float) -> float:
	match p.kind:
		"flatten":
			return old + (p.target - old) * (1.0 - exp(-FLATTEN_K * p.gain * w))
		"noise":
			var n := BrushAlpha.value_noise(float(gx) * NOISE_FREQ, float(gz) * NOISE_FREQ)
			return old + (n - 0.5) * 2.0 * NOISE_RATE_M_PER_S * p.gain * w
		"smooth":
			var avg := _neighbor_mean(doc, snaps, gx, gz)
			return old if is_nan(avg) else old + (avg - old) * minf(1.0, SMOOTH_FACTOR * p.gain * w)
	return old + p.gain * w


## Mean of the existing 4-neighbours in the pre-step snapshot (across region seams); NAN if none.
static func _neighbor_mean(doc: WorldDocument, snaps: Dictionary, gx: int, gz: int) -> float:
	var sum := 0.0
	var count := 0
	for d in _NEIGHBORS:
		var h := _snap_height(doc, snaps, gx + d.x, gz + d.y)
		if not is_nan(h):
			sum += h
			count += 1
	return sum / float(count) if count > 0 else NAN


static func _snap_height(doc: WorldDocument, snaps: Dictionary, gx: int, gz: int) -> float:
	var snap := _snapshot(doc, snaps, Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT))
	if snap.is_empty():
		return NAN
	return snap[(gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES + (gx & WorldConstants.REGION_MASK)]


## Pre-step copy of a region's heights; empty when the region does not exist.
static func _snapshot(doc: WorldDocument, snaps: Dictionary, loc: Vector2i) -> PackedFloat32Array:
	if snaps.has(loc):
		return snaps[loc]
	var region := doc.get_region(loc)
	if region == null:
		return PackedFloat32Array()
	var copy := region.heights.duplicate()
	snaps[loc] = copy
	return copy
