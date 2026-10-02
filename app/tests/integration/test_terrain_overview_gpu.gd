extends TestCase
## Desktop Vulkan evidence only. Device performance and adoption remain separate gates.

const SIZE := Vector2i(1024, 768)
const SKY := Color(0.1, 0.2, 0.6)
const AUTO := WorldConstants.DEFAULT_CONTROL
var _viewport: SubViewport
var _camera: Camera3D
var _adapter: TerrainAdapter
var _logger: TerrainLogger


class TerrainLogger extends Logger:
	var unexpected: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		var message := rationale if rationale != "" else code
		if not message.contains("instance_reset_physics_interpolation() is deprecated"):
			unexpected.append("%s (%s:%d %s)" % [message, file, line, function])

	func _log_message(_message: String, _error: bool) -> void:
		pass


func after_each() -> void:
	if _viewport != null:
		tree.root.remove_child(_viewport)
		_viewport.free()
	_viewport = null
	if _logger != null:
		assert_eq(_logger.unexpected, PackedStringArray(), "unexpected engine errors")
		OS.remove_logger(_logger)
	_logger = null


func _make(doc: WorldDocument) -> void:
	allow_logged_errors()
	_logger = TerrainLogger.new()
	OS.add_logger(_logger)
	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(_viewport)
	_camera = Camera3D.new()
	_camera.current = true
	_viewport.add_child(_camera)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.0
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_viewport.add_child(world_environment)
	_adapter = TerrainAdapter.new()
	_viewport.add_child(_adapter)
	_adapter.set_camera(_camera)
	assert_empty_string(_adapter.initialize(doc))


func _available() -> bool:
	if RenderingServer.get_rendering_device() == null:
		print("    terrain overview: NOT RUN: no rendering device")
		return false
	return true


func _render(name: String) -> Image:
	for frame in 12:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	if image != null and image.is_compressed():
		image.decompress()
	if image == null or image.is_empty():
		print("    terrain overview: NOT RUN: empty viewport readback")
		return null
	var brightest := 0.0
	for y in range(0, image.get_height(), 16):
		for x in range(0, image.get_width(), 16):
			var color := image.get_pixel(x, y)
			brightest = maxf(brightest, maxf(color.r, maxf(color.g, color.b)))
	if brightest < 0.02:
		print("    terrain overview: NOT RUN: black viewport readback")
		return null
	var directory := OS.get_environment("WP_SHADER_EVIDENCE_DIR")
	if directory != "":
		DirAccess.make_dir_recursive_absolute(directory)
		assert_eq(image.save_png(directory.path_join(name + ".png")), OK)
	return image


func _pixel(image: Image, point: Vector3) -> Color:
	var screen := _camera.unproject_position(point)
	assert_false(_camera.is_position_behind(point), "probe behind camera: %s" % point)
	assert_true(Rect2(Vector2.ZERO, Vector2(SIZE)).has_point(screen), "probe outside viewport: %s" % point)
	return image.get_pixel(clampi(int(screen.x), 0, SIZE.x - 1), clampi(int(screen.y), 0, SIZE.y - 1))


func _distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


func _km1_document() -> WorldDocument:
	var doc := WorldDocument.create_flat(12.0, AUTO, WorldLayout.km1())
	for location: Vector2i in doc.regions:
		var region := doc.get_region(location)
		for z in 256:
			for x in 256:
				var wx := float(location.x * 256 + x) * 0.5
				var wz := float(location.y * 256 + z) * 0.5
				region.heights[z * 256 + x] = 12.0 + wx * 0.05
				if absf(wx) < 48.0 and absf(wz) < 48.0:
					region.control[z * 256 + x] = AUTO | ControlCodec.HOLE_BIT
	doc.invalidate_all_height_ranges()
	return doc


func _check_extent(image: Image) -> void:
	var background := image.get_pixel(0, 0)
	for point in [Vector2(-490, -490), Vector2(490, -490), Vector2(-490, 490), Vector2(490, 490),
			Vector2(-0.5, -250), Vector2(0.5, -250), Vector2(-250, -0.5), Vector2(-250, 0.5)]:
		var difference := _distance(_pixel(image, Vector3(point.x, 12.0 + point.x * 0.05, point.y)), background)
		assert_true(difference > 0.15, "authored terrain missing at %s; camera %s; color distance %.3f" %
			[point, _camera.position, difference])
	assert_true(_distance(_pixel(image, Vector3(0, 12, 0)), background) < 0.02, "hole exposes background")
	for point in [Vector2(-560, 0), Vector2(560, 0), Vector2(0, -560), Vector2(0, 560)]:
		assert_true(_distance(_pixel(image, Vector3(point.x, 12.0 + point.x * 0.05, point.y)), background) < 0.02,
			"terrain extends beyond authored bounds at %s" % point)


func test_gpu_km1_max_zoom_preserves_finite_extent_holes_and_height_in_both_modes() -> void:
	if not _available():
		return
	var doc := _km1_document()
	_make(doc)
	assert_eq(_adapter.geometry_uniforms(), {"terrain_world_bounds": Vector4(-512, -512, 511.5, 511.5)})
	var controller := OrbitCameraController.new()
	controller.set_world_rect(doc.layout.world_rect(), Vector2(SIZE))
	_camera.far = controller.distance_max() + doc.layout.world_rect().size.length() + 100.0
	assert_empty_string(_adapter.set_debug_view("heightmap"))
	for pitch in [15.0, 80.0]:
		controller.reset_to({"pivot": Vector3(0, 12, 0), "pitch": deg_to_rad(pitch),
			"yaw": deg_to_rad(30.0), "distance": controller.distance_max()})
		_camera.transform = controller.camera_transform()
		_camera.fov = controller.fov_deg
		assert_empty_string(_adapter.set_material_mode("full"))
		var full: Image = await _render("km1_max_zoom_full_%d" % int(pitch))
		if full == null:
			return
		_check_extent(full)
		assert_empty_string(_adapter.set_material_mode("overview_experiment"))
		var experiment: Image = await _render("km1_max_zoom_experiment_%d" % int(pitch))
		if experiment == null:
			return
		assert_eq(full.get_data(), experiment.get_data(), "height/debug projection unchanged at pitch %s" % pitch)
	assert_eq(_adapter.verify_matches_document(doc), PackedStringArray())
	assert_empty_string(_adapter.replace_document(WorldDocument.create_flat(0.0, AUTO)))
	assert_eq(_adapter.geometry_uniforms(), {"terrain_world_bounds": Vector4(-128, -128, 127.5, 127.5)})


func _paint_document() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	for location: Vector2i in doc.regions:
		var region := doc.get_region(location)
		for z in 256:
			for x in 256:
				var wx := float(location.x * 256 + x) * 0.5
				var wz := float(location.y * 256 + z) * 0.5
				var index := z * 256 + x
				region.heights[index] = clampf(wx, 0.0, 16.0) * 1.7320508
				if wz > 20.0:
					var slot := clampi(int(floor((wx + 80.0) / 40.0)), 0, 3)
					region.control[index] = ControlCodec.encode(AUTO, {"base_id": slot, "auto": false, "blend": 0})
				elif absf(wz) < 8.0:
					region.control[index] = ControlCodec.encode(AUTO, {"overlay_id": 1, "blend": 128})
	doc.invalidate_all_height_ranges()
	return doc


func _height(x: float) -> float:
	return clampf(x, 0.0, 16.0) * 1.7320508


func _hue(color: Color) -> Vector3:
	return Vector3(color.r, color.g, color.b) / maxf(color.r + color.g + color.b, 0.001)


func test_gpu_overview_material_keeps_paint_hues_and_terrain_slope_normals() -> void:
	if not _available():
		return
	var doc := _paint_document()
	_make(doc)
	_camera.look_at_from_position(Vector3(0, 180, 0.01), Vector3.ZERO, Vector3(0, 0, -1))
	_camera.fov = 60.0
	var full: Image = await _render("paint_full")
	if full == null:
		return
	assert_empty_string(_adapter.set_material_mode("overview_experiment"))
	var experiment: Image = await _render("paint_experiment")
	if experiment == null:
		return
	var background := full.get_pixel(0, 0)
	for point in [Vector2(-60, 45), Vector2(-20, 45), Vector2(20, 45), Vector2(60, 45),
			Vector2(-40, 0), Vector2(8, 0)]:
		var position := Vector3(point.x, _height(point.x), point.y)
		var before := _pixel(full, position)
		var after := _pixel(experiment, position)
		assert_true(_distance(before, background) > 0.1, "paint probe rendered at %s" % point)
		assert_true(_hue(before).distance_to(_hue(after)) < 0.025, "paint hue retained at %s" % point)
		if point.y == 45:
			var slot := clampi(int(floor((point.x + 80.0) / 40.0)), 0, 3)
			assert_true(_hue(before).distance_to(_hue(TerrainMaterials.ALBEDO[slot])) < 0.05,
				"material slot %d visible at %s" % [slot, point])
	assert_empty_string(_adapter.set_debug_view("normals"))
	var experiment_normals: Image = await _render("normals_experiment")
	assert_empty_string(_adapter.set_material_mode("full"))
	var full_normals: Image = await _render("normals_full")
	if experiment_normals == null or full_normals == null:
		return
	assert_eq(experiment_normals.get_data(), full_normals.get_data(), "terrain normal projection unchanged")
	assert_true(_distance(_pixel(full_normals, Vector3(-40, 0, -40)),
		_pixel(full_normals, Vector3(8, _height(8), -40))) > 0.15, "slope changes terrain normal")
	assert_eq(_adapter.verify_matches_document(doc), PackedStringArray())
