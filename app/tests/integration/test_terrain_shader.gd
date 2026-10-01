extends TestCase
## Project terrain shader (res://src/terrain/world_terrain.gdshader): rule/highlight uniforms,
## tint map upload and verification (headless), and rendered pixel checks (tests whose name
## contains "gpu" run only in a windowed run: scripts/dev.py test --rendered).
## Set WP_SHADER_EVIDENCE_DIR to also write gentle_hills screenshots there.

const KNOWN_T3D_WARNING := "instance_reset_physics_interpolation() is deprecated"
const AUTO := WorldConstants.DEFAULT_CONTROL
const VIEW_SIZE := Vector2i(1024, 768)
const RAMP_SLOPE := 1.7320508  # tan(60 deg)


class KnownWarningFilter extends Logger:
	var unexpected: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if rationale != "" else code
		if not text.contains(KNOWN_T3D_WARNING):
			unexpected.append("%s (%s:%d %s)" % [text, file, line, function])

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _root: Node
var _filter: KnownWarningFilter
var _adapter: TerrainAdapter
var _cam: Camera3D


func after_each() -> void:
	tree.paused = false
	if _root != null and is_instance_valid(_root):
		_root.get_parent().remove_child(_root)
		_root.free()
	_root = null
	_adapter = null
	if _filter != null:
		assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))
		OS.remove_logger(_filter)
		_filter = null


## `_root` is a SubViewport with its own World3D so rendered tests do not see other tests' nodes.
func _make(doc: WorldDocument) -> TerrainAdapter:
	allow_logged_errors()
	_filter = KnownWarningFilter.new()
	OS.add_logger(_filter)
	var vp := SubViewport.new()
	vp.size = VIEW_SIZE
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(vp)
	_root = vp
	_cam = Camera3D.new()
	vp.add_child(_cam)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.7, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	vp.add_child(sun)
	var a := TerrainAdapter.new()
	vp.add_child(a)
	a.set_camera(_cam)
	assert_empty_string(a.initialize(doc), "initialize")
	_adapter = a
	return a


## Headless runs (dummy renderer) expose no shader parameter list, so uniforms are checked on the
## adapter; in a rendered run the material's own value must agree.
func _check_uniform(key: String, expected: Variant) -> void:
	assert_eq(_adapter.rule_uniforms()[key], expected, key)
	var live: Variant = _adapter.get_terrain().material.get_shader_param(key)
	if live != null:
		assert_eq(live, expected, "material " + key)


# --- headless: uniforms ------------------------------------------------------------------------

func test_project_shader_is_active_and_rules_map_to_uniforms() -> void:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	doc.rules.rock_enabled = false
	doc.rules.rock_slope_deg = 45
	doc.rules.sand_enabled = true
	doc.rules.sand_height_dm = -12
	var a := _make(doc)
	var mat := a.get_terrain().material
	assert_true(mat.shader_override_enabled, "shader override enabled")
	assert_true(mat.shader_override.code.contains("rules_highlight"), "project shader loaded")
	_check_uniform("rules_rock_enabled", false)
	_check_uniform("rules_rock_slope_deg", 45.0)
	_check_uniform("rules_sand_enabled", true)
	_check_uniform("rules_sand_height_m", -1.2)
	var rules := TerrainRules.defaults()
	rules.sand_enabled = false
	rules.sand_height_dm = 7
	a.set_rules(rules)
	_check_uniform("rules_sand_enabled", false)
	_check_uniform("rules_sand_height_m", 0.7)
	_check_uniform("rules_rock_enabled", true)


func test_highlight_toggle_and_replace_document_reapplies_rules() -> void:
	var a := _make(WorldDocument.create_flat(0.0, AUTO))
	assert_false(a.get_rule_highlight())
	_check_uniform("rules_highlight", false)
	a.set_rule_highlight(true)
	assert_true(a.get_rule_highlight())
	_check_uniform("rules_highlight", true)
	var doc2 := WorldDocument.create_flat(0.0, AUTO)
	doc2.rules.rock_slope_deg = 55
	assert_empty_string(a.replace_document(doc2))
	_check_uniform("rules_rock_slope_deg", 55.0)
	assert_true(a.get_rule_highlight(), "highlight survives replace_document")
	a.set_rule_highlight(false)
	_check_uniform("rules_highlight", false)


# --- headless: tint map upload -----------------------------------------------------------------

func _tint(doc: WorldDocument, loc: Vector2i, idx: int, rgba: Array) -> void:
	var rb := doc.get_region(loc)
	for c in 4:
		rb.color[idx * 4 + c] = rgba[c]


func test_color_map_uploads_document_tint_bytes() -> void:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	_tint(doc, Vector2i(-1, -1), 77, [10, 20, 30, 200])
	var a := _make(doc)
	var img: Image = a.get_terrain().data.get_region(Vector2i(-1, -1)).get_color_map()
	assert_eq(img.get_format(), Image.FORMAT_RGBA8)
	assert_eq(img.get_data().slice(77 * 4, 77 * 4 + 4), PackedByteArray([10, 20, 30, 200]), "tint sample")
	assert_eq(img.get_data().slice(0, 4), PackedByteArray([255, 255, 255, 0]), "default tint = weight 0")
	assert_eq(a.verify_matches_document(doc).size(), 0)


func test_color_dirty_batching_uploads_each_region_once_per_flush() -> void:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	var a := _make(doc)
	assert_false(a.has_pending_uploads())
	for loc in doc.sorted_region_locations().slice(0, 3):
		_tint(doc, loc, 5, [1, 2, 3, 255])
		assert_empty_string(a.mark_dirty(TerrainView.MAP_COLOR, loc))
		assert_empty_string(a.mark_dirty(TerrainView.MAP_COLOR, loc), "duplicate mark is idempotent")
	assert_true(a.has_pending_uploads())
	assert_eq(a.verify_matches_document(doc).size(), 3, "pending tint edits are reported")
	a.flush()
	assert_false(a.has_pending_uploads())
	assert_eq(a.stats().uploads_color, 3)
	assert_eq(a.stats().uploads_height, 0)
	assert_eq(a.stats().uploads_control, 0)
	assert_eq(a.verify_matches_document(doc).size(), 0, "tint uploaded")
	_tint(doc, Vector2i(0, 0), 9, [4, 5, 6, 7])
	a.mark_dirty(TerrainView.MAP_COLOR, Vector2i(0, 0))
	a.flush()
	assert_true(a.has_pending_uploads(), "second colour flush in the same frame is deferred")
	assert_eq(a.stats().uploads_color, 3)
	await tree.process_frame
	await tree.process_frame
	assert_false(a.has_pending_uploads(), "deferred colour upload ran")
	assert_eq(a.stats().uploads_color, 4)
	assert_error_contains(a.mark_dirty(TerrainView.MAP_COLOR, Vector2i(9, 9)), "not loaded")


func test_verify_detects_color_mismatch_with_sample_index() -> void:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	var a := _make(doc)
	_tint(doc, Vector2i(0, -1), 1234, [9, 9, 9, 9])
	var out := a.verify_matches_document(doc)
	assert_eq(out.size(), 1, "one mismatch: %s" % out)
	assert_true(out.size() > 0 and out[0].contains("color") and out[0].contains("1234"), "names map and index: %s" % out)


# --- rendered ----------------------------------------------------------------------------------

## Ground height of the probe world: flat 3 m, a 60 degree ramp for x in [10, 20] that ends on a
## plateau, a shallow drop to -2 m for z in [30, 45].
static func _probe_height(x: float, z: float) -> float:
	var h := 3.0 + clampf(x - 10.0, 0.0, 10.0) * RAMP_SLOPE
	return h - clampf(z - 30.0, 0.0, 15.0) * (5.0 / 15.0)


func _probe_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			var z: float = (loc.y * 256 + j) * 0.5
			for i in WorldConstants.REGION_SAMPLES:
				r.heights[j * 256 + i] = _probe_height((loc.x * 256 + i) * 0.5, z)
		var o := Vector2i(loc.x * 256, loc.y * 256)
		for j in WorldConstants.REGION_SAMPLES:
			for i in WorldConstants.REGION_SAMPLES:
				var x := (o.x + i) * 0.5
				var z := (o.y + j) * 0.5
				var k := j * 256 + i
				if absf(z) <= 8.0 and x >= -40.0 and x <= -30.0:
					# Manual dirt overlay over the rule layer: auto bit stays set.
					r.control[k] = ControlCodec.encode(AUTO, {"overlay_id": WorldConstants.MATERIAL_DIRT, "blend": 255})
				if absf(z) <= 8.0 and x >= -20.0 and x <= -10.0:
					for c in 4:
						r.color[k * 4 + c] = [0, 0, 255, 255][c]
	doc.invalidate_all_height_ranges()
	return doc


func _aim_top_down() -> void:
	_cam.look_at_from_position(Vector3(-25, 120, 35), Vector3(-25, 0, 35), Vector3(0, 0, -1))
	_cam.fov = 60.0
	_cam.current = true


## Mean colour of a 7x7 pixel block around the screen position of the world point.
func _probe(img: Image, x: float, z: float) -> Color:
	var p := _cam.unproject_position(Vector3(x, _probe_height(x, z), z))
	var sum := Color(0, 0, 0, 0)
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			sum += img.get_pixel(clampi(int(p.x) + dx, 0, img.get_width() - 1), clampi(int(p.y) + dy, 0, img.get_height() - 1))
	return sum / 49.0


func _render(frames := 12) -> Image:
	for i in frames:
		await tree.process_frame
	var img := (_root as SubViewport).get_texture().get_image()
	if img != null and img.is_compressed():
		img.decompress()
	return img


func _rendered_available() -> bool:
	if RenderingServer.get_rendering_device() == null:
		print("    rendered shader checks: NOT RUN: no rendering device (headless); run scripts/dev.py test --rendered")
		return false
	return true


static func _is_greenish(c: Color) -> bool:
	return c.g > c.r * 1.15 and c.g > c.b * 1.4


static func _is_greyish(c: Color) -> bool:
	return maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.14 * maxf(c.r, maxf(c.g, c.b))


static func _is_sandish(c: Color) -> bool:
	return c.r > c.b * 1.25 and c.r / c.g < 1.2 and c.g > c.b * 1.1


static func _is_dirtish(c: Color) -> bool:
	return c.r / c.g > 1.25 and c.g > c.b


func test_gpu_rendered_rules_overlay_tint_and_highlight() -> void:
	if not _rendered_available():
		return
	var a := _make(_probe_doc())
	_aim_top_down()
	var img := await _render()
	var grass := _probe(img, -60, 0)
	var rock := _probe(img, 15, 0)
	var sand := _probe(img, -40, 60)
	var dirt := _probe(img, -35, 0)
	var tint := _probe(img, -15, 0)
	var driver := RenderingServer.get_current_rendering_driver_name()
	print("    probes (%s): grass %s rock %s sand %s dirt %s tint %s" % [driver, grass, rock, sand, dirt, tint])
	assert_true(_is_greenish(grass), "flat auto area reads grass: %s" % grass)
	assert_true(_is_greyish(rock), "steep auto slope reads rock: %s" % rock)
	assert_true(_is_sandish(sand), "auto area below the sand height reads sand: %s" % sand)
	assert_true(_is_dirtish(dirt), "manual dirt overlay over a rule area reads dirt: %s" % dirt)
	assert_true(tint.b > tint.g and tint.b / maxf(tint.g, 0.001) > 2.0 * grass.b / grass.g,
		"tint patch shifts hue toward the tint colour: %s vs %s" % [tint, grass])

	var rules := a.get_document().rules.clone()
	rules.rock_enabled = false
	a.set_rules(rules)
	img = await _render(4)
	assert_true(_is_greenish(_probe(img, 15, 0)), "rock rule off: slope falls back to grass")
	rules.rock_enabled = true
	rules.sand_enabled = false
	a.set_rules(rules)
	img = await _render(4)
	assert_true(_is_greenish(_probe(img, -40, 60)), "sand rule off: low ground falls back to grass")
	rules.sand_enabled = true
	a.set_rules(rules)

	a.set_rule_highlight(true)
	img = await _render(4)
	var hl_rock := _probe(img, 15, 0)
	var hl_sand := _probe(img, -40, 60)
	var hl_grass := _probe(img, -60, 0)
	assert_true(hl_rock.r > hl_rock.b * 1.6 and hl_rock.g > hl_rock.b * 1.3, "highlighted rock area is yellowish: %s" % hl_rock)
	assert_true(hl_sand.r > sand.r and hl_sand.b < sand.b, "highlighted sand area shifts yellow: %s vs %s" % [hl_sand, sand])
	assert_true(_is_greenish(hl_grass), "highlight leaves grass alone: %s" % hl_grass)
	_save_shot(img, "probe_highlight_on.png")


func test_gpu_rendered_gentle_hills_evidence() -> void:
	if not _rendered_available():
		return
	var loaded := AssetCatalog.load_from()
	assert_empty_string(loaded[1], "catalog")
	var fx := SessionWorldOps.load_fixture("gentle_hills", loaded[0])
	assert_empty_string(fx[1], "fixture")
	var doc: WorldDocument = fx[0]
	var a := _make(doc)
	_cam.look_at_from_position(Vector3(0, 55, 95), Vector3(0, 0, 0), Vector3.UP)
	_cam.current = true
	var rules_on := await _render(14)
	_save_shot(rules_on, "gentle_hills_rules_on.png")
	var rules := doc.rules.clone()
	rules.rock_enabled = false
	rules.sand_enabled = false
	a.set_rules(rules)
	var rules_off := await _render(4)
	_save_shot(rules_off, "gentle_hills_rules_off.png")
	a.set_rules(doc.rules)
	a.set_rule_highlight(true)
	var highlighted := await _render(4)
	_save_shot(highlighted, "gentle_hills_highlight_on.png")
	assert_true(rules_on.get_data() != rules_off.get_data(), "rules change the picture")
	assert_true(rules_on.get_data() != highlighted.get_data(), "highlight changes the picture")
	assert_eq(a.verify_matches_document(doc).size(), 0)
	assert_eq(a.verify_gpu(), PackedStringArray(), "GPU layers match")


func _save_shot(img: Image, file: String) -> void:
	var dir := OS.get_environment("WP_SHADER_EVIDENCE_DIR")
	if dir == "" or img == null:
		return
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join(file))
