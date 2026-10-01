extends ScatterTestCase
## ScatterRenderer / WorldLayers: registry-tier batches per (cell, asset), re-draping, dirty-only rebuilds, hide
## vegetation (UI-02), NOT_READY placeholders and the scatter tools' readiness refusal.
## Tests whose name contains "gpu" run only in a windowed run (scripts/dev.py test --rendered);
## WP_SCATTER_EVIDENCE_DIR also writes the screenshot there.

const KNOWN_T3D_WARNING := "instance_reset_physics_interpolation() is deprecated"


func _expected(layer: ScatterLayer) -> Dictionary:
	var out := {}
	for i in layer.count():
		if is_nan(doc.sample_height(layer.x[i], layer.z[i])):
			continue
		var key := "%s|%s" % [renderer.cell_for(layer.asset_of(i), layer.x[i], layer.z[i]), layer.asset_of(i)]
		out[key] = int(out.get(key, 0)) + 1
	return out


func _assert_matches_layer(note: String) -> void:
	var expected := _expected(doc.scatter)
	var total := 0
	for key: String in expected:
		var parts := key.split("|")
		var asset_id := parts[1]
		var cell := _parse_cell(parts[0])
		assert_eq(renderer.rendered_count(cell, asset_id), int(expected[key]), "%s %s" % [note, key])
		var node := renderer.multimesh_for(cell, asset_id)
		if assert_true(node != null, "%s node %s" % [note, key]):
			assert_eq(node.multimesh.instance_count, int(expected[key]))
		total += int(expected[key])
	var stats := renderer.stats()
	assert_eq(stats.instances, total, note + " total")
	assert_eq(stats.multimeshes, expected.size(), note + " multimeshes")
	assert_eq(renderer.get_child_count(), expected.size(), note + " nodes")


static func _parse_cell(text: String) -> Vector2i:
	var v := text.trim_prefix("(").trim_suffix(")").split(",")
	return Vector2i(int(v[0]), int(v[1]))


func _forest_config() -> Dictionary:
	return {"name": "T", "items": [{"asset_id": SPRUCE, "weight": 1.0}], "density": 1.0, "spacing": 0.5,
			"slope_min": 0.0, "slope_max": 90.0, "align": false}


func test_gentle_hills_renders_550_instances_per_cell_and_asset() -> void:
	_build()
	assert_eq(doc.scatter.count(), 550)
	assert_eq(renderer.stats().instances, 550)
	assert_eq(renderer.stats().authored, 550)
	_assert_matches_layer("initial")
	assert_true(float(renderer.stats().last_rebuild_ms) >= 0.0)


func test_add_erase_and_undo_keep_counts_in_sync_with_dirty_only_rebuilds() -> void:
	_build()
	var far_cell := Vector2i.ZERO
	for i in doc.scatter.count():
		if doc.scatter.asset_of(i) == GRASS and Vector2(doc.scatter.x[i] - 68.0, doc.scatter.z[i] - 64.0).length() > 50.0:
			far_cell = renderer.cell_for(GRASS, doc.scatter.x[i], doc.scatter.z[i])
			break
	var untouched := renderer.multimesh_for(far_cell, GRASS)
	var bytes := doc.scatter.encode()
	var before := doc.scatter.clone()
	var placer := ScatterPlacer.new(doc, catalog, _forest_config(), false, 4)
	for i in 40:
		placer.try_add(60.0 + float(i % 8) * 2.0, 60.0 + float(i / 8) * 2.0)
	assert_true(placer.added > 20)
	renderer.mark_rect(Rect2(58.0, 58.0, 20.0, 14.0))
	assert_true(renderer.has_dirty())
	renderer.flush()
	assert_false(renderer.has_dirty())
	_assert_matches_layer("after add")
	var index := ScatterIndex.new(doc.scatter)
	index.remove_indices(index.indices_in_disc(66.0, 64.0, 6.0))
	renderer.mark_rect(Rect2(58.0, 58.0, 20.0, 14.0))
	renderer.flush()
	_assert_matches_layer("after erase")
	assert_true(untouched != null and renderer.multimesh_for(far_cell, GRASS) == untouched, "far cell not rebuilt")
	doc.scatter = before.clone()  # undo
	renderer.mark_rect(Rect2(58.0, 58.0, 20.0, 14.0))
	renderer.flush()
	_assert_matches_layer("after undo")
	assert_eq(doc.scatter.encode(), bytes)


func test_height_change_redrapes_y_and_nan_is_skipped() -> void:
	var layer := ScatterLayer.new()
	layer.add(PEBBLES, catalog.get_asset(PEBBLES).version, 10.0, 10.0, 0.0, 1.0, 0)
	layer.add(PEBBLES, catalog.get_asset(PEBBLES).version, 11.0, 10.0, 0.0, 1.0, 0)
	doc.scatter = layer
	_build()
	var cell := renderer.cell_for(PEBBLES, 10.0, 10.0)
	assert_near(renderer.instance_transform(cell, PEBBLES, 0).origin.y, doc.sample_height(10.0, 10.0), 1e-4, "draped on the ground")
	var region := doc.get_region(Vector2i(0, 0))
	for i in region.heights.size():
		region.heights[i] += 3.0
	doc.invalidate_height_range(Vector2i(0, 0))
	renderer.mark_rect(Rect2(0.0, 0.0, 128.0, 128.0), true)
	renderer.flush()
	assert_near(renderer.instance_transform(cell, PEBBLES, 0).origin.y, doc.sample_height(10.0, 10.0), 1e-4, "re-draped")
	assert_eq(renderer.rendered_count(cell, PEBBLES), 2)
	var hole_index := (20 * 256) + 20  # sample (20, 20) = world (10, 10)
	region.control[hole_index] = region.control[hole_index] | ControlCodec.HOLE_BIT
	renderer.mark_rect(Rect2(0.0, 0.0, 128.0, 128.0), true)
	renderer.flush()
	assert_true(is_nan(doc.sample_height(10.0, 10.0)))
	assert_eq(renderer.rendered_count(cell, PEBBLES), 1, "instance without a sample is skipped")
	assert_eq(renderer.stats().instances, 1)


func test_align_flag_tilts_to_terrain_and_nothing_casts_shadows() -> void:
	var layer := ScatterLayer.new()
	var v := catalog.get_asset(PEBBLES).version
	layer.add(PEBBLES, v, 10.0, 10.0, 0.0, 1.0, 0)
	layer.add(PEBBLES, v, 16.0, 10.0, 0.0, 1.0, ScatterLayer.FLAG_TILT)
	layer.add(GRASS, catalog.get_asset(GRASS).version, 10.0, 16.0, 0.0, 1.0, 0)
	layer.add(SPRUCE, catalog.get_asset(SPRUCE).version, 16.0, 16.0, 0.0, 1.0, 0)
	doc.scatter = layer
	var region := doc.get_region(Vector2i(0, 0))
	for i in region.heights.size():
		region.heights[i] = 0.3 * float(i % 256) * WorldConstants.SAMPLE_SPACING
	_build()
	var up0 := renderer.instance_transform(renderer.cell_for(PEBBLES, 10.0, 10.0), PEBBLES, 0).basis.y
	var up1 := renderer.instance_transform(renderer.cell_for(PEBBLES, 16.0, 10.0), PEBBLES, 0).basis.y
	assert_vec_near(up0, Vector3.UP, 1e-5, "unaligned stays upright")
	assert_vec_near(up1, doc.sample_normal(16.0, 10.0), 1e-4, "aligned follows the normal")
	assert_true(up1.distance_to(Vector3.UP) > 1e-3, "the hill is not flat here")
	for node: Node in renderer.get_children():
		assert_eq((node as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


## UI-02, scatter part: grass, fern, wildflowers and spruce hide; pebbles (excluded) and boulder stay.
func test_hidden_vegetation_follows_the_descriptor_including_later_cells() -> void:
	var rule := RenderConfig.load_from().vegetation_rule()
	var all: Array[String] = [GRASS, FERN, WILD, SPRUCE, PEBBLES, BOULDER]
	doc.scatter = _layer_of(all)
	_build()
	renderer.set_vegetation_hidden(true, rule)
	for id: String in [GRASS, FERN, WILD, SPRUCE]:
		assert_false(renderer.multimesh_for(renderer.cell_for(id, 10.0, 10.0), id).visible, id + " hidden")
	for id: String in [PEBBLES, BOULDER]:
		assert_true(renderer.multimesh_for(renderer.cell_for(id, 10.0, 10.0), id).visible, id + " stays")
	var bytes := doc.scatter.encode()
	doc.scatter.add(SPRUCE, catalog.get_asset(SPRUCE).version, 100.0, 100.0, 0.0, 1.0, 0)
	renderer.mark_all()
	renderer.flush()
	assert_false(renderer.multimesh_for(renderer.cell_for(SPRUCE, 100.0, 100.0), SPRUCE).visible, "cell built while hidden")
	renderer.set_vegetation_hidden(false, rule)
	for id: String in all:
		assert_true(renderer.multimesh_for(renderer.cell_for(id, 10.0, 10.0), id).visible, id + " restored")
	assert_true(renderer.multimesh_for(renderer.cell_for(SPRUCE, 100.0, 100.0), SPRUCE).visible)
	assert_ne(doc.scatter.encode(), bytes, "only the test's own instance was added")


func test_world_layers_present_change_marks_scatter_and_height_cells() -> void:
	var layers := WorldLayers.new()
	layers.setup(catalog)
	layers.set_lod_profile(full_profile())
	doc.scatter.add(SPRUCE, catalog.get_asset(SPRUCE).version, 5.0, 5.0, 0.0, 1.0, 0)
	layers.rebuild(doc)
	assert_true(layers.settle_now())
	assert_eq(layers.stats().authored, 551)
	var change := WorldChange.new()
	change.before_scatter = doc.scatter.clone()
	doc.scatter.add(SPRUCE, catalog.get_asset(SPRUCE).version, 60.0, 60.0, 0.0, 1.0, 0)
	change.after_scatter = doc.scatter.clone()
	layers.present_change(doc, change)
	assert_true(layers.scatter.has_dirty(), "a scatter change marks cells")
	layers.scatter.flush()
	assert_false(layers.scatter.has_dirty())
	assert_eq(layers.stats().instances, 552)
	layers.present_change(doc, change)
	assert_false(layers.scatter.has_dirty(), "a commit of what was already drawn redraws nothing")
	layers.heights_changed(Rect2(0.0, 0.0, 10.0, 10.0))
	assert_true(layers.scatter.has_dirty(), "height rect marks cells")
	layers.scatter.flush()
	var objects_only := WorldChange.new()
	objects_only.before_objects["x"] = null
	layers.present_change(doc, objects_only)
	assert_false(layers.scatter.has_dirty(), "object-only changes redraw nothing")
	layers.free()


# --- Registry tiers and NOT_READY ---------------------------------------------------------------

func test_meshes_come_from_registry_tiers_never_the_catalog_scatter_mesh() -> void:
	var uncached: Array[String] = []
	for id: String in catalog.sorted_ids():
		var path := catalog.get_asset(id).scatter_mesh
		if path != "" and not ResourceLoader.has_cached(path):
			uncached.append(path)
	_build()
	assert_true(renderer.stats().multimeshes > 0)
	assert_eq(renderer.stats().placeholder_batches, 0, "every committed asset is READY")
	for path in uncached:
		assert_false(ResourceLoader.has_cached(path), "catalog scatter_mesh not loaded: " + path)
	for node: Node in renderer.get_children():
		var mesh := (node as MultiMeshInstance3D).multimesh.mesh
		assert_true(mesh.resource_path.begins_with("res://assets/render_assets/"), mesh.resource_path)


func test_not_ready_asset_renders_as_bounds_scaled_placeholder_and_stays_meaningful() -> void:
	var stub := StubRenderRegistry.hiding(catalog, [SPRUCE, GRASS])
	renderer.free()
	renderer = ScatterRenderer.new()
	var cache := RenderAssetCache.new(RenderConfig.load_from().section("budgets"))
	renderer.setup(catalog, stub, cache)
	renderer.set_lod_profile(full_profile(0.0, 0.0))  # a thinning profile must not hide a NOT_READY asset
	doc.scatter = _layer_of([SPRUCE, GRASS, BOULDER])
	_build()
	var spruce_cell := renderer.cell_for(SPRUCE, 10.0, 10.0)
	assert_eq(spruce_cell, ScatterRenderer.cell_of(10.0, 10.0), "NOT_READY is meaningful: 32 m cells")
	assert_eq(renderer.rendered_count(spruce_cell, SPRUCE), 1, "never thinned")
	assert_eq(renderer.rendered_count(renderer.cell_for(GRASS, 10.0, 10.0), GRASS), 1, "placeholder grass is not decorative")
	assert_eq(renderer.stats().placeholder_batches, 2)
	var node := renderer.multimesh_for(spruce_cell, SPRUCE)
	assert_true(node.multimesh.mesh is BoxMesh, "the shared placeholder box")
	var bounds := catalog.get_asset(SPRUCE).bounds
	var xf := renderer.instance_transform(spruce_cell, SPRUCE, 0)
	assert_near(xf.basis.x.length(), bounds.size.x, 1e-4, "scaled to the catalog bounds")
	assert_near(xf.basis.y.length(), bounds.size.y, 1e-4)
	assert_near(xf.origin.y, doc.sample_height(10.0, 10.0) + bounds.get_center().y, 1e-3)
	assert_true((renderer.multimesh_for(renderer.cell_for(BOULDER, 10.0, 10.0), BOULDER).multimesh.mesh is BoxMesh) == false)
	assert_true(cache.stats().entries <= 8, "no resources were requested for the NOT_READY assets")


func test_scatter_tools_refuse_not_ready_assets() -> void:
	var h := ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness")
	h.doc.scatter = ScatterLayer.new()
	var stub := StubRenderRegistry.hiding(h.catalog, [SPRUCE])
	h.ctx.render_ready = stub.is_ready
	var message := "%s is not ready: render derivatives missing." % h.catalog.get_asset(SPRUCE).display_name
	for tool_id: String in ["scatter", "fill"]:
		h.ctrl.set_tool(tool_id)
		h.diagnostics.clear()
		h.act("tool_begin", h.at(40, 40, 1.0))
		assert_false(h.ctrl.has_active_operation(), tool_id + " refuses")
		assert_eq(h.diagnostics, [message], tool_id)
	h.ctrl.set_tool("erase")
	h.act("tool_begin", h.at(40, 40, 2.0))
	assert_true(h.ctrl.has_active_operation(), "erase never needs readiness")
	h.act("tool_end", h.at(40, 40, 2.1))
	assert_eq(h.doc.scatter.count(), 0)
	h.teardown()


class KnownWarningFilter extends Logger:
	var unexpected: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if rationale != "" else code
		if not text.contains(KNOWN_T3D_WARNING):
			unexpected.append("%s (%s:%d %s)" % [text, file, line, function])

	func _log_message(_message: String, _error: bool) -> void:
		pass


## Windowed run only: gentle_hills with its scatter drawn through WorldLayers, screenshot saved when
## WP_SCATTER_EVIDENCE_DIR is set.
func test_gpu_rendered_gentle_hills_scatter_screenshot() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("    rendered scatter check: NOT RUN: no rendering device (headless)")
		return
	allow_logged_errors()
	var filter := KnownWarningFilter.new()
	OS.add_logger(filter)
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 800)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
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
	sun.shadow_enabled = true
	vp.add_child(sun)
	var adapter := TerrainAdapter.new()
	vp.add_child(adapter)
	adapter.set_camera(cam)
	assert_empty_string(adapter.initialize(doc), "terrain")
	var layers := WorldLayers.new()
	vp.add_child(layers)
	layers.setup(catalog)
	layers.set_camera(cam)
	layers.set_lod_profile(full_profile())
	layers.rebuild(doc)
	cam.look_at_from_position(Vector3(-15, 38, 75), Vector3(-15, 0, 0), Vector3.UP)
	cam.current = true
	for i in 16:
		await tree.process_frame
		layers.service_frame(4.0)
	layers.settle_now()
	await tree.process_frame
	var img := vp.get_texture().get_image()
	var dir := OS.get_environment("WP_SCATTER_EVIDENCE_DIR")
	if dir != "" and img != null:
		DirAccess.make_dir_recursive_absolute(dir)
		img.save_png(dir.path_join("gentle_hills_scatter.png"))
	assert_eq(layers.stats().authored, 550)
	assert_eq(layers.stats().instances, 550)
	assert_true(img != null and img.get_width() == 1280, "screenshot captured")
	vp.get_parent().remove_child(vp)
	vp.free()
	assert_true(filter.unexpected.is_empty(), str(filter.unexpected))
	OS.remove_logger(filter)
