extends TestCase
## PathRenderer / WorldLayers path wiring (docs/editor-v2.md §7): one draped ribbon per path,
## re-drape on terrain edits, handles only for the selected path while the Path tool is active.

var catalog: AssetCatalog
var doc: WorldDocument
var renderer: PathRenderer


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	doc = WorldCodec.read_generation("res://fixtures/gentle_hills", catalog)[0]
	renderer = PathRenderer.new()


func after_each() -> void:
	renderer.free()


func _vertices(id: String) -> PackedVector3Array:
	var mesh := renderer.node_for(id).mesh
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]


func _assert_draped(id: String, note: String) -> void:
	var verts := _vertices(id)
	assert_true(verts.size() > 20, note + " has vertices")
	var worst := 0.0
	for v in verts:
		var h := doc.sample_height(v.x, v.z)
		if not is_nan(h):
			worst = maxf(worst, absf(v.y - (h + PathRibbon.LIFT_M)))
	assert_true(worst < 1e-3, "%s: ribbon Y follows the terrain (worst %f)" % [note, worst])


func _add_path(a: Vector2, b: Vector2) -> String:
	var rec := PathRecord.new()
	rec.path_id = ObjectRecord.new_uuid_v4()
	rec.width_m = 3.0
	rec.points = PackedVector2Array([a, a.lerp(b, 0.5) + Vector2(0, 3), b])
	doc.put_path(rec)
	return rec.path_id


func test_one_mesh_per_path_draped_on_the_terrain() -> void:
	renderer.rebuild(doc)
	assert_eq(renderer.path_count(), 1)
	var id := doc.sorted_path_ids()[0]
	_assert_draped(id, "fixture path")
	var second := _add_path(Vector2(-60, -60), Vector2(-30, -50))
	renderer.sync(doc, [second])
	assert_eq(renderer.path_count(), 2)
	_assert_draped(second, "second path")
	doc.remove_path(second)
	renderer.sync(doc, [second])
	assert_eq(renderer.path_count(), 1)
	assert_true(renderer.node_for(second) == null)


func test_ribbon_vertex_colours_use_the_path_palette() -> void:
	renderer.rebuild(doc)
	var colors: PackedColorArray = renderer.node_for(doc.sorted_path_ids()[0]).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var band := Color("a37650").lerp(Color8(50, 34, 18), 0.35)
	var fills := 0
	var bands := 0
	for c in colors:
		fills += 1 if c.is_equal_approx(Color("a37650")) else 0
		bands += 1 if absf(c.r - band.r) + absf(c.g - band.g) + absf(c.b - band.b) < 0.01 and c.a > 0.99 else 0  # 8-bit vertex colours
	assert_true(fills > 0, "fill colour a37650")
	assert_true(bands > 0 and bands == 2 * fills, "darker edge band on both edges")


func test_sculpt_height_change_redrapes_only_intersecting_paths() -> void:
	var far := _add_path(Vector2(-110, -110), Vector2(-90, -100))
	renderer.rebuild(doc)
	var id := doc.sorted_path_ids()[0] if doc.sorted_path_ids()[0] != far else doc.sorted_path_ids()[1]
	var far_node := renderer.node_for(far)
	var far_mesh := far_node.mesh
	var bounds := doc.get_path_record(id).bounds()
	for loc: Vector2i in doc.regions:
		var region := doc.get_region(loc)
		for i in region.heights.size():
			region.heights[i] += 2.0
		doc.invalidate_height_range(loc)
	renderer.mark_rect(bounds)
	assert_true(renderer.has_dirty())
	renderer.flush()
	assert_false(renderer.has_dirty())
	_assert_draped(id, "after sculpt")
	assert_true(far_node.mesh == far_mesh, "the far path was not rebuilt")


func test_handles_only_when_selected_and_shown() -> void:
	renderer.rebuild(doc)
	var id := doc.sorted_path_ids()[0]
	var rec := doc.get_path_record(id)
	assert_false(renderer.overlay().visible, "nothing selected")
	renderer.set_selection(id, false)
	assert_false(renderer.overlay().visible, "selected but the Path tool is not active")
	renderer.set_selection(id, true)
	assert_true(renderer.overlay().visible)
	var handles := renderer.overlay().handle_positions()
	assert_eq(handles.size(), rec.points.size())
	for i in handles.size():
		assert_near(handles[i].x, rec.points[i].x, 1e-4)
		assert_true(handles[i].y > doc.sample_height(rec.points[i].x, rec.points[i].y), "lifted above the terrain")
	renderer.set_selection("", true)
	assert_false(renderer.overlay().visible)


func test_handle_scale_keeps_minimum_screen_size() -> void:
	var near := PathOverlay.screen_scale(5.0, 60.0, 820.0)
	assert_eq(near, 1.0, "close camera keeps the true 0.6 m size")
	for dist in [40.0, 120.0, 400.0]:
		var s := PathOverlay.screen_scale(dist, 60.0, 820.0)
		var px: float = 0.6 * s * 820.0 / (2.0 * dist * tan(deg_to_rad(30.0)))
		assert_near(px, PathOverlay.MIN_SCREEN_PT, 0.05, "marker is 22 pt at %s m" % dist)
	assert_true(PathOverlay.screen_scale(120.0, 60.0, 820.0) > PathOverlay.screen_scale(40.0, 60.0, 820.0), "grows with distance")


func test_world_layers_follow_tool_and_selection_and_history() -> void:
	var h := ToolHarness.new()
	assert_empty_string(h.setup(tree))
	var layers := WorldLayers.new()
	layers.setup(h.catalog)
	layers.rebuild(h.doc)
	SessionRender.bind_path_selection(layers, h.ctrl)
	h.ctx.path_changed = layers.path_changed
	h.ctx.scatter_changed = layers.scatter_changed
	var id := h.doc.sorted_path_ids()[0]
	assert_eq(layers.paths.path_count(), 1)
	h.ctrl.set_tool("path")
	h.ctrl.select_path(id)
	assert_true(layers.paths.overlay().visible, "path tool + selection")
	h.ctrl.set_tool("raise")
	assert_false(layers.paths.overlay().visible, "other tool hides the handles")
	h.ctrl.set_tool("path")
	assert_true(layers.paths.overlay().visible)
	h.ctrl.select_path("")
	assert_false(layers.paths.overlay().visible)
	h.act("tool_begin", h.at(20, 90, 1.0))
	for x in range(21, 60):
		h.act("tool_move", h.at(float(x), 90.0, 1.0 + float(x) * 0.02))
	h.act("tool_end", h.at(60, 90, 3.0))
	assert_eq(layers.paths.path_count(), 2, "live ribbon of the new path")
	var change := h.history.undo(h.doc)
	layers.present_change(h.doc, change)
	assert_eq(layers.paths.path_count(), 1, "undo removes the ribbon")
	layers.present_change(h.doc, h.history.redo(h.doc))
	assert_eq(layers.paths.path_count(), 2, "redo brings it back")
	assert_empty_string(h.ctrl.delete_selected_path() if h.ctrl.selected_path_id() != "" else "")
	layers.free()
	h.teardown()
