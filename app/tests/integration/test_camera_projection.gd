extends TestCase
## Controller screen_ray must match Camera3D projection (CA-01 support).


func test_screen_ray_matches_camera3d() -> void:
	var size := Vector2i(1180, 820)
	var vp := SubViewport.new()
	vp.size = size
	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	tree.root.add_child(vp)
	var c := OrbitCameraController.new()
	c.pivot = Vector3(10, 4, -20)
	c.yaw = 0.7
	c.pitch = deg_to_rad(40.0)
	c.distance = 75.0
	cam.transform = c.camera_transform()
	cam.fov = c.fov_deg
	cam.current = true
	await tree.process_frame
	var fsize := Vector2(size)
	for fx in [0.0, 0.5, 1.0]:
		for fy in [0.0, 0.5, 1.0]:
			var pos := Vector2(fx * fsize.x, fy * fsize.y)
			var ray := c.screen_ray(pos, fsize)
			assert_vec_near(ray[0], cam.project_ray_origin(pos), 1e-4, "origin %s" % pos)
			assert_vec_near(ray[1], cam.project_ray_normal(pos), 1e-4, "dir %s" % pos)
	vp.queue_free()
	await tree.process_frame


func test_rig_actions_and_freeze() -> void:
	var rig := OrbitCameraRig.new()
	tree.root.add_child(rig)
	await tree.process_frame
	var t0 := rig.get_camera().global_transform
	rig.handle_camera_action({"type": "camera_orbit", "delta": Vector2(50, 0)})
	assert_ne(rig.get_camera().global_transform, t0, "orbit moved camera")
	rig.frozen = true
	var t1 := rig.get_camera().global_transform
	rig.handle_camera_action({"type": "camera_orbit", "delta": Vector2(50, 0)})
	assert_eq(rig.get_camera().global_transform, t1, "frozen ignores motion")
	rig.frozen = false
	rig.handle_camera_action({"type": "camera_pan_zoom_begin", "centroid": Vector2(500, 400), "span": 100.0})
	rig.handle_camera_action({"type": "camera_pan_zoom", "centroid": Vector2(500, 400), "span": 200.0})
	assert_true(rig.controller.distance < 140.0, "zoomed")
	assert_eq(rig.get_camera().transform, rig.controller.camera_transform(), "camera follows controller")
	assert_near(rig.get_camera().fov, rig.controller.fov_deg, 1e-6, "fov follows controller")
	rig.handle_camera_action({"type": "camera_end", "reason": "test"})
	assert_false(rig.controller._gesture_active, "end drops baselines")
	rig.handle_camera_action({"type": "camera_orbit_begin"})
	assert_false(rig.controller._gesture_active)
	rig.queue_free()
	await tree.process_frame


func test_rig_clearance_and_begin_frame() -> void:
	var rig := OrbitCameraRig.new()
	tree.root.add_child(rig)
	await tree.process_frame
	rig.reset_to({"pivot": Vector3.ZERO, "pitch": deg_to_rad(20.0), "distance": 20.0})
	rig.height_sampler = func(_x: float, _z: float) -> float: return 30.0
	var t0 := rig.get_camera().transform
	rig.handle_camera_action({"type": "camera_pan_zoom_begin", "centroid": Vector2(500, 400), "span": 100.0})
	assert_eq(rig.get_camera().transform, t0, "begin frame does not move camera")
	rig.handle_camera_action({"type": "camera_orbit", "delta": Vector2(1, 0)})
	assert_true(rig.get_camera().position.y >= 31.0 - 1e-4, "clearance applied on motion")
	assert_eq(rig.get_camera().transform, rig.controller.camera_transform())
	rig.queue_free()
	await tree.process_frame
