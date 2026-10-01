extends TestCase
## Terrain upload accounting and scheduling (spec §14, TERRAIN-01, TERRAIN-02): interleaved height /
## control / tint marks never lose an edit or upload the wrong map kind, the counters add up, and the
## presented terrain matches the canonical bytes after stroke finish, cancel and undo.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const KINDS := [TerrainView.MAP_HEIGHT, TerrainView.MAP_CONTROL, TerrainView.MAP_COLOR]
const KIND_NAMES := ["height", "control", "color"]

var _filter: TerrainTests.KnownWarningFilter
var _adapter: TerrainAdapter
var _session: EditorSession


func before_each() -> void:
	allow_logged_errors()
	_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(_filter)


func after_each() -> void:
	tree.paused = false
	if _session != null and is_instance_valid(_session):
		tree.root.remove_child(_session)
		_session.free()
	_session = null
	if _adapter != null and is_instance_valid(_adapter):
		_adapter.get_parent().remove_child(_adapter)
		_adapter.free()
	_adapter = null
	assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))
	OS.remove_logger(_filter)


func _make(doc: WorldDocument) -> TerrainAdapter:
	var a := TerrainAdapter.new()
	tree.root.add_child(a)
	var cam := Camera3D.new()
	a.add_child(cam)
	cam.position = Vector3(0, 60, 60)
	a.set_camera(cam)
	assert_empty_string(a.initialize(doc), "initialize")
	_adapter = a
	return a


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


## Stamps a value only this (frame, kind, region) would produce so a mix-up shows in verify.
func _edit(doc: WorldDocument, kind: int, loc: Vector2i, stamp: int) -> void:
	var rb := doc.get_region(loc)
	var k := (stamp * 37) % WorldConstants.REGION_SAMPLE_COUNT
	if kind == TerrainView.MAP_HEIGHT:
		rb.heights[k] = float(stamp % 50) * 0.25
	elif kind == TerrainView.MAP_CONTROL:
		rb.control[k] = ControlCodec.encode(rb.control[k], {"overlay_id": stamp % 4, "blend": stamp % 256})
	else:
		for c in 4:
			rb.color[k * 4 + c] = (stamp * 11 + c * 29) % 256
	if kind == TerrainView.MAP_HEIGHT:
		doc.invalidate_height_range(loc)


# --- TERRAIN-01 ------------------------------------------------------------------------------------

func test_interleaved_marks_across_frames_never_lose_an_edit_or_cross_kinds() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var a := _make(doc)
	var locs := doc.sorted_region_locations()
	var marks := [0, 0, 0]
	for frame in 12:
		for kind: int in KINDS:
			# Different kinds hit different regions in the same frame; some regions are marked twice.
			var loc: Vector2i = locs[(frame + kind * 2) % locs.size()]
			_edit(doc, kind, loc, frame * 3 + kind + 1)
			assert_empty_string(a.mark_dirty(kind, loc))
			marks[kind] += 1
			if frame % 3 == 0:
				_edit(doc, kind, loc, frame * 5 + kind + 7)
				a.mark_dirty(kind, loc)  # coalesced into the same pending upload
				marks[kind] += 1
		await tree.process_frame
	await _frames(4)
	assert_false(a.has_pending_uploads())
	assert_eq(a.verify_matches_document(doc), PackedStringArray(), "every edit reached the right map")
	var st := a.stats()
	assert_eq(st.regions_pending, 0)
	assert_eq(st.oldest_pending_ms, 0.0)
	for kind: int in KINDS:
		var n: String = KIND_NAMES[kind]
		var uploaded: int = st["uploads_" + n]
		assert_eq(uploaded + int(st["coalesced_" + n]), marks[kind], "%s: every mark uploaded or coalesced" % n)
		assert_eq(st["bytes_uploaded_" + n], uploaded * WorldConstants.REGION_MAP_BYTES, n + " bytes")
		assert_true(uploaded >= 1)
	assert_true(int(st.coalesced_height) > 0 and int(st.coalesced_control) > 0 and int(st.coalesced_color) > 0)


func test_a_mark_uploads_only_its_own_kind_and_unmarked_edits_stay_pending() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var a := _make(doc)
	var loc := Vector2i(0, 0)
	_edit(doc, TerrainView.MAP_CONTROL, loc, 5)  # edited but never marked
	_edit(doc, TerrainView.MAP_HEIGHT, loc, 6)
	a.mark_dirty(TerrainView.MAP_HEIGHT, loc)
	await _frames(3)
	var st := a.stats()
	assert_eq(st.uploads_height, 1)
	assert_eq(st.uploads_control, 0, "height mark did not flush control")
	assert_eq(st.bytes_uploaded_control, 0)
	var report := a.verify_matches_document(doc)
	assert_eq(report.size(), 1, "the unmarked control edit is still unpresented: %s" % report)
	assert_true(report[0].contains("control"))
	a.mark_dirty(TerrainView.MAP_CONTROL, loc)
	await _frames(3)
	assert_eq(a.verify_matches_document(doc), PackedStringArray())
	assert_eq(a.stats().uploads_height, 1, "control mark did not re-upload height")


func test_pending_age_copy_timings_and_latency_are_reported() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var a := _make(doc)
	var loc := Vector2i(-1, 0)
	_edit(doc, TerrainView.MAP_HEIGHT, loc, 3)
	a.mark_dirty(TerrainView.MAP_HEIGHT, loc)
	_edit(doc, TerrainView.MAP_COLOR, loc, 4)
	a.mark_dirty(TerrainView.MAP_COLOR, Vector2i(0, -1))
	OS.delay_msec(15)
	var pending := a.stats()
	assert_eq(pending.regions_pending, 2)
	assert_eq(pending.regions_pending_height, 1)
	assert_true(float(pending.oldest_pending_ms) >= 14.0, "oldest pending age %s" % pending.oldest_pending_ms)
	await _frames(3)
	var st := a.stats()
	assert_eq(st.regions_pending, 0)
	assert_true(float(st.last_presented_age_ms) >= 14.0, "age of the last flush %s" % st.last_presented_age_ms)
	assert_true(float(st.copy_ms_last) >= 0.0 and float(st.update_maps_ms_last) >= 0.0 and float(st.height_range_ms_last) >= 0.0)
	assert_true(float(st.last_flush_ms) > 0.0)
	var lat := a.presentation_latency()
	assert_eq(lat.samples, 2)
	assert_true(float(lat.max_ms) >= float(lat.p50_ms) and float(lat.p95_ms) >= 14.0)
	assert_eq(lat.oldest_pending_ms, 0.0)
	print("    terrain upload: copy %.3f ms, range %.3f ms, update_maps %.3f ms, age p95 %.1f ms" % [
		st.copy_ms_last, st.height_range_ms_last, st.update_maps_ms_last, lat.p95_ms])


func test_replace_document_resets_pending_and_counters() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var a := _make(doc)
	a.mark_dirty(TerrainView.MAP_HEIGHT, Vector2i(0, 0))
	assert_empty_string(a.replace_document(WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)))
	assert_false(a.has_pending_uploads())
	assert_eq(a.stats().regions_pending, 0)
	assert_eq(a.stats().uploads_height, 0)
	assert_eq(a.presentation_latency().samples, 0)


## Rendered runs only (scripts/dev.py test --rendered): the tint array layer carries the mip chain Terrain3D built.
func test_gpu_color_edit_reaches_the_gpu_layer() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("    NOT RUN: no rendering device (headless); run scripts/dev.py test --rendered")
		return
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var a := _make(doc)
	var loc := Vector2i(0, 0)
	_edit(doc, TerrainView.MAP_COLOR, loc, 9)
	a.mark_dirty(TerrainView.MAP_COLOR, loc)
	await _frames(4)
	assert_false(a.has_pending_uploads())
	var data := a.get_terrain().data
	var rid := data.get_color_maps_rid()
	var index := data.get_region_locations().find(loc)
	var layer := RenderingServer.texture_2d_layer_get(rid, index)
	assert_true(layer != null and layer.has_mipmaps(), "GPU tint layer keeps its mip chain")
	assert_eq(layer.get_data().slice(0, WorldConstants.REGION_MAP_BYTES), doc.get_region(loc).color_bytes(), "mip 0 == document tint")


# --- shader / mesh configuration ----------------------------------------------------------------------

func test_background_is_flat_and_mesh_config_is_validated() -> void:
	var a := _make(WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL))
	assert_eq(a.get_terrain().material.world_background, Terrain3DMaterial.FLAT, "no noise world background")
	var before := a.mesh_config()
	assert_true(int(before.mesh_size) >= 8 and int(before.lods) >= 1)
	assert_empty_string(a.set_mesh_config(32, 7))
	assert_eq(a.mesh_config(), {"mesh_size": 32, "lods": 7})
	assert_empty_string(a.set_mesh_config(24, 7))
	assert_eq(a.mesh_config().mesh_size, 24)
	for bad: Array in [[7, 7], [66, 7], [25, 7], [32, 0], [32, 11]]:
		assert_ne(a.set_mesh_config(bad[0], bad[1]), "", "rejects %s" % [bad])
	assert_eq(a.mesh_config(), {"mesh_size": 24, "lods": 7}, "a rejected config changes nothing")
	assert_empty_string(a.set_mesh_config(int(before.mesh_size), int(before.lods)))


func test_texture_preview_uniforms_validate_their_inputs() -> void:
	var a := _make(WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL))
	var arr := Texture2DArray.new()
	var img := Image.create(8, 8, true, Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	assert_eq(arr.create_from_images([img] as Array[Image]), OK)
	var layers := PackedInt32Array([0, -1, -1, -1])
	assert_ne(a.set_texture_preview(Vector2(NAN, 0), 20.0, 1.5, arr, arr, layers), "")
	assert_ne(a.set_texture_preview(Vector2.ZERO, 0.0, 1.5, arr, arr, layers), "")
	assert_ne(a.set_texture_preview(Vector2.ZERO, 20.0, 1.5, null, arr, layers), "")
	assert_ne(a.set_texture_preview(Vector2.ZERO, 20.0, 1.5, arr, arr, PackedInt32Array([0, 0])), "")
	assert_ne(a.set_texture_preview(Vector2.ZERO, 20.0, 1.5, arr, arr, PackedInt32Array([1, -1, -1, -1])), "layer outside the array")
	assert_ne(a.set_texture_preview(Vector2.ZERO, 20.0, 1.5, arr, arr, PackedInt32Array([-1, -1, -1, -1])), "no layer selected")
	assert_false(a.preview_uniforms().preview_enabled, "rejected input binds nothing")
	assert_empty_string(a.set_texture_preview(Vector2(3, 4), 20.0, 1.5, arr, arr, layers))
	assert_eq(a.preview_uniforms().preview_area, Vector4(3, 4, 20, 1.5))
	a.clear_texture_preview()
	assert_eq(a.preview_uniforms().preview_layer, Vector4i(-1, -1, -1, -1))
	assert_true(a.preview_uniforms().preview_albedo_array == null)


# --- TERRAIN-02 --------------------------------------------------------------------------------------

func _start_session() -> EditorSession:
	var s := EditorSession.new()
	s.storage_root = scratch_dir() + "/worlds"
	s.start_fixture = "flat"
	s.provider_override = InputTests.FakeProvider.new()
	s.build_ui = false
	_session = s
	tree.root.add_child(s)
	await tree.process_frame
	for i in 300:
		if not s.storage.is_busy():
			break
		await tree.process_frame
	return s


func _sample(s: EditorSession, x: float, z: float, t: float) -> PointerSample:
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.PENCIL
	sample.timestamp_s = t
	sample.position_viewport = s.rig.get_camera().unproject_position(Vector3(x, s.document.sample_height(x, z), z))
	return sample


func _act(s: EditorSession, type: String, x: float, z: float, t: float) -> void:
	s._on_tool_action({"type": type, "sample": _sample(s, x, z, t), "over_ui": false})


func _sculpt(s: EditorSession, x0: float, x1: float, end: bool) -> void:
	var t := 1.0
	_act(s, "tool_begin", x0, 0.0, t)
	var x := x0
	while x < x1:
		x = minf(x + 2.0, x1)
		t += 0.05
		_act(s, "tool_move", x, 0.0, t)
		s.tools.advance(t)
	if end:
		_act(s, "tool_end", x1, 0.0, t + 0.05)
	else:
		s.cancel_active()


func _assert_presented(s: EditorSession, what: String) -> void:
	await _frames(4)
	var adapter := s.terrain as TerrainAdapter
	assert_false(adapter.has_pending_uploads(), what + ": nothing pending")
	assert_eq(adapter.verify_matches_document(s.document), PackedStringArray(), what + ": presented == canonical")
	assert_eq(adapter.stats().regions_pending, 0, what)


func test_stroke_finish_cancel_undo_redo_present_the_canonical_bytes() -> void:
	var s := await _start_session()
	assert_true(s.terrain is TerrainAdapter, "real terrain adapter")
	s.tools.set_tool(ToolController.TOOL_RAISE)
	var flat_hash := s.authored_hash()
	_sculpt(s, -6.0, 6.0, true)
	assert_ne(s.authored_hash(), flat_hash, "the stroke changed the terrain")
	assert_eq(s.history.size(), 1)
	await _assert_presented(s, "after finish")
	var uploads_after_stroke: int = (s.terrain as TerrainAdapter).stats().uploads_height
	assert_true(uploads_after_stroke >= 1)
	var finished_hash := s.authored_hash()
	_sculpt(s, -10.0, 10.0, false)
	assert_eq(s.authored_hash(), finished_hash, "cancel restores the canonical bytes")
	await _assert_presented(s, "after cancel")
	assert_eq(s.undo(), "")
	assert_eq(s.authored_hash(), flat_hash)
	await _assert_presented(s, "after undo")
	assert_eq(s.redo(), "")
	assert_eq(s.authored_hash(), finished_hash)
	await _assert_presented(s, "after redo")
	var lat := (s.terrain as TerrainAdapter).presentation_latency()
	assert_true(int(lat.samples) >= 4)
	print("    stroke edit-to-upload age: p50 %.1f ms p95 %.1f ms max %.1f ms over %d uploads" % [
		lat.p50_ms, lat.p95_ms, lat.max_ms, lat.samples])
