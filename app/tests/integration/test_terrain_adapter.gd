extends TestCase
## TerrainAdapter against the pinned Terrain3D 1.0.2 runtime: construction from canonical
## bytes, TE-02 raw control bits, partial per-region uploads, height bounds, debug views,
## document replacement, and a measured comparison of Terrain3D.get_intersection (CPU).
## GPU texture-array contents are not observable headless (dummy rendering server); these
## tests verify region Images, Terrain3DData sampling and the upload signals.

## The pinned Terrain3D binaries were built against Godot 4.4 headers; Terrain3DMesher::snap
## calls the 4.4 compat RenderingServer.instance_reset_physics_interpolation, which Godot
## 4.7.2 reports once per process as a deprecation warning when the first Terrain3D enters
## the tree. Which test sees it depends on test order, so every adapter test tolerates
## exactly that message and fails on any other engine log (see after_each).
const KNOWN_T3D_WARNING := "instance_reset_physics_interpolation() is deprecated"

## Float32 bit patterns with unusual float meanings; none sets the hole bit (0x4), which
## would make Terrain3DData.get_height return NaN by design.
const ODD_CONTROL := [
	0x7FC00000, 0x7F800001, 0xFFC00000, 0x7F800000, 0xFF800000, 0x80000000,
	0x00000001, 0x807FFFF8, 0xFFFFFFFB, 0x7FBFFFFB, 0x3F800000, 0x00000000,
]


class KnownWarningFilter extends Logger:
	var unexpected: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if rationale != "" else code
		if not text.contains(KNOWN_T3D_WARNING):
			unexpected.append("%s (%s:%d %s)" % [text, file, line, function])

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _adapter: TerrainAdapter
var _filter: KnownWarningFilter
var _height_signals := 0
var _control_signals := 0


## Frees the adapter before checking the filter so errors logged during Terrain3D teardown
## are caught too (allow_logged_errors() disables the runner's own counter).
func after_each() -> void:
	tree.paused = false
	if _adapter != null and is_instance_valid(_adapter):
		_adapter.get_parent().remove_child(_adapter)
		_adapter.free()
	_adapter = null
	_assert_no_unexpected_logs()
	if _filter != null:
		OS.remove_logger(_filter)
		_filter = null


func _allow_only_known_warning() -> void:
	if _filter != null:
		return
	allow_logged_errors()
	_filter = KnownWarningFilter.new()
	OS.add_logger(_filter)


func _assert_no_unexpected_logs() -> void:
	if _filter != null:
		assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))


func _make(doc: WorldDocument) -> TerrainAdapter:
	_allow_only_known_warning()
	var a := TerrainAdapter.new()
	a.name = "TerrainAdapterUnderTest"
	tree.root.add_child(a)
	var cam := Camera3D.new()
	a.add_child(cam)
	cam.position = Vector3(0, 60, 60)
	a.set_camera(cam)
	assert_empty_string(a.initialize(doc), "initialize")
	_adapter = a
	var data := a.get_terrain().data
	data.height_maps_changed.connect(func() -> void: _height_signals += 1)
	data.control_maps_changed.connect(func() -> void: _control_signals += 1)
	return a


## Non-planar per-sample pattern so any index/region mix-up changes the value.
static func _pattern_height(gx: int, gz: int) -> float:
	return gx * 0.01 + gz * 0.001 + float(posmod(gx * 7 + gz * 13, 5)) * 0.1


func _pattern_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			for i in WorldConstants.REGION_SAMPLES:
				r.heights[j * 256 + i] = _pattern_height(loc.x * 256 + i, loc.y * 256 + j)
	doc.invalidate_all_height_ranges()
	return doc


func _hills_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			var z: float = (loc.y * 256 + j) * 0.5
			for i in WorldConstants.REGION_SAMPLES:
				var x: float = (loc.x * 256 + i) * 0.5
				r.heights[j * 256 + i] = 3.0 * sin(x * 0.045) * cos(z * 0.038) + 1.5 * sin((x + z) * 0.021)
	doc.invalidate_all_height_ranges()
	return doc


func _set_doc_height(doc: WorldDocument, gx: int, gz: int, h: float) -> Vector2i:
	var loc := Vector2i(WorldConstants.sample_region(gx), WorldConstants.sample_region(gz))
	doc.get_region(loc).heights[WorldConstants.sample_local(gz) * 256 + WorldConstants.sample_local(gx)] = h
	doc.invalidate_height_range(loc)
	return loc


# --- construction -----------------------------------------------------------------------------

func test_initialize_heights_match_document_including_seams() -> void:
	var doc := _pattern_doc()
	var a := _make(doc)
	var data := a.get_terrain().data
	assert_eq(data.get_region_locations().size(), 4, "four regions")
	var gs: Array[int] = [-256, -255, -129, -128, -2, -1, 0, 1, 2, 127, 128, 254, 255]
	for g in range(-256, 256, 11):
		gs.append(g)
	var checked := 0
	for gz in gs:
		for gx in gs:
			var h := data.get_height(Vector3(gx * 0.5, 0.0, gz * 0.5))
			if not assert_near(h, doc.get_height_at_sample(gx, gz), 1e-6, "vertex (%d,%d)" % [gx, gz]):
				return
			checked += 1
	# Between vertices (and across the X/Z seams) Terrain3D's bilinear matches the document's.
	for p: Vector2 in [Vector2(-0.25, -0.25), Vector2(-0.1, 0.3), Vector2(0.2, -0.4), Vector2(-64.3, 99.9), Vector2(127.25, -127.75)]:
		assert_near(data.get_height(Vector3(p.x, 0, p.y)), doc.sample_height(p.x, p.y), 1e-5, "bilinear %s" % p)
	assert_true(is_nan(data.get_height(Vector3(128.0, 0, 0))), "no sample beyond +127.5")
	assert_eq(a.verify_matches_document(doc).size(), 0, "verify after initialize")
	print("    compared %d vertices incl. seams" % checked)


func test_control_bits_survive_upload_bit_exactly() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	for p: int in ODD_CONTROL:
		assert_eq(p & ControlCodec.HOLE_BIT, 0, "pattern %x avoids hole bit" % p)
	var k := 0
	for loc in doc.sorted_region_locations():
		var r := doc.get_region(loc)
		for idx in r.control.size():
			r.control[idx] = ODD_CONTROL[(idx + k) % ODD_CONTROL.size()]
		k += 1
	var a := _make(doc)
	var data := a.get_terrain().data
	for loc in doc.sorted_region_locations():
		var img: Image = data.get_region(loc).get_control_map()
		assert_eq(img.get_format(), Image.FORMAT_RF, "control format %s" % loc)
		assert_true(img.get_data() == doc.get_region(loc).control_bytes(), "initial control bytes %s" % loc)
	# Second path: in-place Image.set_data during a partial flush.
	var target := Vector2i(0, -1)
	var rb := doc.get_region(target)
	for idx in rb.control.size():
		rb.control[idx] = ODD_CONTROL[(idx * 5 + 3) % ODD_CONTROL.size()]
	a.mark_dirty(TerrainAdapter.MAP_CONTROL, target)
	a.flush()
	var bytes := (data.get_region(target).get_control_map() as Image).get_data()
	assert_true(bytes == rb.control_bytes(), "flushed control bytes")
	for idx in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 65535]:
		assert_eq(bytes.decode_u32(idx * 4), rb.get_control(idx), "sample %d" % idx)
	assert_eq(a.verify_matches_document(doc).size(), 0, "verify after control flush")


func test_color_map_is_neutral_and_configuration_pinned() -> void:
	var a := _make(WorldDocument.create_flat(0.5, ControlCodec.grass_value()))
	var t := a.get_terrain()
	assert_false(t.material.auto_shader, "auto_shader off")
	assert_eq(t.collision_mode, Terrain3DCollision.DISABLED, "collision disabled")
	assert_eq(t.region_size, 256)
	assert_near(t.vertex_spacing, 0.5, 0.0)
	assert_eq(t.global_transform, Transform3D.IDENTITY, "identity terrain transform")
	assert_eq(t.assets.get_texture_count(), 2, "two materials")
	assert_eq(t.assets.get_texture(0).name, "grass")
	assert_eq(t.assets.get_texture(1).name, "dirt")
	var n := 256 * 256 * 4
	var expected := PackedByteArray()
	expected.resize(n)
	for i in range(0, n, 4):
		expected.encode_u32(i, 0x7FFFFFFF)  # RGBA8 (255, 255, 255, 127) little-endian
	for loc in t.data.get_region_locations():
		var cm: Image = t.data.get_region(loc).get_color_map()
		assert_eq(cm.get_format(), Image.FORMAT_RGBA8, "color format %s" % loc)
		assert_true(cm.get_data().slice(0, n) == expected, "neutral white color map %s" % loc)
		assert_eq(t.data.get_region(loc).location, loc)


func test_procedural_materials_share_size_format_and_mipmaps() -> void:
	var assets := TerrainMaterials.create_assets()
	var first_albedo: Image = assets.get_texture(0).albedo_texture.get_image()
	var first_normal: Image = assets.get_texture(0).normal_texture.get_image()
	for id in 2:
		var ta := assets.get_texture(id)
		for pair in [[ta.albedo_texture.get_image(), first_albedo], [ta.normal_texture.get_image(), first_normal]]:
			var img: Image = pair[0]
			var ref: Image = pair[1]
			assert_eq(img.get_size(), ref.get_size(), "size id %d" % id)
			assert_eq(img.get_format(), ref.get_format(), "format id %d" % id)
			assert_eq(img.has_mipmaps(), ref.has_mipmaps(), "mipmaps id %d" % id)
			assert_true(img.has_mipmaps(), "mipmaps present id %d" % id)
	var grass := first_albedo.get_pixel(5, 5)
	var dirt: Color = assets.get_texture(1).albedo_texture.get_image().get_pixel(5, 5)
	assert_true(grass.g > grass.r and dirt.r > dirt.g, "grass reads green, dirt reads brown")


# --- partial uploads -----------------------------------------------------------------------

func test_partial_flush_updates_only_dirty_region() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	var a := _make(doc)
	var data := a.get_terrain().data
	var before := {}
	for loc in doc.sorted_region_locations():
		var img: Image = data.get_region(loc).get_height_map()
		before[loc] = [img, img.get_data()]
	_height_signals = 0
	_control_signals = 0
	var edited := _set_doc_height(doc, 40, -10, 4.25)  # region (0, -1)
	assert_eq(edited, Vector2i(0, -1))
	assert_empty_string(a.mark_dirty(TerrainAdapter.MAP_HEIGHT, edited))
	a.flush()
	assert_eq(_height_signals, 1, "one height layer upload signal")
	assert_eq(_control_signals, 0, "no control upload")
	assert_eq(a.stats().uploads_height, 1)
	assert_eq(a.stats().uploads_control, 0)
	assert_near(data.get_height(Vector3(20.0, 0, -5.0)), 4.25, 1e-6, "Terrain3D sees new height")
	for loc in doc.sorted_region_locations():
		var region: Terrain3DRegion = data.get_region(loc)
		assert_true(region.get_height_map() == before[loc][0], "image updated in place %s" % loc)
		assert_false(region.edited, "edited flag cleared %s" % loc)
		if loc != edited:
			assert_true(region.get_height_map().get_data() == before[loc][1], "untouched %s" % loc)
	assert_false(a.has_pending_uploads())
	# Control kind has its own budget within the same frame.
	var cr := doc.get_region(Vector2i(-1, 0))
	cr.control[77] = ControlCodec.encode_paint(cr.get_control(77), 200)
	a.mark_dirty(TerrainAdapter.MAP_CONTROL, Vector2i(-1, 0))
	a.flush()
	assert_eq(_control_signals, 1, "one control layer upload signal")
	assert_eq(_height_signals, 1, "height not re-uploaded")
	assert_eq(a.verify_matches_document(doc).size(), 0, "verify after flushes")


func test_flush_is_batched_once_per_kind_per_frame() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var a := _make(doc)
	_set_doc_height(doc, -3, -3, 1.0)
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, Vector2i(-1, -1))
	a.flush()
	assert_eq(a.stats().uploads_height, 1)
	_set_doc_height(doc, 3, 3, 2.0)
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, Vector2i(0, 0))
	a.flush()
	assert_eq(a.stats().uploads_height, 1, "second flush in the same frame is deferred")
	assert_true(a.has_pending_uploads(), "work stays pending")
	var mismatches := a.verify_matches_document(doc)
	assert_eq(mismatches.size(), 1, "pending edit visible to verify: %s" % mismatches)
	# TerrainAdapter._process retries once the process frame counter has advanced.
	var frames := 0
	while a.has_pending_uploads() and frames < 10:
		await tree.process_frame
		frames += 1
	assert_false(a.has_pending_uploads(), "deferred upload ran within %d frames" % frames)
	assert_eq(a.stats().uploads_height, 2, "exactly one more height upload")
	assert_eq(a.verify_matches_document(doc).size(), 0)


func test_deferred_upload_runs_while_tree_is_paused() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var a := _make(doc)
	assert_eq(a.process_mode, Node.PROCESS_MODE_ALWAYS, "adapter processes while paused")
	tree.paused = true
	_set_doc_height(doc, -3, -3, 1.0)
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, Vector2i(-1, -1))
	a.flush()
	_set_doc_height(doc, 3, 3, 2.0)
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, Vector2i(0, 0))
	a.flush()
	assert_true(a.has_pending_uploads(), "second same-frame flush deferred")
	var frames := 0
	while a.has_pending_uploads() and frames < 10:
		await tree.process_frame
		frames += 1
	assert_false(a.has_pending_uploads(), "deferred upload ran while paused (%d frames)" % frames)
	assert_eq(a.stats().uploads_height, 2)
	assert_eq(a.verify_matches_document(doc).size(), 0, "Terrain3D matches the document while paused")
	tree.paused = false


func test_flush_is_cheap_when_clean() -> void:
	var a := _make(WorldDocument.create_flat(0.0, ControlCodec.grass_value()))
	var before := a.stats()
	var t0 := Time.get_ticks_usec()
	for i in 10000:
		a.flush()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("    10000 clean flush() calls: %.3f ms" % ms)
	assert_eq(a.stats(), before, "no work when clean")
	assert_true(ms < 50.0, "clean flush must be trivial (%.3f ms)" % ms)




func test_height_range_updates_after_raise_and_lower() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	var a := _make(doc)
	var data := a.get_terrain().data
	var raised := _set_doc_height(doc, -100, 60, 9.5)
	var lowered := _set_doc_height(doc, 10, -10, -3.0)
	assert_eq(raised, Vector2i(-1, 0))
	assert_eq(lowered, Vector2i(0, -1))
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, raised)
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, lowered)
	a.flush()
	assert_eq(_height_signals, 2, "one upload signal per dirty region")
	assert_eq(data.get_region(raised).get_height_range(), Vector2(1.0, 9.5), "region range after raise")
	assert_eq(data.get_region(lowered).get_height_range(), Vector2(-3.0, 1.0), "region range after lower")
	assert_eq(data.get_region(Vector2i(0, 0)).get_height_range(), Vector2(1.0, 1.0), "untouched region range")
	assert_near(data.get_height_range().y, 9.5, 1e-6, "master max after raise")
	assert_near(data.get_height_range().x, -3.0, 1e-6, "master min after lower")
	assert_eq(a.verify_matches_document(doc).size(), 0)


func test_verify_reports_unflushed_edits_and_clears_after_flush() -> void:
	var doc := _pattern_doc()
	var a := _make(doc)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for k in 64:
		var gx := rng.randi_range(-256, 255)
		var gz := rng.randi_range(-256, 255)
		var loc := _set_doc_height(doc, gx, gz, rng.randf_range(-5.0, 20.0))
		var r := doc.get_region(loc)
		var idx := WorldConstants.sample_local(gz) * 256 + WorldConstants.sample_local(gx)
		r.control[idx] = ControlCodec.encode_paint(r.get_control(idx), rng.randi_range(0, 255))
	var pending := a.verify_matches_document(doc)
	assert_eq(pending.size(), 8, "height + control mismatch in every region before flush: %s" % pending)
	for loc in doc.sorted_region_locations():
		a.mark_dirty(TerrainAdapter.MAP_HEIGHT, loc)
		a.mark_dirty(TerrainAdapter.MAP_CONTROL, loc)
	a.flush()
	assert_eq(a.verify_matches_document(doc).size(), 0, "verify after flush")
	assert_eq(a.stats().uploads_height, 4)
	assert_eq(a.stats().uploads_control, 4)
	assert_true(a.stats().last_flush_ms >= 0.0)
	print("    flush of 4 height + 4 control regions: %.3f ms" % a.stats().last_flush_ms)


func test_mark_dirty_rejects_unknown_kind_and_region() -> void:
	var a := _make(WorldDocument.create_flat(0.0, ControlCodec.grass_value()))
	assert_error_contains(a.mark_dirty(2, Vector2i(0, 0)), "kind")
	assert_error_contains(a.mark_dirty(TerrainAdapter.MAP_HEIGHT, Vector2i(1, 0)), "not loaded")
	assert_false(a.has_pending_uploads())


func test_initialize_errors_are_returned() -> void:
	var detached := TerrainAdapter.new()
	assert_error_contains(detached.initialize(WorldDocument.create_flat(0.0, 0)), "scene tree")
	detached.free()
	var a := TerrainAdapter.new()
	tree.root.add_child(a)
	_adapter = a
	assert_error_contains(a.initialize(null), "null")
	var bad := WorldDocument.create_flat(0.0, 0)
	bad.regions[Vector2i(3, 3)] = RegionBuffers.filled(Vector2i(3, 3), 0.0, 0)
	assert_error_contains(a.initialize(bad), "outside the fixed PoC layout")
	assert_true(a.get_terrain() == null, "no Terrain3D created for an invalid document")


## Spec §11.1: verify the uploaded GPU layers, not just the Images. Layer i of the Terrain3D
## texture arrays belongs to data.get_region_locations()[i] (terrain_3d_data.cpp update_maps).
## Headless runs use the dummy renderer (texture RIDs are unset), so this only runs rendered:
## godot --path <app copy> --script res://tests/run_tests.gd -- --filter=gpu_texture_layers
func test_gpu_texture_layers_match_document_after_partial_flush() -> void:
	var doc := _pattern_doc()
	var a := _make(doc)
	var data := a.get_terrain().data
	var initial := a.verify_gpu()
	if not initial.is_empty() and initial[0].begins_with("NOT RUN"):
		print("    GPU texture layers: %s (run rendered: scripts/dev.py test --rendered)" % initial[0])
		return
	assert_eq(initial, PackedStringArray(), "GPU matches document after initialize")
	var locs := data.get_region_locations()
	var before_h := _gpu_layers(data.get_height_maps_rid(), locs.size())
	var before_c := _gpu_layers(data.get_control_maps_rid(), locs.size())
	var h_loc := _set_doc_height(doc, 40, -10, 7.25)
	var c_loc := Vector2i(-1, 0)
	var cr := doc.get_region(c_loc)
	cr.control[1234] = ControlCodec.encode_paint(cr.get_control(1234), 201)
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, h_loc)
	a.mark_dirty(TerrainAdapter.MAP_CONTROL, c_loc)
	a.flush()
	await tree.process_frame
	assert_eq(a.verify_gpu(), PackedStringArray(), "GPU matches document after partial flush")
	var after_h := _gpu_layers(data.get_height_maps_rid(), locs.size())
	var after_c := _gpu_layers(data.get_control_maps_rid(), locs.size())
	var changed := 0
	for i in locs.size():
		assert_eq(after_h[i] != before_h[i], locs[i] == h_loc, "only dirty height layer changed %s" % locs[i])
		assert_eq(after_c[i] != before_c[i], locs[i] == c_loc, "only dirty control layer changed %s" % locs[i])
		changed += int(after_h[i] != before_h[i]) + int(after_c[i] != before_c[i])
	# A later frame, a different region: repeated partial updates must keep matching.
	var h2_loc := _set_doc_height(doc, -40, 30, -3.5)
	assert_true(h2_loc != h_loc, "second edit targets a different region")
	a.mark_dirty(TerrainAdapter.MAP_HEIGHT, h2_loc)
	a.flush()
	await tree.process_frame
	assert_eq(a.verify_gpu(), PackedStringArray(), "GPU matches document after second partial flush")
	print("    GPU texture layers (%s): verified after initialize and two partial flushes; %d of %d layers changed in the first" % [RenderingServer.get_current_rendering_driver_name(), changed, 2 * locs.size()])


func _gpu_layers(rid: RID, count: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for i in count:
		var img := RenderingServer.texture_2d_layer_get(rid, i)
		out.append(img.get_data() if img != null else PackedByteArray())
	return out


# --- debug views ------------------------------------------------------------------------------

func test_debug_view_and_region_grid_toggles() -> void:
	var a := _make(WorldDocument.create_flat(0.0, ControlCodec.grass_value()))
	var t := a.get_terrain()
	assert_false(t.show_control_blend or t.show_heightmap or t.show_region_grid, "normal by default")
	assert_empty_string(a.set_debug_view("control_blend"))
	assert_true(t.material.show_control_blend, "control blend on")
	assert_false(t.material.show_heightmap)
	assert_empty_string(a.set_debug_view("heightmap"))
	assert_true(t.material.show_heightmap, "heightmap on")
	assert_false(t.material.show_control_blend, "control blend off")
	assert_error_contains(a.set_debug_view("wireframe"), "unknown debug view")
	assert_eq(a.get_debug_view(), "heightmap", "rejected mode leaves state")
	assert_empty_string(a.set_debug_view("normal"))
	assert_false(t.material.show_heightmap or t.material.show_control_blend, "normal clears both")
	a.set_region_grid(true)
	assert_true(t.material.show_region_grid, "region grid on")
	a.set_region_grid(false)
	assert_false(t.material.show_region_grid, "region grid off")


# --- document replacement -----------------------------------------------------------------------

func test_replace_document_twice_releases_old_regions() -> void:
	var a := _make(WorldDocument.create_flat(1.0, ControlCodec.grass_value()))
	var t := a.get_terrain()
	var child_count := a.get_child_count()
	var old_refs: Array[WeakRef] = []
	for loc in t.data.get_region_locations():
		old_refs.append(weakref(t.data.get_region(loc)))
		old_refs.append(weakref(t.data.get_region(loc).get_height_map()))
	var second := _pattern_doc()
	assert_empty_string(a.replace_document(second), "first replace")
	assert_eq(a.verify_matches_document(second).size(), 0, "matches second doc")
	assert_near(t.data.get_height(Vector3(-10.5, 0, 33.0)), second.sample_height(-10.5, 33.0), 1e-6)
	for w in old_refs:
		assert_true(w.get_ref() == null, "old region objects released")
	var third := WorldDocument.create_flat(-2.0, ControlCodec.encode_paint(0, 255))
	assert_empty_string(a.replace_document(third), "second replace")
	assert_eq(a.verify_matches_document(third).size(), 0, "matches third doc")
	assert_true(a.get_terrain() == t, "Terrain3D node reused")
	assert_eq(a.get_child_count(), child_count, "no extra nodes")
	assert_eq(t.data.get_region_locations().size(), 4)
	assert_near(t.data.get_height(Vector3(50, 0, 50)), -2.0, 1e-6)
	assert_eq(a.stats().uploads_height, 0, "stats reset on replace")
	assert_true(a.verify_matches_document(second).size() > 0, "no longer matches the second doc")


# --- Terrain3D CPU intersection vs canonical picker (ADR 0004 evidence) -------------------------

func test_measure_terrain3d_get_intersection_against_picker() -> void:
	var doc := _hills_doc()
	var a := _make(doc)
	var t := a.get_terrain()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var groups := {"45deg": -1.0, "30deg": -0.577, "70deg": -2.747}
	for label: String in groups:
		var worst := 0.0
		var total := 0.0
		var n := 25
		for k in n:
			var ang := rng.randf() * TAU
			var d := Vector3(cos(ang), groups[label], sin(ang)).normalized()
			var o := Vector3(rng.randf_range(-80, 80), 25.0, rng.randf_range(-80, 80))
			var hit := TerrainPicker.raycast(doc, o, d)
			assert_eq(hit.reason, "hit", "%s ray %d" % [label, k])
			assert_near(hit.position.y, doc.sample_height(hit.position.x, hit.position.z), 1e-5, "picker on surface")
			var t3d := t.get_intersection(o, d, false)
			var err := t3d.distance_to(hit.position)
			worst = maxf(worst, err)
			total += err
		print("    Terrain3D.get_intersection(cpu) vs picker, %s: mean %.4f m, worst %.4f m (%d rays)" % [label, total / n, worst, n])
	var down := t.get_intersection(Vector3(12.25, 30, -7.5), Vector3.DOWN, false)
	var pick_down := TerrainPicker.raycast(doc, Vector3(12.25, 30, -7.5), Vector3.DOWN)
	print("    straight down inside: Terrain3D %s vs picker %s (|d| %s m)" % [down, pick_down.position, String.num_scientific(down.distance_to(pick_down.position))])
	var outside := t.get_intersection(Vector3(200, 30, 0), Vector3.DOWN, false)
	var pick_out := TerrainPicker.raycast(doc, Vector3(200, 30, 0), Vector3.DOWN)
	print("    straight down outside world: Terrain3D %s (substitutes y=0) vs picker '%s' %s" % [outside, pick_out.reason, pick_out.position])
	var sky := t.get_intersection(Vector3(0, 30, 0), Vector3(0.2, 1, 0), false)
	print("    sky ray: Terrain3D %s vs picker '%s'" % [sky, TerrainPicker.raycast(doc, Vector3(0, 30, 0), Vector3(0.2, 1, 0)).reason])
	assert_eq(pick_out.reason, "outside")
	assert_true(is_nan(pick_out.position.y), "picker never substitutes zero")
