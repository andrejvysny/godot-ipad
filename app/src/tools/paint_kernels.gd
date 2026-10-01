class_name PaintKernels
extends RefCounted
## Paint-family kernels (docs/editor-v2.md §3, §4): coverage-max strokes into the stroke's working
## buffers, written to the control map or the tint map through the state's op. soft + circle keeps
## the exact continuous capsule coverage (BrushMath); every other alpha uses discrete dabs along
## the segment with coverage = max over dabs of strength * pf * alpha. Regions are never created.

## Coverage that rounds to zero in a byte writes nothing, so rim samples keep their exact bytes.
const MIN_VISIBLE_COVERAGE := 0.5 / 255.0
const _CHANGED := 1
const _UNCHANGED := 0
const _BUDGET := -1


## Per-call constants and the coverage function of one segment.
class Job extends RefCounted:
	var state: BrushKernels.PaintStrokeState
	var geo: BrushKernels.Capsule
	var radius: float
	var strength: float
	var pf_a: float
	var pf_b: float
	var use_path: bool
	var exact: bool
	var varying_pf: bool
	var pf_max: float
	var inv_r: float
	var inv_len: float
	var dab_pos := PackedVector2Array()
	var dab_pf := PackedFloat32Array()

	func _init(p_state: BrushKernels.PaintStrokeState, a: Vector2, b: Vector2, p_radius: float,
			p_strength: float, p_pf_a: float, p_pf_b: float, falloff_kind: String) -> void:
		state = p_state
		radius = p_radius
		strength = p_strength
		pf_a = p_pf_a
		pf_b = p_pf_b
		use_path = falloff_kind == "path"
		geo = BrushKernels.Capsule.new(a, b, p_radius)
		inv_r = 1.0 / p_radius
		inv_len = 1.0 / geo.length if geo.length >= BrushMath.MIN_SEGMENT_LENGTH else 0.0
		varying_pf = pf_a != pf_b and geo.length > 0.0
		pf_max = maxf(pf_a, pf_b)
		exact = use_path or BrushAlpha.is_exact_soft(state.shape, state.alpha_mode)
		if not exact:
			var n := BrushDabs.count(geo.length, radius)
			dab_pos = BrushDabs.centers(a, b, n)
			dab_pf.resize(n)
			for i in n:
				dab_pf[i] = lerpf(pf_a, pf_b, float(i) / float(n - 1)) if n > 1 else pf_a

	## Coverage at world point (x, z); `mult` scales strength; `floor_cov` lets the pressure-varying
	## continuous branch bail out early when it cannot beat the stored coverage.
	func coverage(x: float, z: float, mult: float, floor_cov: float) -> float:
		if exact:
			return _exact(x, z, mult, floor_cov)
		var best := 0.0
		var r2 := radius * radius
		var s := strength * mult
		for i in dab_pos.size():
			var c := dab_pos[i]
			var dx := x - c.x
			var dz := z - c.y
			if dx * dx + dz * dz >= r2:
				continue
			var w := BrushAlpha.weight(state.shape, state.alpha_mode, x, z, c, radius, state.angle)
			best = maxf(best, s * dab_pf[i] * w)
		return best

	func _exact(x: float, z: float, mult: float, floor_cov: float) -> float:
		var rx := x - geo.ax
		var rz := z - geo.az
		var along_raw := rx * geo.ux + rz * geo.uz
		var perp := rz * geo.ux - rx * geo.uz
		var along := clampf(along_raw, 0.0, geo.length)
		var d2 := perp * perp + (along_raw - along) * (along_raw - along)
		if d2 >= radius * radius:
			return 0.0
		var q := sqrt(d2) * inv_r
		var s := strength * mult
		if use_path or not varying_pf:
			var f := BrushMath.path_falloff(q) if use_path else BrushMath.falloff(q)
			return s * lerpf(pf_a, pf_b, along * inv_len) * f
		# The closest point maximises falloff, so pf_max * falloff bounds the true max.
		if s * pf_max * BrushMath.falloff(q) <= floor_cov:
			return 0.0
		return s * BrushMath.max_weighted_falloff(perp * perp, along_raw, geo.length, radius, pf_a, pf_b)


static func paint_segment(state: BrushKernels.PaintStrokeState, p_a: Vector2, p_b: Vector2, radius: float,
		strength: float, pf_a: float, pf_b: float, falloff_kind: String) -> Dictionary:
	var res := BrushKernels.empty_result()
	if not (is_finite(strength) and is_finite(radius) and is_finite(pf_a) and is_finite(pf_b)
			and p_a.is_finite() and p_b.is_finite()):
		res.error = BrushKernels.ERROR_INVALID
		return res
	if strength <= 0.0 or radius <= 0.0:
		return res
	state.angle = BrushDabs.segment_angle(p_a, p_b, state.angle)
	var job := Job.new(state, p_a, p_b, radius, strength, pf_a, pf_b, falloff_kind)
	var bounds := job.geo.row_range()
	var ext := BrushKernels._new_extent()
	var sp := WorldConstants.SAMPLE_SPACING
	for gz in range(bounds.x, bounds.y + 1):
		var span := job.geo.row_span(gz * sp)
		var gx := span.x
		while gx <= span.y:
			var loc := Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT)
			var gx_end := mini(span.y, (loc.x << WorldConstants.REGION_SHIFT) + WorldConstants.REGION_MASK)
			if state.doc.get_region(loc) != null and not _span(job, loc, gx, gx_end, gz, res, ext):
				break
			gx = gx_end + 1
		if res.error != "":
			break
	res.rect = BrushKernels._extent_rect(ext)
	return res


## Paints samples gx0..gx1 of row gz inside region `loc`; false (res.error set) on budget exhaustion.
static func _span(job: Job, loc: Vector2i, gx0: int, gx1: int, gz: int, res: Dictionary, ext: PackedInt32Array) -> bool:
	var state := job.state
	state.ensure_region(loc)
	var cov_buf: PackedFloat32Array = state.coverage[loc]
	var row := (gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES
	var z := gz * WorldConstants.SAMPLE_SPACING
	var lo := 0
	var hi := 0
	var wrote := false
	for g in range(gx0, gx1 + 1):
		var i := row + (g & WorldConstants.REGION_MASK)
		var cov := job.coverage(g * WorldConstants.SAMPLE_SPACING, z, state.strength_mult(g, gz), cov_buf[i])
		if cov <= cov_buf[i]:
			continue
		cov_buf[i] = cov
		if cov < MIN_VISIBLE_COVERAGE:
			continue
		var outcome := _store(state, loc, i, cov_buf[i])  # a function of the stored (float32) coverage only
		if outcome == _BUDGET:
			res.error = BrushKernels.ERROR_BUDGET
			break
		if outcome == _CHANGED:
			if not wrote:
				lo = g
			hi = g
			wrote = true
	if wrote:
		var dirty: Array[Vector2i] = res.dirty_colors if state.is_color() else res.dirty_controls
		BrushKernels._mark(dirty, ext, loc, lo, hi, gz)
	return res.error == ""


## Writes the stroke-start value blended by `cov` to sample i of region `loc`.
static func _store(state: BrushKernels.PaintStrokeState, loc: Vector2i, i: int, cov: float) -> int:
	var region := state.doc.get_region(loc)
	if state.is_color():
		var start: PackedByteArray = state.start_color[loc]
		var cur: PackedByteArray = region.color
		var o := i * 4
		var nv := state.color_value(_pack(start, o), cov)
		if nv == _pack(cur, o):
			return _UNCHANGED
		if not state.tx.capture_colors(loc):
			return _BUDGET
		cur[o] = (nv >> 24) & 0xFF
		cur[o + 1] = (nv >> 16) & 0xFF
		cur[o + 2] = (nv >> 8) & 0xFF
		cur[o + 3] = nv & 0xFF
		return _CHANGED
	var ctrl: PackedInt32Array = region.control
	var nc := state.control_value((state.start_control[loc] as PackedInt32Array)[i] & 0xFFFFFFFF, cov)
	if nc == (ctrl[i] & 0xFFFFFFFF):
		return _UNCHANGED
	if not state.tx.capture_controls(loc):
		return _BUDGET
	ctrl[i] = nc
	return _CHANGED


static func _pack(bytes: PackedByteArray, o: int) -> int:
	return (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]
