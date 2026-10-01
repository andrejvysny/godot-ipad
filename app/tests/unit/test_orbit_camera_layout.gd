extends TestCase
## Layout-aware camera framing (docs/rendering-performance-spec.md §16.5): the legacy world keeps its
## exact values; a larger world is framed whole, reachable by zoom and pan, and inside the far plane.

const WIDE := Vector2i(1180, 820)
const TALL := Vector2i(820, 1180)

var _viewports: Array[SubViewport] = []


func after_each() -> void:
	for vp in _viewports:
		tree.root.remove_child(vp)
		vp.free()
	_viewports.clear()


func _rig(size: Vector2i, rect: Rect2) -> OrbitCameraRig:
	var vp := SubViewport.new()
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tree.root.add_child(vp)
	_viewports.append(vp)
	var rig := OrbitCameraRig.new(JSON.parse_string(FileAccess.get_file_as_string("res://config/poc_defaults.json")).camera)
	vp.add_child(rig)
	rig.set_world_rect(rect)
	return rig


func _corners(rect: Rect2, y: float) -> Array[Vector3]:
	return [Vector3(rect.position.x, y, rect.position.y), Vector3(rect.end.x, y, rect.position.y),
		Vector3(rect.position.x, y, rect.end.y), Vector3(rect.end.x, y, rect.end.y)]


func test_legacy_world_keeps_its_exact_camera_values() -> void:
	var rect := WorldLayout.legacy().world_rect()
	var rig := _rig(WIDE, rect)
	assert_eq(rig.get_camera().far, 2000.0)
	assert_eq(rig.controller.distance_max(), 350.0)
	var pose := rig.controller.fixture_pose(3.0)
	assert_eq(pose.distance, 140.0)
	assert_eq(pose.pivot, Vector3(0.0, 3.0, 0.0))
	rig.reset_to(pose)
	assert_eq(rig.controller.distance, 140.0)
	var plain := OrbitCameraController.new()
	assert_eq(plain.distance_max(), 350.0, "a controller never given a rect is the legacy one")
	assert_eq(plain.fixture_pose(3.0).distance, 140.0)
	assert_eq(plain.world_rect(), rect)


func test_km1_reset_view_shows_all_four_corners_in_landscape_and_portrait() -> void:
	var rect := WorldLayout.km1().world_rect()
	for size in [WIDE, TALL, Vector2i(1024, 768)]:
		var rig := _rig(size, rect)
		rig.reset_to(rig.controller.fixture_pose(0.0))
		var cam := rig.get_camera()
		var view := Rect2(Vector2.ZERO, Vector2(size))
		for corner in _corners(rect, 0.0):
			assert_false(cam.is_position_behind(corner), "corner %s in front, viewport %s" % [str(corner), str(size)])
			assert_true(view.has_point(cam.unproject_position(corner)),
					"corner %s at %s inside viewport %s" % [str(corner), str(cam.unproject_position(corner)), str(size)])
		assert_true(rig.controller.distance > 350.0, "framing needs more than the legacy range")


func test_km1_far_plane_reaches_the_farthest_corner_from_the_farthest_camera() -> void:
	var rect := WorldLayout.km1().world_rect()
	var rig := _rig(WIDE, rect)
	var far := rig.get_camera().far
	assert_true(far > 2000.0, "far %.0f" % far)
	assert_true(far >= rig.controller.distance_max() + rect.size.length() + 100.0 - 1e-6)
	# Camera at maximum distance on the far side of the pivot: every world point stays inside the far plane.
	for yaw in [0.0, 1.0, 2.5, 4.0]:
		rig.reset_to({"pivot": Vector3(0, 0, 0), "yaw": yaw, "pitch": deg_to_rad(15.0), "distance": rig.controller.distance_max()})
		var origin := rig.get_camera().global_position
		for corner in _corners(rect, 0.0):
			assert_true(origin.distance_to(corner) < far, "corner reachable at yaw %.1f" % yaw)


func test_km1_zoom_out_reaches_the_fitted_distance_and_the_pivot_roams_the_whole_world() -> void:
	var c := OrbitCameraController.new()
	var rect := WorldLayout.km1().world_rect()
	c.set_world_rect(rect)
	var fit := c.fit_distance(deg_to_rad(30.0), deg_to_rad(45.0), 1180.0 / 820.0)
	assert_true(c.distance_max() >= fit * OrbitCameraController.MAX_DISTANCE_HEADROOM - 1e-6)
	assert_true(c.distance_max() > 350.0)
	c.reset_to(c.fixture_pose(0.0))
	assert_near(c.distance, fit, 1e-6, "reset frames the world")
	c.pan_zoom_begin(Vector2(590, 410), 100.0, Vector2(1180, 820))
	c.pan_zoom_update(Vector2(590, 410), 1.0, Vector2(1180, 820))
	assert_near(c.distance, c.distance_max(), 1e-6, "zoom stops at the layout maximum")
	# Drag across the ground repeatedly: the pivot passes the legacy +-128 m and stops at the layout edge.
	var vp := Vector2(1180, 820)
	for _i in 4:
		c.end()
		c.pan_zoom_begin(Vector2(900, 410), 100.0, vp)
		c.pan_zoom_update(Vector2(100, 410), 100.0, vp)
		assert_true(c.pivot.x >= rect.position.x and c.pivot.x <= rect.end.x and c.pivot.z >= rect.position.y
				and c.pivot.z <= rect.end.y, "pivot %s inside %s" % [str(c.pivot), str(rect)])
	assert_true(absf(c.pivot.x) > 128.0 or absf(c.pivot.z) > 128.0, "pivot left the legacy extent: %s" % str(c.pivot))


func test_returning_to_the_legacy_world_restores_its_limits() -> void:
	var rig := _rig(WIDE, WorldLayout.km1().world_rect())
	assert_true(rig.get_camera().far > 2000.0)
	rig.set_world_rect(WorldLayout.legacy().world_rect())
	assert_eq(rig.get_camera().far, 2000.0)
	assert_eq(rig.controller.distance_max(), 350.0)
	rig.reset_to(rig.controller.fixture_pose(0.0))
	assert_eq(rig.controller.distance, 140.0)
