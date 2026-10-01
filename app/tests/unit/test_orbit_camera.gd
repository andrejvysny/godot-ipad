extends TestCase
## Orbit camera math (spec §8, CA-01..CA-03).

const VP := Vector2(1180, 820)


func _screen_of(c: OrbitCameraController, world: Vector3) -> Vector2:
	var inv := c.camera_transform().affine_inverse()
	var l := inv * world
	var th := tan(deg_to_rad(c.fov_deg) * 0.5)
	var ndc := Vector2(l.x / (-l.z * th * VP.x / VP.y), l.y / (-l.z * th))
	return Vector2((ndc.x + 1.0) * 0.5 * VP.x, (1.0 - ndc.y) * 0.5 * VP.y)


func test_ca01_orbit_keeps_pivot_no_roll() -> void:
	var c := OrbitCameraController.new()
	c.pivot = Vector3(12, 3, -7)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 500:
		c.orbit(Vector2(rng.randf_range(-80, 80), rng.randf_range(-80, 80)), VP)
		var t := c.camera_transform()
		assert_near(t.basis.x.y, 0.0, 1e-6, "no roll")
		assert_vec_near(c.pivot, Vector3(12, 3, -7), 0.0, "pivot fixed")
		assert_near(t.origin.distance_to(c.pivot), c.distance, 1e-4, "distance kept")
		var fwd := -t.basis.z
		assert_vec_near(fwd, (c.pivot - t.origin).normalized(), 1e-5, "looks at pivot")


func test_clamps() -> void:
	var c := OrbitCameraController.new()
	c.orbit(Vector2(0, 100000), VP)
	assert_near(rad_to_deg(c.pitch), 80.0, 1e-6)
	c.orbit(Vector2(0, -100000), VP)
	assert_near(rad_to_deg(c.pitch), 15.0, 1e-6)
	c.pan_zoom_begin(VP * 0.5, 100.0, VP)
	c.pan_zoom_update(VP * 0.5, 100000.0, VP)
	assert_near(c.distance, 3.0, 1e-9)
	c.pan_zoom_update(VP * 0.5, 1.0, VP)
	assert_near(c.distance, 350.0, 1e-9)


func test_precision_factor_monotonic() -> void:
	var c := OrbitCameraController.new()
	var last := -1.0
	for d in [3.0, 6.0, 12.0, 20.0, 30.0, 100.0]:
		c.distance = d
		var f := c.precision_factor()
		assert_true(f >= last, "monotonic")
		last = f
	c.distance = 3.0
	assert_near(c.precision_factor(), 0.4 + 0.6 * 0.1, 1e-9)
	c.distance = 100.0
	assert_near(c.precision_factor(), 1.0, 1e-9)


func test_ca02_begin_update_identical_is_exact() -> void:
	var c := OrbitCameraController.new()
	c.pivot = Vector3(5, 2, 9)
	var before := c.camera_transform()
	var cen := Vector2(400, 500)
	c.pan_zoom_begin(cen, 230.0, VP)
	assert_eq(c.camera_transform(), before, "begin changes nothing")
	c.pan_zoom_update(cen, 230.0, VP)
	assert_eq(c.camera_transform(), before, "identical update changes nothing")


func test_pan_moves_pivot_by_ground_displacement() -> void:
	var c := OrbitCameraController.new()
	var cen := Vector2(500, 400)
	var start_hit: Vector3 = c._ground_hit(cen, VP, 0.0)
	var moved := Vector2(560, 430)
	var expect_shift: Vector3 = start_hit - (c._ground_hit(moved, VP, 0.0) as Vector3)
	c.pan_zoom_begin(cen, 200.0, VP)
	c.pan_zoom_update(moved, 200.0, VP)
	assert_near(c.pivot.y, 0.0, 1e-9)
	assert_true(c.pivot.length() > 0.1, "pivot moved")
	assert_near(_screen_of(c, start_hit).x, moved.x, 0.5, "x under finger")
	assert_near(_screen_of(c, start_hit).y, moved.y, 0.5, "y under finger")
	assert_vec_near(c.pivot, expect_shift, 1e-3, "pivot shift equals ground displacement")


func test_ca03_pinch_keeps_anchor_under_centroid() -> void:
	var c := OrbitCameraController.new()
	var cen := Vector2(300, 600)
	var anchor: Vector3 = c._ground_hit(cen, VP, 0.0)
	c.pan_zoom_begin(cen, 150.0, VP)
	for span in [170.0, 250.0, 400.0, 120.0]:
		c.pan_zoom_update(cen, span, VP)
		var s := _screen_of(c, anchor)
		assert_near(s.x, cen.x, 0.5, "x span %s" % span)
		assert_near(s.y, cen.y, 0.5, "y span %s" % span)
	c.pan_zoom_update(cen, 300.0, VP)
	assert_true(c.distance < 140.0, "zoomed in")


func _low_pitch() -> OrbitCameraController:
	var c := OrbitCameraController.new()
	c.pivot = Vector3(10, 0, 10)
	c.pitch = deg_to_rad(15.0)
	return c


func test_upward_ray_keeps_pivot() -> void:
	var c := _low_pitch()
	var top := Vector2(590, 0)
	assert_true(c.screen_ray(top, VP)[1].y > -1e-6, "ray is upward")
	c.pan_zoom_begin(top, 100.0, VP)
	c.pan_zoom_update(top, 100.0, VP)
	assert_vec_near(c.pivot, Vector3(10, 0, 10), 0.0, "pivot kept when no hit")


func test_hit_then_miss_keeps_last_pivot() -> void:
	var c := _low_pitch()
	c.pan_zoom_begin(Vector2(590, 700), 100.0, VP)
	var last := c.pivot
	var missed := false
	for y in range(700, 0, -20):
		c.pan_zoom_update(Vector2(590, y), 100.0, VP)
		assert_true(c.pivot.is_finite())
		if c._ground_hit(Vector2(590, y), VP, 0.0) == null:
			missed = true
			assert_vec_near(c.pivot, last, 0.0, "miss keeps pivot y=%d" % y)
		assert_true(c.pivot.distance_to(last) < 60.0, "bounded step y=%d" % y)
		assert_true(absf(c.pivot.x) <= 127.5 and absf(c.pivot.z) <= 128.0, "inside world")
		last = c.pivot
	assert_true(missed, "sequence reached a miss")


func test_miss_then_hit_does_not_jump() -> void:
	var c := _low_pitch()
	var start := c.pivot
	c.pan_zoom_begin(Vector2(590, 100), 100.0, VP)
	assert_true(c._ground_hit(Vector2(590, 100), VP, 0.0) == null, "begin misses")
	var last := start
	var first_hit_seen := false
	for y in range(100, 800, 20):
		var hit: Variant = c._ground_hit(Vector2(590, y), VP, 0.0)
		c.pan_zoom_update(Vector2(590, y), 100.0, VP)
		if hit == null or not first_hit_seen:
			assert_vec_near(c.pivot, start, 0.0, "no movement until first hit y=%d" % y)
		if hit != null:
			first_hit_seen = true
		last = c.pivot
	assert_true(first_hit_seen and c._anchored, "anchored after first hit")
	c.pan_zoom_update(Vector2(590, 790), 100.0, VP)
	assert_true(c.pivot.distance_to(last) < 60.0, "bounded step after re-baseline")


func test_horizon_pan_stays_in_world() -> void:
	var c := _low_pitch()
	c.pan_zoom_begin(Vector2(590, 800), 100.0, VP)
	for y in range(800, 150, -10):
		c.pan_zoom_update(Vector2(590, y), 100.0, VP)
		assert_true(absf(c.pivot.x) <= 127.5 and absf(c.pivot.z) <= 128.0, "bounded y=%d" % y)


func test_zero_viewport_is_ignored() -> void:
	var c := OrbitCameraController.new()
	var before := c.get_pose()
	c.orbit(Vector2(10, 10), Vector2.ZERO)
	assert_eq(c.get_pose(), before)
	var ray := c.screen_ray(Vector2(5, 5), Vector2(0, 100))
	assert_true(ray[0].is_finite() and ray[1].is_finite())


func test_orbit_sensitivity() -> void:
	var c := OrbitCameraController.new()
	c.distance = 140.0
	var yaw0 := c.yaw
	c.orbit(Vector2(VP.x, 0), VP)
	assert_near(rad_to_deg(yaw0 - c.yaw), 270.0, 1e-6, "far: 270 deg per width, drag right lowers yaw")
	c.distance = 3.0
	yaw0 = c.yaw
	c.orbit(Vector2(VP.x, 0), VP)
	assert_near(rad_to_deg(yaw0 - c.yaw), 270.0 * c.precision_factor(), 1e-6, "near: scaled")
	assert_true(c.precision_factor() < 0.5)


func test_defaults_match_json() -> void:
	var f := FileAccess.open("res://config/poc_defaults.json", FileAccess.READ)
	assert_true(f != null, "defaults json readable")
	if f == null:
		return
	var cam: Dictionary = JSON.parse_string(f.get_as_text())["camera"]
	for key: String in cam:
		assert_true(OrbitCameraController.DEFAULTS.has(key), "DEFAULTS has %s" % key)
		assert_near(float(OrbitCameraController.DEFAULTS[key]), float(cam[key]), 1e-9, key)
	assert_eq(OrbitCameraController.DEFAULTS.size(), cam.size(), "same key set")


func _hill(x: float, z: float) -> float:
	if x > 1000.0:
		return NAN
	return 30.0 * exp(-(x * x + z * z) / 2000.0)


func test_clearance_raises_camera_and_handles_nan() -> void:
	var c := OrbitCameraController.new()
	c.pivot = Vector3(0, 0, 0)
	c.distance = 10.0
	c.pitch = deg_to_rad(15.0)
	assert_true(c.camera_position().y < _hill(c.camera_position().x, c.camera_position().z) + 1.0)
	assert_true(c.apply_clearance(_hill), "adjusted")
	var p := c.camera_position()
	assert_true(p.y >= _hill(p.x, p.z) + 1.0 - 1e-4, "above ground")
	assert_false(c.apply_clearance(_hill), "already clear")
	var o := OrbitCameraController.new()
	o.pivot = Vector3(5000, -100, 0)
	var before := o.get_pose()
	assert_false(o.apply_clearance(_hill), "NAN = no adjustment")
	assert_eq(o.get_pose(), before)


func test_focus_bounds_frames_lodge() -> void:
	var c := OrbitCameraController.new()
	var box := AABB(Vector3(-6, 0, -5), Vector3(12, 8, 10))
	c.focus_bounds(box)
	assert_vec_near(c.pivot, box.get_center(), 1e-6)
	var r := box.size.length() * 0.5
	assert_true(c.distance * sin(deg_to_rad(c.fov_deg) * 0.5) >= r, "sphere fits")
	assert_true(c.distance <= 350.0 and c.distance >= 3.0)


func test_pose_roundtrip_and_fixture() -> void:
	var c := OrbitCameraController.new()
	var pose := c.fixture_pose(12.5)
	c.reset_to(pose)
	assert_near(c.pivot.y, 12.5, 0.0)
	assert_near(c.distance, 140.0, 0.0)
	c.orbit(Vector2(30, 10), VP)
	var p := c.get_pose()
	var d := OrbitCameraController.new()
	d.set_pose(p)
	assert_eq(d.camera_transform(), c.camera_transform())
