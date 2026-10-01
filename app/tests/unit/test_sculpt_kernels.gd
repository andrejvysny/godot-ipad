extends TestCase
## Sculpt-family kernels through SculptStroke: alphas, flatten, noise, smooth (docs/editor-v2.md §3, §5).

const STEP := 1.0 / 60.0


func _doc(height: float = 0.0) -> WorldDocument:
	return WorldDocument.create_flat(height, ControlCodec.default_value())


func _settings(kind: String, radius: float, extra: Dictionary = {}) -> Dictionary:
	var s := {"kind": kind, "radius": radius, "direction": 1.0, "speed_m_per_s": 2.0, "strength": 1.0,
			"pressure_enabled": false, "fixed_step_s": STEP, "shape": "soft",
			"alpha_mode": "circle", "target": 0.0}
	s.merge(extra, true)
	return s


func _begin(doc: WorldDocument, settings: Dictionary, pos: Vector2) -> SculptStroke:
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Sculpt", settings)
	var s := SculptStroke.new()
	s.begin(doc, tx, settings, 0.0, pos, 1.0)
	return s


## Advances step by step for `steps` fixed steps and returns the merged error ("" when fine).
func _run(s: SculptStroke, from_step: int, to_step: int) -> String:
	for k in range(from_step + 1, to_step + 1):
		var r := s.advance_to(float(k) * STEP + 0.06)
		if r.error != "":
			return r.error
	return ""


func _heights(doc: WorldDocument) -> Dictionary:
	var out := {}
	for loc: Vector2i in doc.regions:
		out[loc] = doc.get_region(loc).heights.duplicate()
	return out


func test_flatten_approaches_the_target_monotonically_without_overshoot() -> void:
	for elevation in [-20.0, -3.0, 2.5, 10.0, 40.0]:
		var doc := _doc(elevation)
		var target := 3.5
		var s := _begin(doc, _settings("flatten", 6.0, {"target": target}), Vector2(20, 20))
		var prev := {}
		for step in range(1, 181):
			assert_empty_string(_run(s, step - 1, step))
			for probe in [Vector2i(40, 40), Vector2i(44, 40), Vector2i(40, 46)]:
				var h := doc.get_height_at_sample(probe.x, probe.y)
				var gap := h - target
				if prev.has(probe):
					assert_true(absf(gap) <= absf(float(prev[probe]) - target) + 1e-6, "monotone %s e=%s step %d" % [probe, elevation, step])
					assert_true(gap * (float(prev[probe]) - target) >= -1e-6, "no overshoot %s e=%s" % [probe, elevation])
				prev[probe] = h
		assert_near(doc.get_height_at_sample(40, 40), target, 0.05, "centre converged from %s" % elevation)
		assert_true(absf(doc.get_height_at_sample(44, 40) - target) < absf(elevation - target), "q = 0.33 moved")
		assert_eq(doc.get_height_at_sample(60, 40), elevation, "outside the radius untouched")


func test_flatten_leaves_a_level_surface_unchanged_and_never_leaves_height_limits() -> void:
	var doc := _doc(3.5)
	var s := _begin(doc, _settings("flatten", 6.0, {"target": 3.5}), Vector2(20, 20))
	assert_empty_string(_run(s, 0, 30))
	assert_eq(doc.get_height_at_sample(40, 40), 3.5)
	var high := _doc(60.0)
	var s2 := _begin(high, _settings("flatten", 6.0, {"target": 500.0}), Vector2(20, 20))
	assert_empty_string(_run(s2, 0, 300))
	assert_true(high.get_height_at_sample(40, 40) <= WorldConstants.HEIGHT_MAX, "clamped to the height range")


func test_noise_is_deterministic_bounded_and_roughens_further_per_pass() -> void:
	var a := _doc()
	var b := _doc()
	var sa := _begin(a, _settings("noise", 6.0), Vector2(20, 20))
	var sb := _begin(b, _settings("noise", 6.0), Vector2(20, 20))
	assert_empty_string(_run(sa, 0, 30))
	assert_empty_string(_run(sb, 0, 30))
	assert_true(_heights(a) == _heights(b), "same input, same bytes")
	var lo := 1.0e9
	var hi := -1.0e9
	for gx in range(34, 47):
		var h := a.get_height_at_sample(gx, 40)
		lo = minf(lo, h)
		hi = maxf(hi, h)
		assert_true(absf(h) <= 1.5 * 0.5 + 1e-3, "at most rate * time (%.4f)" % h)
	assert_true(hi - lo > 0.05, "surface roughened (%.4f)" % (hi - lo))
	var before := a.get_height_at_sample(40, 40)
	assert_empty_string(_run(sa, 30, 60))
	assert_ne(a.get_height_at_sample(40, 40), before, "more time, more change")


func _mirror(g: int) -> int:
	return g if g >= 0 else -1 - g


## Rough field that is mirror symmetric about the region seams at (-0.25, -0.25).
func _symmetric_noise_doc() -> WorldDocument:
	var doc := _doc()
	for loc: Vector2i in doc.regions:
		var heights := doc.get_region(loc).heights
		for i in heights.size():
			var gx := loc.x * 256 + i % 256
			var gz := loc.y * 256 + i / 256
			heights[i] = 4.0 * BrushAlpha.hash01(float(_mirror(gx)) * 1.3, float(_mirror(gz)) * 0.7)
	return doc


func _roughness(doc: WorldDocument, r: int) -> float:
	var sum := 0.0
	for gz in range(-r, r):
		for gx in range(-r, r):
			sum += absf(doc.get_height_at_sample(gx + 1, gz) - doc.get_height_at_sample(gx, gz))
	return sum


func test_smooth_across_region_seams_has_no_seam_discontinuity() -> void:
	var doc := _symmetric_noise_doc()
	var rough_before := _roughness(doc, 8)
	var s := _begin(doc, _settings("smooth", 8.0), Vector2(-0.25, -0.25))
	assert_empty_string(_run(s, 0, 40))
	assert_true(_roughness(doc, 8) < rough_before * 0.6, "surface smoothed")
	var worst := 0.0
	for gz in range(-12, 12):
		for gx in range(-12, 12):
			worst = maxf(worst, absf(doc.get_height_at_sample(gx, gz) - doc.get_height_at_sample(-1 - gx, gz)))
			worst = maxf(worst, absf(doc.get_height_at_sample(gx, gz) - doc.get_height_at_sample(gx, -1 - gz)))
	assert_true(worst < 1e-4, "X and Z seam symmetry (worst %.7f)" % worst)


func test_smooth_at_the_world_edge_skips_missing_neighbours() -> void:
	var doc := _symmetric_noise_doc()
	var s := _begin(doc, _settings("smooth", 4.0), Vector2(127.5, 127.5))
	assert_empty_string(_run(s, 0, 30))
	var finite := true
	for gz in range(240, 256):
		for gx in range(240, 256):
			finite = finite and is_finite(doc.get_height_at_sample(gx, gz))
	assert_true(finite, "all heights finite")
	assert_true(doc.get_height_at_sample(255, 255) != _symmetric_noise_doc().get_height_at_sample(255, 255), "corner smoothed")


func test_smooth_never_changes_a_flat_surface() -> void:
	var doc := _doc(7.0)
	var s := _begin(doc, _settings("smooth", 6.0), Vector2(0.0, 0.0))
	assert_empty_string(_run(s, 0, 20))
	for loc: Vector2i in doc.regions:
		assert_eq(doc.get_region(loc).heights.count(7.0), WorldConstants.REGION_SAMPLE_COUNT, "%s flat" % loc)


func test_dab_raise_mass_matches_the_continuous_kernel() -> void:
	var exact := _doc()
	var dabs := _doc()
	var pts := [Vector2(20, 20), Vector2(24, 20)]
	for pair in [[exact, "circle"], [dabs, "stamp"]]:
		var doc: WorldDocument = pair[0]
		var s := _begin(doc, _settings("raise", 4.0, {"alpha_mode": pair[1]}), pts[0])
		for k in range(1, 61):
			s.add_sample(float(k) * STEP, (pts[0] as Vector2).lerp(pts[1], float(k) / 60.0), 1.0)
			assert_empty_string(s.advance_to(float(k) * STEP + 0.06).error)
	var mass_exact := 0.0
	var mass_dabs := 0.0
	for gz in range(30, 52):
		for gx in range(30, 62):
			mass_exact += exact.get_height_at_sample(gx, gz)
			mass_dabs += dabs.get_height_at_sample(gx, gz)
	assert_true(mass_exact > 1.0, "something was raised")
	assert_true(absf(mass_dabs / mass_exact - 1.0) < 0.05, "mass %.3f vs %.3f" % [mass_dabs, mass_exact])


func test_hard_raise_is_flat_topped_and_ring_leaves_the_centre() -> void:
	var hard := _doc()
	var ring := _doc()
	var sh := _begin(hard, _settings("raise", 6.0, {"shape": "hard"}), Vector2(20, 20))
	var sr := _begin(ring, _settings("raise", 6.0, {"shape": "ring"}), Vector2(20, 20))
	assert_empty_string(_run(sh, 0, 30))
	assert_empty_string(_run(sr, 0, 30))
	assert_near(hard.get_height_at_sample(40, 40), hard.get_height_at_sample(44, 40), 1e-6, "flat core")
	assert_true(hard.get_height_at_sample(40, 40) > 0.5)
	assert_true(ring.get_height_at_sample(40, 40) < 1e-4, "ring: centre untouched")
	assert_true(ring.get_height_at_sample(48, 40) > 0.1, "ring crest raised")
