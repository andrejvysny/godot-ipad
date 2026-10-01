extends TestCase
## Brush scalar math and the stroke timeline (spec §12.1, §12.2, §13.1, §15.5).


func test_falloff_profile() -> void:
	assert_eq(BrushMath.falloff(0.0), 1.0, "centre")
	assert_near(BrushMath.falloff(0.5), 0.5625, 1e-12, "(1 - 0.25)^2")
	assert_eq(BrushMath.falloff(1.0), 0.0, "edge")
	assert_eq(BrushMath.falloff(1.5), 0.0, "beyond")


func test_path_falloff_hard_core() -> void:
	assert_eq(BrushMath.path_falloff(0.0), 1.0)
	assert_eq(BrushMath.path_falloff(0.6), 1.0, "core edge")
	assert_near(BrushMath.path_falloff(0.8), 0.5625, 1e-12, "half-way through the rim")
	assert_eq(BrushMath.path_falloff(1.0), 0.0)
	assert_eq(BrushMath.path_falloff(2.0), 0.0)


func test_pressure_factor_mapping() -> void:
	assert_near(BrushMath.pressure_factor(true, 0.0, true), 0.2, 1e-12, "p=0 -> min factor")
	assert_near(BrushMath.pressure_factor(true, 0.5, true), 0.6, 1e-12, "0.2 + 0.8p")
	assert_near(BrushMath.pressure_factor(true, 1.0, true), 1.0, 1e-12)
	assert_near(BrushMath.pressure_factor(true, 7.0, true), 1.0, 1e-12, "clamped")
	assert_eq(BrushMath.pressure_factor(true, 0.0, false), 1.0, "pressure off = 1")
	assert_eq(BrushMath.pressure_factor(false, 0.0, true), 1.0, "unavailable pressure is never zero")
	assert_eq(BrushMath.pressure_factor(true, NAN, true), 1.0, "NaN pressure is never zero")


func test_resample_spacing() -> void:
	assert_eq(BrushMath.resample_spacing(0.5), 0.125, "radius/4")
	assert_eq(BrushMath.resample_spacing(16.0), 0.25, "sample_spacing/2")


func test_integrated_falloff_matches_numeric_integration() -> void:
	var cases: Array = [
		[0.0, 0.0, 2.0, 4.0], [1.0, 1.0, 2.0, 4.0], [4.0, 3.0, 5.0, 3.0], [0.25, -1.0, 0.5, 2.0],
		[2.0, 10.0, 3.0, 4.0], [0.0, 2.0, 0.001, 16.0], [100.0, 5.0, 20.0, 16.0], [3.9, 0.0, 1.0, 2.0],
	]
	for c: Array in cases:
		var h2: float = c[0]
		var a: float = c[1]
		var l: float = c[2]
		var r: float = c[3]
		var expected := _numeric(h2, a, l, r)
		var got := BrushMath.integrated_falloff(h2, a, l, r)
		assert_near(got, expected, 1e-6 * maxf(absf(expected), 1e-3), "case %s" % [c])


func test_integrated_falloff_point_limit_and_outside() -> void:
	assert_near(BrushMath.integrated_falloff(1.0, 1.0, 0.0, 4.0), BrushMath.falloff(sqrt(2.0) / 4.0), 1e-12, "point dab")
	assert_near(BrushMath.integrated_falloff(1.0, 1.0, 1e-5, 4.0), BrushMath.falloff(sqrt(2.0) / 4.0), 1e-5, "continuous to point")
	assert_eq(BrushMath.integrated_falloff(16.0, 0.0, 2.0, 4.0), 0.0, "perpendicular distance == r")
	assert_eq(BrushMath.integrated_falloff(0.0, -5.0, 2.0, 4.0), 0.0, "behind the segment start")


func test_max_weighted_falloff_matches_dense_search() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for n in 60:
		var r := rng.randf_range(0.5, 16.0)
		var length := rng.randf_range(0.01, 3.0) * r
		var h2 := pow(rng.randf_range(0.0, 1.05) * r, 2.0)
		var a := rng.randf_range(-r, length + r)
		var pf_a := rng.randf_range(0.2, 1.0)
		var pf_b := pf_a if n % 7 == 0 else rng.randf_range(0.2, 1.0)
		var dense := 0.0
		for i in 20001:
			var s := length * i / 20000.0
			dense = maxf(dense, lerpf(pf_a, pf_b, s / length) * BrushMath.falloff(sqrt(h2 + (s - a) * (s - a)) / r))
		var got := BrushMath.max_weighted_falloff(h2, a, length, r, pf_a, pf_b)
		assert_true(got >= dense - 1e-12, "not below any sampled value (case %d)" % n)
		assert_near(got, dense, 1e-6, "case %d" % n)
	assert_near(BrushMath.max_weighted_falloff(1.0, 1.0, 0.0, 4.0, 0.5, 0.9), 0.5 * BrushMath.falloff(sqrt(2.0) / 4.0), 1e-12, "point dab")


## Composite Simpson over the segment; the integrand is C1 at the support edge.
func _numeric(h2: float, a: float, l: float, r: float) -> float:
	var n := 20000
	var h := l / n
	var total := 0.0
	for i in n + 1:
		var u := i * h
		var w := 1.0 if i == 0 or i == n else (4.0 if i % 2 == 1 else 2.0)
		total += w * BrushMath.falloff(sqrt(h2 + (a - u) * (a - u)) / r)
	return total * h / 3.0 / l


# --- StrokeTimeline --------------------------------------------------------------------

func test_timeline_interpolates_and_holds_last_position() -> void:
	var tl := StrokeTimeline.new()
	tl.add_sample(1.0, Vector2(0, 0), 0.5)
	tl.add_sample(2.0, Vector2(4, 2), 1.0)
	assert_false(tl.position_at(0.5).valid, "before start")
	var mid := tl.position_at(1.5)
	assert_true(mid.valid)
	assert_eq(mid.pos, Vector2(2, 1))
	assert_near(mid.pf, 0.75, 1e-12)
	var held := tl.position_at(10.0)
	assert_true(held.valid, "open segment holds")
	assert_eq(held.pos, Vector2(4, 2))


func test_timeline_pause_creates_gap_and_resume_new_segment() -> void:
	var tl := StrokeTimeline.new()
	tl.add_sample(0.0, Vector2(0, 0), 1.0)
	tl.add_sample(1.0, Vector2(1, 0), 1.0)
	tl.pause(1.5)
	tl.resume(3.0, Vector2(10, 10), 1.0)
	tl.add_sample(4.0, Vector2(11, 10), 1.0)
	assert_eq(tl.segment_count(), 2)
	assert_true(tl.position_at(1.25).valid, "held until pause")
	assert_false(tl.position_at(2.0).valid, "gap invalid")
	var pieces := tl.segments_between(0.5, 3.5)
	assert_eq(pieces.size(), 3, "0.5-1, 1-1.5 hold, 3-3.5")
	assert_eq(pieces[0].p_a, Vector2(0.5, 0))
	assert_eq(pieces[1].p_a, pieces[1].p_b, "hold piece is stationary")
	assert_eq(pieces[1].t_b, 1.5)
	assert_eq(pieces[2].t_a, 3.0, "no bridge across the gap")
	assert_eq(pieces[2].p_a, Vector2(10, 10))
	assert_eq(pieces[2].p_b, Vector2(10.5, 10))
	var total := 0.0
	for p: Dictionary in pieces:
		total += float(p.t_b) - float(p.t_a)
	assert_near(total, 1.5, 1e-12, "only valid time")


func test_timeline_known_until_tracks_last_sample_or_pause() -> void:
	var tl := StrokeTimeline.new()
	assert_eq(tl.known_until(), -INF, "empty")
	tl.add_sample(1.0, Vector2(0, 0), 1.0)
	tl.add_sample(1.5, Vector2(1, 0), 1.0)
	assert_eq(tl.known_until(), 1.5, "open segment: last sample")
	tl.pause(2.0)
	assert_eq(tl.known_until(), 2.0, "paused: close time")
	tl.resume(3.0, Vector2(5, 5), 1.0)
	assert_eq(tl.known_until(), 3.0, "resumed: resume sample")


func test_timeline_clamps_non_monotonic_time() -> void:
	var tl := StrokeTimeline.new()
	tl.add_sample(1.0, Vector2(0, 0), 1.0)
	assert_false(tl.add_sample(0.5, Vector2(1, 0), 1.0), "reported")
	assert_eq(tl.clamped_count, 1)
	assert_eq(tl.last_time(), 1.0, "clamped to last")
	assert_true(tl.add_sample(2.0, Vector2(2, 0), 1.0))
	var pieces := tl.segments_between(0.0, 2.0)
	assert_eq(pieces.size(), 1, "zero-duration jump omitted")
	assert_eq(pieces[0].p_a, Vector2(1, 0), "latest of equal timestamps")
