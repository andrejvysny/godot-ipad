extends TestCase
## PathSpline (docs/editor-v2.md §7): Catmull-Rom through the control points, closest point,
## stroke resampling.

func _points() -> PackedVector2Array:
	return PackedVector2Array([Vector2(0, 0), Vector2(4, 3), Vector2(8, 0), Vector2(12, -3), Vector2(16, 0)])


func test_curve_passes_through_every_control_point() -> void:
	var pts := _points()
	for i in pts.size():
		assert_eq(PathSpline.eval(pts, float(i)), pts[i], "eval at %d" % i)
	var curve := PathSpline.sample(pts, 0.5)
	for p in pts:
		assert_true(curve.has(p), "sample contains %s" % p)
	assert_eq(curve[0], pts[0])
	assert_eq(curve[curve.size() - 1], pts[pts.size() - 1])


func test_two_points_are_a_straight_line() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0)])
	for p in PathSpline.sample(pts, 0.5):
		assert_near(p.y, 0.0, 1e-6)
	assert_true(PathSpline.sample(pts, 0.5).size() >= 21, "at least one sample per 0.5 m")


func test_sampling_spacing_never_exceeds_the_step() -> void:
	var curve := PathSpline.sample(_points(), 0.5)
	assert_true(curve.size() > 30)
	for i in range(1, curve.size()):
		var d := curve[i - 1].distance_to(curve[i])
		assert_true(d <= 0.5 + 1e-4, "gap %f at %d" % [d, i])
		assert_true(d > 0.1, "no degenerate gap %f at %d" % [d, i])


func test_closest_on_curve_and_off_to_the_side() -> void:
	var pts := _points()
	var on := PathSpline.closest(pts, pts[2])
	assert_near(float(on.distance), 0.0, 0.01)
	assert_near(float(on.t), 2.0, 0.02)
	var query := Vector2(8, 5)
	var brute := INF
	for q in PathSpline.sample(pts, 0.01):
		brute = minf(brute, q.distance_to(query))
	var off := PathSpline.closest(pts, query)
	assert_near(float(off.distance), brute, 0.01, "matches a dense brute-force search")
	assert_true(float(off.t) > 1.0 and float(off.t) < 2.0)
	assert_true(PathSpline.eval(pts, float(off.t)).distance_to(off.point) < 0.05)
	var past := PathSpline.closest(pts, Vector2(-3, 0))
	assert_near(float(past.distance), 3.0, 0.01)
	assert_near(float(past.t), 0.0, 1e-6)
	assert_true(is_inf(float(PathSpline.closest(PackedVector2Array(), Vector2.ZERO).distance)))


func test_resample_keeps_first_and_last_and_spaces_points() -> void:
	var raw := PackedVector2Array()
	for i in 101:
		raw.append(Vector2(float(i) * 0.51, 0.0))  # 51 m
	var out := PathSpline.resample_stroke(raw, 4.0)
	assert_eq(out[0], raw[0])
	assert_eq(out[out.size() - 1], raw[raw.size() - 1])
	assert_eq(out.size(), 14, "0, 4 ... 48 and the end at 51 (a 3 m remainder is kept)")
	for i in range(1, out.size() - 1):
		assert_near(out[i].x - out[i - 1].x, 4.0, 1e-4)


func test_resample_short_remainder_replaces_the_last_point_and_corners_are_walked() -> void:
	var raw := PackedVector2Array([Vector2(0, 0), Vector2(6, 0), Vector2(6, 5)])
	var out := PathSpline.resample_stroke(raw, 4.0)
	assert_eq(out[0], Vector2(0, 0))
	assert_eq(out[1], Vector2(4, 0))
	assert_near(out[2].x, 6.0, 1e-4)
	assert_near(out[2].y, 2.0, 1e-4, "8 m along the polyline is 2 m up the second leg")
	assert_eq(out[out.size() - 1], Vector2(6, 5))
	var two := PathSpline.resample_stroke(PackedVector2Array([Vector2(0, 0), Vector2(1, 0)]), 4.0)
	assert_eq(two, PackedVector2Array([Vector2(0, 0), Vector2(1, 0)]))
