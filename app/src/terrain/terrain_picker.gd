class_name TerrainPicker
extends RefCounted
## Terrain ray picking against canonical document data (ADR 0004): the pinned Terrain3D
## CPU get_intersection is a fixed 1 m raymarch without refinement and reports y = 0 for
## a vertical ray over missing terrain, which violates spec §11.3. This picker marches the
## same bilinear surface Terrain3DData.get_height samples (WorldDocument.sample_height),
## so it always sees the current document, never stale collision or GPU state.
##
## All ray math runs in 64-bit floats; only the returned position/normal are Vector3.
##
## The vertical clip uses the fixed authored limits [HEIGHT_MIN, HEIGHT_MAX] instead of
## doc.height_range(): height writers invalidate the per-region range cache, and rescanning
## 65,536 samples per region in GDScript on every edit-then-pick costs ~15 ms per region.
## Canonical heights never leave these limits (WorldValidator rejects, brushes clamp).

const STEP := 0.25
const BISECT_ITERATIONS := 30
const BOX_Y_MARGIN := 0.5
const GRAZING_SIN := 0.03489949670250097  # sin(2 degrees)
const _MIN_DIR_LENGTH_SQ := 1e-12


static func raycast(doc: WorldDocument, origin: Vector3, dir: Vector3, max_distance: float = 2000.0) -> TerrainHit:
	if doc == null or not origin.is_finite() or not dir.is_finite() or not (max_distance > 0.0):
		return TerrainHit.miss(TerrainHit.REASON_INVALID_RAY)
	var dx: float = dir.x
	var dy: float = dir.y
	var dz: float = dir.z
	var len_sq := dx * dx + dy * dy + dz * dz
	if len_sq < _MIN_DIR_LENGTH_SQ:
		return TerrainHit.miss(TerrainHit.REASON_INVALID_RAY)
	var inv_len := 1.0 / sqrt(len_sq)
	var ray := PackedFloat64Array([origin.x, origin.y, origin.z, dx * inv_len, dy * inv_len, dz * inv_len])
	var origin_h := doc.sample_height(ray[0], ray[2])
	if not is_nan(origin_h) and ray[1] < origin_h:
		return TerrainHit.miss(TerrainHit.REASON_INVALID_RAY)

	# 'outside' depends only on the forward XZ path; max_distance cut-offs are 'no_hit'.
	var span := PackedFloat64Array([0.0, INF])
	if not _clip_axis(ray[0], ray[3], WorldConstants.WORLD_MIN, WorldConstants.WORLD_MAX_SAMPLE, span) \
			or not _clip_axis(ray[2], ray[5], WorldConstants.WORLD_MIN, WorldConstants.WORLD_MAX_SAMPLE, span):
		return TerrainHit.miss(TerrainHit.REASON_OUTSIDE)
	span[1] = minf(span[1], max_distance)
	if span[0] > span[1] or not _clip_axis(ray[1], ray[4],
			WorldConstants.HEIGHT_MIN - BOX_Y_MARGIN, WorldConstants.HEIGHT_MAX + BOX_Y_MARGIN, span):
		return TerrainHit.miss(TerrainHit.REASON_NO_HIT)
	return _march(doc, ray, span[0], span[1])


## Walks [t0, t1] and refines the first crossing from above the surface (f > 0) to on or
## below it (f <= 0). NaN heights break the bracket so no crossing is bridged over a gap.
## The span is finite (clipped to the world box), and the step count is fixed up front so a
## far origin, where t + STEP == t in float64, cannot stall the loop.
static func _march(doc: WorldDocument, ray: PackedFloat64Array, t0: float, t1: float) -> TerrainHit:
	var prev_t := t0
	var prev_f := _f(doc, ray, t0)
	if prev_f == 0.0:
		return _make_hit(doc, ray, t0)
	var steps := ceili((t1 - t0) / STEP)
	for i in range(1, steps + 1):
		var t := minf(t0 + i * STEP, t1)
		var f := _f(doc, ray, t)
		if f <= 0.0 and prev_f > 0.0:
			var crossing := _bisect(doc, ray, prev_t, t)
			if is_finite(crossing):
				return _make_hit(doc, ray, crossing)
		prev_f = f
		prev_t = t
	return TerrainHit.miss(TerrainHit.REASON_NO_HIT)


static func _bisect(doc: WorldDocument, ray: PackedFloat64Array, above_t: float, below_t: float) -> float:
	var ta := above_t
	var tb := below_t
	for _i in BISECT_ITERATIONS:
		var mid := 0.5 * (ta + tb)
		var height := _f(doc, ray, mid)
		if is_nan(height):
			return NAN  # a hole inside the bracket cannot be refined into a surface hit
		if height <= 0.0:
			tb = mid
		else:
			ta = mid
	return 0.5 * (ta + tb)


## Height of the ray above the terrain at parameter t; NAN where there is no sample.
static func _f(doc: WorldDocument, ray: PackedFloat64Array, t: float) -> float:
	return ray[1] + ray[4] * t - doc.sample_height(ray[0] + ray[3] * t, ray[2] + ray[5] * t)


static func _make_hit(doc: WorldDocument, ray: PackedFloat64Array, t: float) -> TerrainHit:
	var x: float = ray[0] + ray[3] * t
	var y: float = ray[1] + ray[4] * t
	var z: float = ray[2] + ray[5] * t
	var n := doc.sample_normal(x, z)
	var cos_incidence := absf(ray[3] * n.x + ray[4] * n.y + ray[5] * n.z)
	return TerrainHit.surface(Vector3(x, y, z), n, t, region_at(x, z), cos_incidence < GRAZING_SIN)


## Region containing world point (x, z) using the floor-based sample mapping (TE-08).
## The +127.5 m edge belongs to region 0 because its sample index is 255.
static func region_at(x: float, z: float) -> Vector2i:
	if not WorldConstants.is_inside_world(x, z):
		return TerrainHit.NO_REGION
	var gx := mini(floori(x / WorldConstants.SAMPLE_SPACING), WorldConstants.GLOBAL_SAMPLE_MAX)
	var gz := mini(floori(z / WorldConstants.SAMPLE_SPACING), WorldConstants.GLOBAL_SAMPLE_MAX)
	return Vector2i(WorldConstants.sample_region(gx), WorldConstants.sample_region(gz))


## Slab clip of span = [t_enter, t_exit] against lo <= o + d t <= hi. False when empty.
static func _clip_axis(o: float, d: float, lo: float, hi: float, span: PackedFloat64Array) -> bool:
	if d == 0.0:
		return o >= lo and o <= hi and span[0] <= span[1]
	var ta := (lo - o) / d
	var tb := (hi - o) / d
	if ta > tb:
		var tmp := ta
		ta = tb
		tb = tmp
	span[0] = maxf(span[0], ta)
	span[1] = minf(span[1], tb)
	return span[0] <= span[1]
