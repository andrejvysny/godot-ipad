extends TestCase
## Rendered reproduction harness for terrain paint defects (Plane GODOTIPAD-2): paints with the real
## PaintStroke on flat ground, uploads through TerrainAdapter and saves screenshots + prints control
## values. Documents behaviour only; it never asserts the defects are fixed. Rendered runs only:
##   WP_PAINT_EVIDENCE_DIR=/abs/dir python3 scripts/dev.py test --rendered --filter paint_repro
## (dev.py --rendered defaults the filter to "gpu"; the test names below contain it too.)

const KNOWN_T3D_WARNING := "instance_reset_physics_interpolation() is deprecated"
const AUTO := WorldConstants.DEFAULT_CONTROL
const VIEW_SIZE := Vector2i(1024, 768)
const ROCK := WorldConstants.MATERIAL_ROCK
const DIRT := WorldConstants.MATERIAL_DIRT
const SAND := WorldConstants.MATERIAL_SAND


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


func _rendered_available() -> bool:
	if RenderingServer.get_rendering_device() == null:
		print("    paint repro: NOT RUN: no rendering device (headless); run scripts/dev.py test --rendered")
		return false
	return true


func _render(frames := 10) -> Image:
	for i in frames:
		await tree.process_frame
	var img := (_root as SubViewport).get_texture().get_image()
	if img != null and img.is_compressed():
		img.decompress()
	return img


func _save_shot(img: Image, file: String) -> void:
	var dir := OS.get_environment("WP_PAINT_EVIDENCE_DIR")
	if dir == "" or img == null:
		return
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join(file))


## Looks at (x, z) from straight above (top_down) or from the south at 45 degrees; `dist` is the
## camera height (top_down) or the distance to the target (oblique).
func _aim(x: float, z: float, dist: float, top_down: bool) -> void:
	var target := Vector3(x, 0, z)
	if top_down:
		_cam.look_at_from_position(target + Vector3(0, dist, 0), target, Vector3(0, 0, -1))
	else:
		_cam.look_at_from_position(target + Vector3(0, dist * 0.7, dist * 0.7), target, Vector3.UP)
	_cam.fov = 60.0
	_cam.far = 3000.0
	_cam.current = true


func _shot(name: String, x: float, z: float, dist: float, top_down: bool) -> void:
	_aim(x, z, dist, top_down)
	var img := await _render()
	_save_shot(img, name)


# --- document helpers ----------------------------------------------------------------------------

func _set_control(doc: WorldDocument, gx: int, gz: int, value: int) -> void:
	var rb := doc.get_region(Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT))
	rb.control[(gz & 255) * WorldConstants.REGION_SAMPLES + (gx & 255)] = value


func _mixed_doc(layout: WorldLayout) -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, AUTO, layout)
	var mix := ControlCodec.encode(0, {"base_id": WorldConstants.MATERIAL_GRASS,
			"overlay_id": DIRT, "blend": 128, "auto": false})
	for gz in range(-40, 40):  # 40 x 40 m at 0.5 m spacing
		for gx in range(-40, 40):
			_set_control(doc, gx, gz, mix)
	return doc


func _settings(layer: int, op: String, strength: float, radius: float) -> Dictionary:
	return {"op": op, "layer": layer, "strength": strength, "radius": radius, "shape": "soft",
			"alpha_mode": "circle", "pressure_enabled": false, "seed": 7.0}


## Paints `path` (world XZ points, 1 m steps between them) like a tool drag and uploads the result.
func _stroke(doc: WorldDocument, settings: Dictionary, a: Vector2, b: Vector2) -> void:
	var tx := EditTransaction.new()
	tx.begin(doc, "paint", "Paint", settings)
	var s := PaintStroke.new()
	var dirty := {}
	var res := s.begin(doc, tx, settings, a, 1.0)
	for loc: Vector2i in res.dirty_controls:
		dirty[loc] = true
	var steps := maxi(1, int(a.distance_to(b)))
	for i in range(1, steps + 1):
		res = s.add_sample(float(i) / 60.0, a.lerp(b, float(i) / steps), 1.0)
		assert_empty_string(res.error, "paint error")
		for loc: Vector2i in res.dirty_controls:
			dirty[loc] = true
	s.finish(1.0)
	tx.finish()
	for loc: Vector2i in dirty:
		assert_empty_string(_adapter.mark_dirty(TerrainView.MAP_CONTROL, loc), "mark_dirty %s" % loc)
	_adapter.flush()


## One line: x:base/overlay/blend for samples on the centre line z every 1 m from x0 to x1.
func _print_line(doc: WorldDocument, label: String, z: float, x0: int, x1: int) -> void:
	var gz := int(round(z / WorldConstants.SAMPLE_SPACING))
	var parts := PackedStringArray()
	for x in range(x0, x1 + 1):
		var v := doc.get_control_at_sample(int(round(x / WorldConstants.SAMPLE_SPACING)), gz)
		parts.append("%d:%d/%d/%d%s" % [x, ControlCodec.get_base(v), ControlCodec.get_overlay(v),
				ControlCodec.get_blend(v), "a" if (v & ControlCodec.AUTO_BIT) != 0 else ""])
	print("    PAINT_REPRO %s z=%s (x:base/overlay/blend, a=auto bit): %s" % [label, str(z), " ".join(parts)])


func _count_changed(before: Dictionary, doc: WorldDocument) -> int:
	var n := 0
	for loc: Vector2i in before:
		var a: PackedInt32Array = before[loc]
		var b: PackedInt32Array = doc.get_region(loc).control
		for i in a.size():
			if a[i] != b[i]:
				n += 1
	return n


func _snapshot(doc: WorldDocument) -> Dictionary:
	var out := {}
	for loc: Vector2i in doc.regions:
		out[loc] = doc.get_region(loc).control.duplicate()
	return out


## Uploads are guarded per frame, so let a few frames pass before reading the GPU back.
func _check_gpu(label: String) -> void:
	for i in 3:
		await tree.process_frame
		_adapter.flush()
	var gpu := _adapter.verify_gpu()
	assert_eq(gpu.size(), 0, "%s verify_gpu: %s" % [label, "; ".join(gpu)])
	var doc := _adapter.get_document()
	var diff := _adapter.verify_matches_document(doc)
	assert_eq(diff.size(), 0, "%s verify_matches_document: %s" % [label, "; ".join(diff)])


# --- scenario A: third material over a grass/dirt mix ------------------------------------------

func test_gpu_paint_repro_a_third_material() -> void:
	if not _rendered_available():
		return
	var doc := _mixed_doc(WorldLayout.legacy())
	_make(doc)
	var before := _snapshot(doc)
	await _shot("A_before_close.png", 0, 0, 40, true)
	var strokes := [
		{"label": "paint s0.3", "op": "paint", "s": 0.3, "z": -15.0},
		{"label": "paint s0.6", "op": "paint", "s": 0.6, "z": -5.0},
		{"label": "paint s1.0", "op": "paint", "s": 1.0, "z": 5.0},
		{"label": "spray s1.0", "op": "spray", "s": 1.0, "z": 15.0},
	]
	for st: Dictionary in strokes:
		_stroke(doc, _settings(ROCK, st.op, st.s, 4.0), Vector2(-40, st.z), Vector2(40, st.z))
		_print_line(doc, "A rock " + str(st.label), st.z, -40, 40)
	assert_true(_count_changed(before, doc) > 0, "rock strokes changed the document")
	await _check_gpu("A")
	await _shot("A_third_material_close.png", 0, 0, 40, true)
	await _shot("A_third_material_default_oblique.png", 0, 0, 140, false)
	await _shot("A_third_material_default_topdown.png", 0, 0, 140, true)


# --- scenario B: region borders on a 1 km world ------------------------------------------------

func test_gpu_paint_repro_b_region_border_km1() -> void:
	if not _rendered_available():
		return
	var doc := WorldDocument.create_flat(0.0, AUTO, WorldLayout.km1())
	var a := _make(doc)
	var before := _snapshot(doc)
	# Region borders sit at multiples of 128 m; x = 0 / z = 0 are borders between regions (-1|0).
	_stroke(doc, _settings(DIRT, "paint", 1.0, 4.0), Vector2(0, -40), Vector2(0, 40))  # along z, on x = 0
	_stroke(doc, _settings(DIRT, "paint", 1.0, 4.0), Vector2(-40, 0), Vector2(40, 0))  # along x, on z = 0
	_stroke(doc, _settings(DIRT, "paint", 1.0, 4.0), Vector2(-30, 30), Vector2(30, 30))  # across x = 0 at z = 30
	_stroke(doc, _settings(DIRT, "paint", 1.0, 4.0), Vector2(-30, -30), Vector2(-30, 30))
	_print_line(doc, "B dirt along x on z=0 (x=0 is region border)", 0.0, -12, 12)
	_print_line(doc, "B dirt across corner z=-0.5", -0.5, -12, 12)
	_print_line(doc, "B dirt z=30", 30.0, -12, 12)
	assert_true(_count_changed(before, doc) > 0, "dirt strokes changed the document")
	for loc: Vector2i in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
		assert_true(a.get_terrain().data.has_region(loc), "region %s uploaded" % loc)
	await _check_gpu("B")
	for d in [20.0, 140.0, 400.0]:
		await _shot("B_km1_border_%dm_topdown.png" % int(d), 0, 0, d, true)
		await _shot("B_km1_border_%dm_oblique.png" % int(d), 0, 0, d, false)


# --- scenario C: stroke running off the world edge ---------------------------------------------

func test_gpu_paint_repro_c_world_edge() -> void:
	if not _rendered_available():
		return
	var doc := WorldDocument.create_flat(0.0, AUTO, WorldLayout.legacy())
	_make(doc)
	var before := _snapshot(doc)
	_stroke(doc, _settings(DIRT, "paint", 1.0, 4.0), Vector2(100, 0), Vector2(140, 0))  # world ends at 127.5
	_print_line(doc, "C dirt past the edge", 0.0, 96, 127)
	assert_true(_count_changed(before, doc) > 0, "in-world part painted")
	var v := doc.get_control_at_sample(int(110 / WorldConstants.SAMPLE_SPACING), 0)
	assert_eq(ControlCodec.get_blend(v), 255, "x = 110 m is full dirt")
	await _check_gpu("C")
	await _shot("C_world_edge_close.png", 115, 0, 40, true)
	await _shot("C_world_edge_oblique.png", 115, 0, 70, false)


# --- scenario D: texel squares from a small dab ------------------------------------------------

func test_gpu_paint_repro_d_texel_squares() -> void:
	if not _rendered_available():
		return
	var doc := WorldDocument.create_flat(0.0, AUTO, WorldLayout.legacy())
	_make(doc)
	_stroke(doc, _settings(ROCK, "paint", 1.0, 1.0), Vector2(-3, 0), Vector2(-3, 0))
	_stroke(doc, _settings(SAND, "paint", 1.0, 1.0), Vector2(3, 0), Vector2(3, 0))
	for gz in [0, 1]:
		_print_line(doc, "D dab rock at x=-3 / sand at x=3", gz * 0.5, -5, 5)
	await _check_gpu("D")
	for h in [8.0, 20.0]:
		await _shot("D_texel_dab_%dm.png" % int(h), 0, 0, h, true)
