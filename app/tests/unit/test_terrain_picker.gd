extends TestCase
## TerrainPicker accuracy against independently solved intersections, seams and negative
## coordinates (TE-08), world boundary / sky rays (TE-09) and edit-then-pick (TE-10).

const TOL := 1e-3
const HILL_A := 4.0
const HILL_SIGMA := 30.0
const HILL_CENTER := Vector2(-10.3, 12.7)


# --- fixtures ------------------------------------------------------------------------------

## h = a*x + b*z + c at every sample (bilinear reproduces a plane exactly).
func _plane_doc(a: float, b: float, c: float) -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			var z: float = (loc.y * 256 + j) * 0.5
			for i in WorldConstants.REGION_SAMPLES:
				var x: float = (loc.x * 256 + i) * 0.5
				r.heights[j * 256 + i] = a * x + b * z + c
	doc.invalidate_all_height_ranges()
	return doc


static func _hill(x: float, z: float) -> float:
	var dx := x - HILL_CENTER.x
	var dz := z - HILL_CENTER.y
	return HILL_A * exp(-(dx * dx + dz * dz) / (2.0 * HILL_SIGMA * HILL_SIGMA))


func _hill_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			var z: float = (loc.y * 256 + j) * 0.5
			for i in WorldConstants.REGION_SAMPLES:
				r.heights[j * 256 + i] = _hill((loc.x * 256 + i) * 0.5, z)
	doc.invalidate_all_height_ranges()
	return doc


## Gentle-hills-like surface (a few metres of relief) used for timing.
func _hills_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			var z: float = (loc.y * 256 + j) * 0.5
			for i in WorldConstants.REGION_SAMPLES:
				var x: float = (loc.x * 256 + i) * 0.5
				r.heights[j * 256 + i] = 3.0 * sin(x * 0.045) * cos(z * 0.038) + 1.5 * sin((x + z) * 0.021)
	doc.invalidate_all_height_ranges()
	return doc


## Ray that passes through `target` from `height` metres above it along `dir`.
func _ray_to(target: Vector3, dir: Vector3, back: float) -> Vector3:
	return target - dir.normalized() * back


## Independent reference: first root of y(t) - hill(x(t), z(t)) on the analytic surface,
## 1 cm scan + 80-step bisection (different function, step and refinement than the picker).
func _solve_hill(o: Vector3, d: Vector3) -> Vector3:
	var n := d.normalized()
	var prev := 0.0
	var t := 0.0
	while t < 1000.0:
		t += 0.01
		if o.y + n.y * t - _hill(o.x + n.x * t, o.z + n.z * t) <= 0.0:
			var lo := prev
			var hi := t
			for _i in 80:
				var mid := 0.5 * (lo + hi)
				if o.y + n.y * mid - _hill(o.x + n.x * mid, o.z + n.z * mid) <= 0.0:
					hi = mid
				else:
					lo = mid
			return o + n * hi
		prev = t
	return Vector3(NAN, NAN, NAN)


func _assert_miss(hit: TerrainHit, reason: String, msg: String) -> void:
	assert_false(hit.ok, msg + " ok")
	assert_eq(hit.reason, reason, msg + " reason")
	assert_true(is_nan(hit.position.x) and is_nan(hit.position.y) and is_nan(hit.position.z), msg + " position must be NAN, got %s" % hit.position)
	assert_true(is_nan(hit.distance), msg + " distance NAN")
	assert_eq(hit.region, TerrainHit.NO_REGION, msg + " region sentinel")


# --- accuracy ------------------------------------------------------------------------------

func test_flat_terrain_exact() -> void:
	var doc := WorldDocument.create_flat(2.0, ControlCodec.grass_value())
	for target in [Vector3(10, 2, 10), Vector3(-37.3, 2, 88.1), Vector3(-127.9, 2, -127.9), Vector3(127.4, 2, 127.4)]:
		for dir in [Vector3(0, -1, 0), Vector3(1, -1, 0.5), Vector3(-0.3, -1, 0.2)]:
			var o := _ray_to(target, dir, 40.0)
			var hit := TerrainPicker.raycast(doc, o, dir)
			assert_eq(hit.reason, "hit", "flat %s %s" % [target, dir])
			assert_vec_near(hit.position, target, TOL, "flat %s %s" % [target, dir])
			assert_near(hit.distance, 40.0, TOL, "distance")
			assert_vec_near(hit.normal, Vector3.UP, 1e-6, "normal")


func test_tilted_plane_matches_analytic() -> void:
	var a := 0.1
	var b := -0.05
	var c := 3.0
	var doc := _plane_doc(a, b, c)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for k in 40:
		var o := Vector3(rng.randf_range(-120, 120), rng.randf_range(25, 60), rng.randf_range(-120, 120))
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1.5, -0.4), rng.randf_range(-1, 1)).normalized()
		# Plane: y = a x + b z + c  ->  t = (a ox + b oz + c - oy) / (dy - a dx - b dz)
		var t := (a * o.x + b * o.z + c - o.y) / (d.y - a * d.x - b * d.z)
		var expected := o + d * t
		var hit := TerrainPicker.raycast(doc, o, d)
		if not doc.layout.is_inside_world(expected.x, expected.z):
			assert_false(hit.ok, "ray %d leaves world before hitting" % k)
			continue
		assert_eq(hit.reason, "hit", "ray %d" % k)
		assert_vec_near(hit.position, expected, TOL, "ray %d" % k)
		assert_near(hit.distance, t, TOL, "ray %d distance" % k)
		assert_vec_near(hit.normal, Vector3(-a, 1.0, -b).normalized(), 1e-4, "ray %d normal" % k)


func test_gaussian_hill_matches_analytic_solution() -> void:
	var doc := _hill_doc()
	var targets := [Vector2(-10.3, 12.7), Vector2(0.1, 0.1), Vector2(-0.2, 30.0), Vector2(-40.0, -3.0), Vector2(25.0, 40.0), Vector2(-60.0, 60.0)]
	var dirs := [Vector3(0, -1, 0), Vector3(0.4, -1, 0.3), Vector3(-0.5, -1, 0.1), Vector3(0.2, -1, -0.6)]
	var worst := 0.0
	for tgt: Vector2 in targets:
		for d: Vector3 in dirs:
			var surface := Vector3(tgt.x, _hill(tgt.x, tgt.y), tgt.y)
			var o := _ray_to(surface, d, 50.0)
			var expected := _solve_hill(o, d)
			var hit := TerrainPicker.raycast(doc, o, d)
			assert_eq(hit.reason, "hit", "hill %s %s" % [tgt, d])
			assert_vec_near(hit.position, expected, TOL, "hill %s %s" % [tgt, d])
			assert_near(hit.position.y, doc.sample_height(hit.position.x, hit.position.z), 1e-5, "on doc surface")
			worst = maxf(worst, hit.position.distance_to(expected))
	print("    gaussian hill: worst |picker - analytic| = %s m over %d rays" % [String.num_scientific(worst), targets.size() * dirs.size()])


# --- seams, negative coordinates, quadrants (TE-08) ------------------------------------------

func test_quadrants_and_negative_coordinates() -> void:
	var doc := _plane_doc(0.02, 0.002, 1.0)
	var cases := [
		[Vector2(-0.1, -0.1), Vector2i(-1, -1)], [Vector2(0.1, -0.1), Vector2i(0, -1)],
		[Vector2(-0.1, 0.1), Vector2i(-1, 0)], [Vector2(0.1, 0.1), Vector2i(0, 0)],
		[Vector2(-127.9, -127.9), Vector2i(-1, -1)], [Vector2(127.4, -127.9), Vector2i(0, -1)],
		[Vector2(-127.9, 127.4), Vector2i(-1, 0)], [Vector2(127.4, 127.4), Vector2i(0, 0)],
		[Vector2(-64.25, 33.3), Vector2i(-1, 0)], [Vector2(0.0, 0.0), Vector2i(0, 0)],
		[Vector2(-0.5, -0.5), Vector2i(-1, -1)], [Vector2(127.5, 127.5), Vector2i(0, 0)],
	]
	for c: Array in cases:
		var p: Vector2 = c[0]
		var expected := Vector3(p.x, 0.02 * p.x + 0.002 * p.y + 1.0, p.y)
		var hit := TerrainPicker.raycast(doc, expected + Vector3(0, 30, 0), Vector3.DOWN)
		assert_eq(hit.reason, "hit", "quadrant %s" % p)
		assert_vec_near(hit.position, expected, TOL, "quadrant %s" % p)
		assert_eq(hit.region, c[1], "region of %s" % p)


func test_rays_crossing_internal_seams() -> void:
	var doc := _plane_doc(0.02, 0.002, 1.0)
	# Hits placed on and right next to the X and Z seams, approached from both sides.
	for p: Vector2 in [Vector2(0.0, 20.0), Vector2(-0.01, 20.0), Vector2(0.01, -20.0), Vector2(20.0, 0.0), Vector2(-20.0, -0.01), Vector2(-0.25, -0.25)]:
		for d: Vector3 in [Vector3(1, -0.6, 0), Vector3(-1, -0.6, 0), Vector3(0, -0.6, 1), Vector3(0, -0.6, -1), Vector3(0.7, -0.5, -0.7)]:
			var expected := Vector3(p.x, 0.02 * p.x + 0.002 * p.y + 1.0, p.y)
			var hit := TerrainPicker.raycast(doc, _ray_to(expected, d, 15.0), d)
			assert_eq(hit.reason, "hit", "seam %s %s" % [p, d])
			assert_vec_near(hit.position, expected, TOL, "seam %s %s" % [p, d])


# --- boundaries, sky, grazing, invalid (TE-09) ----------------------------------------------

func test_ray_from_outside_world_hits_inside() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	var target := Vector3(-20, 1, 30)
	for o in [Vector3(-300, 80, 30), Vector3(200, 40, 200), Vector3(-20, 50, -400)]:
		var hit := TerrainPicker.raycast(doc, o, target - o)
		assert_eq(hit.reason, "hit", "from %s" % o)
		assert_vec_near(hit.position, target, TOL, "from %s" % o)
		assert_near(hit.distance, o.distance_to(target), TOL, "distance from %s" % o)


func test_sky_rays_are_no_hit() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 20, 0), Vector3(0, 1, 0)), "no_hit", "straight up")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 20, 0), Vector3(0.3, 0.2, 0.1)), "no_hit", "upward")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(-50, 20, 10), Vector3(1, 0, 0)), "no_hit", "horizontal above")
	# Descending too slowly to reach the terrain before leaving the world.
	_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 20, 0), Vector3(1, -0.01, 0)), "no_hit", "leaves world")
	# Pointing at the terrain but max_distance stops short.
	_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 20, 0), Vector3.DOWN, 10.0), "no_hit", "short max_distance")
	# Aimed into the world from outside, but max_distance ends before the world edge: the XZ
	# path does cross the world, so this is a range cut-off, not 'outside'.
	_assert_miss(TerrainPicker.raycast(doc, Vector3(-300, 50, 0), Vector3(1, -0.1, 0), 100.0), "no_hit", "short range from outside")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(-300, 30, 0), Vector3(1, -0.1, 0), 150.0), "no_hit", "range ends before surface")
	var far_enough := TerrainPicker.raycast(doc, Vector3(-300, 30, 0), Vector3(1, -0.1, 0), 400.0)
	assert_eq(far_enough.reason, "hit", "same ray with enough range hits")


func test_outside_world_never_substitutes_zero() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var before := CanonicalEncoder.authored_hash(doc)
	for x in [127.75, 128.0, 200.0, -128.01, -500.0]:
		_assert_miss(TerrainPicker.raycast(doc, Vector3(x, 30, 0), Vector3.DOWN), "outside", "down at x=%s" % x)
		_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 30, x), Vector3.DOWN), "outside", "down at z=%s" % x)
	_assert_miss(TerrainPicker.raycast(doc, Vector3(300, 10, 0), Vector3(1, -0.2, 0)), "outside", "pointing away")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(300, 10, 300), Vector3(1, -1, -1)), "outside", "diagonal away")
	assert_eq(CanonicalEncoder.authored_hash(doc), before, "picking never writes the document")
	assert_eq(doc.regions.size(), 4, "no regions created")


func test_straight_down_over_world_edges() -> void:
	var doc := _plane_doc(0.02, 0.002, 1.0)
	for p: Vector2 in [Vector2(127.5, 0.0), Vector2(-128.0, 0.0), Vector2(0.0, 127.5), Vector2(0.0, -128.0), Vector2(127.5, -128.0), Vector2(127.45, 127.49)]:
		var expected := Vector3(p.x, 0.02 * p.x + 0.002 * p.y + 1.0, p.y)
		var hit := TerrainPicker.raycast(doc, Vector3(p.x, 40.0, p.y), Vector3.DOWN)
		assert_eq(hit.reason, "hit", "edge %s" % p)
		assert_vec_near(hit.position, expected, TOL, "edge %s" % p)
	_assert_miss(TerrainPicker.raycast(doc, Vector3(127.51, 40.0, 0.0), Vector3.DOWN), "outside", "just beyond +edge")


func test_grazing_rays_are_rejected_with_diagnostics() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var shallow := Vector3(cos(deg_to_rad(1.0)), -sin(deg_to_rad(1.0)), 0.0)
	var hit := TerrainPicker.raycast(doc, Vector3(-120, 1.0, 5.0), shallow)
	assert_false(hit.ok, "1 degree ray not ok")
	assert_eq(hit.reason, "grazing")
	assert_true(hit.position.is_finite(), "grazing keeps diagnostic position")
	assert_near(hit.position.y, 0.0, TOL, "grazing position on surface")
	assert_near(hit.position.x, -120.0 + 1.0 / tan(deg_to_rad(1.0)), 0.05, "grazing position x")
	var steeper := Vector3(cos(deg_to_rad(3.0)), -sin(deg_to_rad(3.0)), 0.0)
	var ok_hit := TerrainPicker.raycast(doc, Vector3(-120, 1.0, 5.0), steeper)
	assert_eq(ok_hit.reason, "hit", "3 degree ray accepted")
	assert_true(ok_hit.ok)


func test_invalid_rays() -> void:
	var doc := WorldDocument.create_flat(5.0, ControlCodec.grass_value())
	_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 20, 0), Vector3.ZERO), "invalid_ray", "zero dir")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(NAN, 20, 0), Vector3.DOWN), "invalid_ray", "nan origin")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(0, 20, 0), Vector3(INF, -1, 0)), "invalid_ray", "inf dir")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(3, 4.0, 3), Vector3.DOWN), "invalid_ray", "origin under terrain")
	_assert_miss(TerrainPicker.raycast(doc, Vector3(3, 4.0, 3), Vector3.UP), "invalid_ray", "origin under terrain looking up")
	_assert_miss(TerrainPicker.raycast(null, Vector3(0, 20, 0), Vector3.DOWN), "invalid_ray", "null doc")
	# Below the terrain but outside the world is not "under terrain": there is no terrain there.
	_assert_miss(TerrainPicker.raycast(doc, Vector3(300, 0, 0), Vector3(1, 0, 0)), "outside", "outside, low")


func test_far_origin_and_infinite_range_terminate() -> void:
	var doc := WorldDocument.create_flat(2.0, ControlCodec.grass_value())
	# t + STEP == t in float64 this far out; the march must still end after a bounded count.
	var far := TerrainPicker.raycast(doc, Vector3(3, 1e17, 3), Vector3.DOWN, INF)
	assert_true(far.reason == "hit" or far.reason == "no_hit", "far origin returns (%s)" % far.reason)
	var high := TerrainPicker.raycast(doc, Vector3(3.3, 1e6, -7.1), Vector3.DOWN, INF)
	assert_eq(high.reason, "hit", "1000 km up with unbounded range")
	assert_vec_near(high.position, Vector3(3.3, 2.0, -7.1), TOL, "1000 km up position")
	var slanted := TerrainPicker.raycast(doc, Vector3(-1e5, 1e5, 10.0), Vector3(1, -1, 0), INF)
	assert_eq(slanted.reason, "hit", "100 km away, 45 degrees, unbounded range")
	assert_vec_near(slanted.position, Vector3(-2.0, 2.0, 10.0), TOL, "far slanted position")


func test_heights_at_authored_limits_are_picked() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var r := doc.get_region(Vector2i(0, 0))
	for j in range(100, 111):
		for i in range(100, 111):
			r.heights[j * 256 + i] = WorldConstants.HEIGHT_MAX
	var low := doc.get_region(Vector2i(-1, -1))
	for j in range(100, 111):
		for i in range(100, 111):
			low.heights[j * 256 + i] = WorldConstants.HEIGHT_MIN
	doc.invalidate_all_height_ranges()
	# Plateau spans world 50..55 on both axes; the ray starts far above the authored limit.
	var peak := Vector3(52.5, WorldConstants.HEIGHT_MAX, 52.5)
	var d := Vector3(0.1, -1, 0.05)
	var top := TerrainPicker.raycast(doc, _ray_to(peak, d, 450.0), d)
	assert_eq(top.reason, "hit", "peak at HEIGHT_MAX")
	assert_vec_near(top.position, peak, TOL, "peak position")
	# Pit centre is world (-128 + 52.5) on both axes; its floor is 32 m below the flat terrain.
	var pit := TerrainPicker.raycast(doc, Vector3(-75.5, 10.0, -75.5), Vector3.DOWN)
	assert_eq(pit.reason, "hit", "pit floor at HEIGHT_MIN")
	assert_near(pit.position.y, WorldConstants.HEIGHT_MIN, TOL, "pit depth")


func test_origin_on_surface_hits_at_zero_distance() -> void:
	var doc := WorldDocument.create_flat(5.0, ControlCodec.grass_value())
	var hit := TerrainPicker.raycast(doc, Vector3(3, 5.0, 3), Vector3.DOWN)
	assert_eq(hit.reason, "hit")
	assert_near(hit.distance, 0.0, 1e-9)


# --- document freshness (TE-10) --------------------------------------------------------------

func test_height_edit_then_pick_sees_new_height() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var probe := Vector3(-30.25, 50.0, -12.75)
	assert_near(TerrainPicker.raycast(doc, probe, Vector3.DOWN).position.y, 0.0, TOL, "before edit")
	# Raise a patch well above the old height range; the doc contract requires invalidation.
	var loc := Vector2i(-1, -1)
	var r := doc.get_region(loc)
	var gx0 := floori(probe.x / 0.5) - 4
	var gz0 := floori(probe.z / 0.5) - 4
	for gz in range(gz0, gz0 + 9):
		for gx in range(gx0, gx0 + 9):
			r.heights[WorldConstants.sample_local(gz) * 256 + WorldConstants.sample_local(gx)] = 7.5
	doc.invalidate_height_range(loc)
	var hit := TerrainPicker.raycast(doc, probe, Vector3.DOWN)
	assert_eq(hit.reason, "hit")
	assert_near(hit.position.y, 7.5, TOL, "after edit sees raised terrain")
	assert_eq(hit.region, loc)


# --- timing -----------------------------------------------------------------------------------

func test_timing_typical_and_grazing_rays() -> void:
	var doc := _hills_doc()
	# No doc.height_range() warm-up: the picker must not depend on the range cache.
	var d45 := Vector3(0.6, -1.0, 0.8).normalized()  # horizontal length 1, drop 1: 45 degrees
	var n := 200
	var t0 := Time.get_ticks_usec()
	var hits := 0
	for k in n:
		var o := Vector3(-100.0 + k * 0.7, 30.0, -90.0 + k * 0.5)
		if TerrainPicker.raycast(doc, o, d45).ok:
			hits += 1
	var avg45 := (Time.get_ticks_usec() - t0) / 1000.0 / n
	assert_eq(hits, n, "every 45-degree ray hits")
	var grazing_dir := Vector3(1.0, -0.035, 0.05).normalized()
	var m := 20
	t0 = Time.get_ticks_usec()
	var graze_hit: TerrainHit
	for k in m:
		graze_hit = TerrainPicker.raycast(doc, Vector3(-127.9, 6.0, -60.0 + k), grazing_dir)
	var avg_graze := (Time.get_ticks_usec() - t0) / 1000.0 / m
	print("    picker timing: 45-degree ray %.3f ms avg (%d rays); long near-grazing (2 degree) ray %.3f ms avg (%d rays, last=%s)" % [avg45, n, avg_graze, m, graze_hit.reason])
	assert_true(avg45 < 1.0, "45-degree ray average %.3f ms must stay under 1 ms" % avg45)


## TE-10 path during sculpting: every frame edits heights (which invalidates the region range
## cache) and then picks. The pick must neither consult nor rebuild the range cache.
class RangeCountingDoc extends WorldDocument:
	var range_queries := 0

	func height_range() -> Vector2:
		range_queries += 1
		return super()

	func region_height_range(loc: Vector2i) -> Vector2:
		range_queries += 1
		return super(loc)


func test_pick_after_height_invalidation_does_not_rescan() -> void:
	var doc := RangeCountingDoc.new()
	doc.regions = _hills_doc().regions
	var d45 := Vector3(0.6, -1.0, 0.8).normalized()
	var results := {}
	for label: String in ["1 region", "4 regions"]:
		var n := 30
		var total_us := 0
		for k in n:
			if label == "1 region":
				doc.invalidate_height_range(Vector2i(-1, 0))
			else:
				doc.invalidate_all_height_ranges()
			var o := Vector3(-60.0 + k * 3.0, 70.0, -50.0 + k * 2.0)
			var t0 := Time.get_ticks_usec()
			var hit := TerrainPicker.raycast(doc, o, d45)
			total_us += Time.get_ticks_usec() - t0
			assert_eq(hit.reason, "hit", "%s ray %d" % [label, k])
		results[label] = total_us / 1000.0 / n
	assert_eq(doc.range_queries, 0, "picker never queries the height range cache")
	var t_scan := Time.get_ticks_usec()
	doc.region_height_range(Vector2i(0, 0))
	var scan_ms := (Time.get_ticks_usec() - t_scan) / 1000.0
	print("    pick right after edit (camera 70 m up, 45 deg): 1 region invalidated %.3f ms, 4 regions invalidated %.3f ms avg; one region range rescan (avoided) %.3f ms" % [results["1 region"], results["4 regions"], scan_ms])
	for label: String in results:
		# Generous bound for loaded CI hosts; the call-count assert above is the real guard.
		assert_true(results[label] < 5.0, "%s pick %.3f ms" % [label, results[label]])
