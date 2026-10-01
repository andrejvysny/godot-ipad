extends TestCase
## ScatterRenderer / WorldLayers: MultiMesh cells per (32 m cell, asset), re-draping, dirty-only
## rebuilds, performance sanity. Tests whose name contains "gpu" run only in a windowed run
## (scripts/dev.py test --rendered); WP_SCATTER_EVIDENCE_DIR also writes the screenshot there.

const PEBBLES := "nature.rock.pebbles_a"
const GRASS := "nature.cover.grass_tuft_a"
const SPRUCE := "nature.tree.spruce_a"
const KNOWN_T3D_WARNING := "instance_reset_physics_interpolation() is deprecated"

var catalog: AssetCatalog
var renderer: ScatterRenderer
var doc: WorldDocument


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	doc = WorldCodec.read_generation("res://fixtures/gentle_hills", catalog)[0]
	renderer = ScatterRenderer.new()
	renderer.setup(catalog)


func after_each() -> void:
	renderer.free()


## {Vector2i cell: {asset_id: count}} straight from the layer, skipping instances without a sample.
func _expected(layer: ScatterLayer) -> Dictionary:
	var out := {}
	for i in layer.count():
		if is_nan(doc.sample_height(layer.x[i], layer.z[i])):
			continue
		var cell := ScatterRenderer.cell_of(layer.x[i], layer.z[i])
		var by_asset: Dictionary = out.get(cell, {})
		by_asset[layer.asset_of(i)] = int(by_asset.get(layer.asset_of(i), 0)) + 1
		out[cell] = by_asset
	return out


func _assert_matches_layer(note: String) -> void:
	var expected := _expected(doc.scatter)
	var total := 0
	var multimeshes := 0
	for cell: Vector2i in expected:
		for asset_id: String in expected[cell]:
			assert_eq(renderer.rendered_count(cell, asset_id), int(expected[cell][asset_id]), "%s %s %s" % [note, cell, asset_id])
			var node := renderer.multimesh_for(cell, asset_id)
			if assert_true(node != null, "%s node %s" % [note, cell]):
				assert_eq(node.multimesh.instance_count, int(expected[cell][asset_id]))
			total += int(expected[cell][asset_id])
			multimeshes += 1
	var stats := renderer.stats()
	assert_eq(stats.instances, total, note + " total")
	assert_eq(stats.cells, expected.size(), note + " cells")
	assert_eq(stats.multimeshes, multimeshes, note + " multimeshes")
	assert_eq(renderer.get_child_count(), multimeshes, note + " nodes")


func _forest_config() -> Dictionary:
	return {"name": "T", "items": [{"asset_id": SPRUCE, "weight": 1.0}], "density": 1.0, "spacing": 0.5,
			"slope_min": 0.0, "slope_max": 90.0, "align": false}


func test_gentle_hills_renders_550_instances_per_cell_and_asset() -> void:
	renderer.rebuild_all(doc)
	assert_eq(doc.scatter.count(), 550)
	assert_eq(renderer.stats().instances, 550)
	_assert_matches_layer("initial")
	assert_true(float(renderer.stats().last_rebuild_ms) >= 0.0)


func test_add_erase_and_undo_keep_counts_in_sync_with_dirty_only_rebuilds() -> void:
	renderer.rebuild_all(doc)
	var untouched := renderer.multimesh_for(ScatterRenderer.cell_of(-100.0, -100.0), GRASS)
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
	if untouched != null and ScatterRenderer.cell_of(-100.0, -100.0) != ScatterRenderer.cell_of(60.0, 60.0):
		assert_true(renderer.multimesh_for(ScatterRenderer.cell_of(-100.0, -100.0), GRASS) == untouched, "far cell not rebuilt")
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
	renderer.rebuild_all(doc)
	var cell := ScatterRenderer.cell_of(10.0, 10.0)
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
	renderer.rebuild_all(doc)
	var cell := ScatterRenderer.cell_of(10.0, 10.0)
	var up0 := renderer.instance_transform(cell, PEBBLES, 0).basis.y
	var up1 := renderer.instance_transform(cell, PEBBLES, 1).basis.y
	assert_vec_near(up0, Vector3.UP, 1e-5, "unaligned stays upright")
	assert_vec_near(up1, doc.sample_normal(16.0, 10.0), 1e-4, "aligned follows the normal")
	assert_true(up1.distance_to(Vector3.UP) > 1e-3, "the hill is not flat here")
	assert_eq(renderer.multimesh_for(cell, GRASS).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_eq(renderer.multimesh_for(cell, SPRUCE).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_eq(renderer.multimesh_for(cell, PEBBLES).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


func test_hidden_vegetation_follows_the_rule_including_later_cells() -> void:
	var rule := RenderConfig.load_from().vegetation_rule()
	var layer := ScatterLayer.new()
	for id: String in [GRASS, SPRUCE, PEBBLES, "nature.rock.boulder_a"]:
		layer.add(id, catalog.get_asset(id).version, 10.0, 10.0, 0.0, 1.0, 0)
	doc.scatter = layer
	renderer.rebuild_all(doc)
	var cell := ScatterRenderer.cell_of(10.0, 10.0)
	renderer.set_vegetation_hidden(true, rule)
	assert_false(renderer.multimesh_for(cell, GRASS).visible)
	assert_false(renderer.multimesh_for(cell, SPRUCE).visible)
	assert_true(renderer.multimesh_for(cell, PEBBLES).visible, "excluded ground cover stays")
	assert_true(renderer.multimesh_for(cell, "nature.rock.boulder_a").visible)
	layer.add(SPRUCE, catalog.get_asset(SPRUCE).version, 100.0, 100.0, 0.0, 1.0, 0)
	renderer.mark_all()
	renderer.flush()
	assert_false(renderer.multimesh_for(ScatterRenderer.cell_of(100.0, 100.0), SPRUCE).visible, "cell built while hidden")
	renderer.set_vegetation_hidden(false, rule)
	assert_true(renderer.multimesh_for(cell, GRASS).visible)
	assert_true(renderer.multimesh_for(ScatterRenderer.cell_of(100.0, 100.0), SPRUCE).visible)


func test_world_layers_present_change_marks_scatter_and_height_cells() -> void:
	var layers := WorldLayers.new()
	layers.setup(catalog)
	layers.rebuild(doc)
	assert_eq(layers.stats().instances, 550)
	var change := WorldChange.new()
	change.before_scatter = doc.scatter.clone()
	change.after_scatter = doc.scatter.clone()
	layers.present_change(doc, change)
	assert_true(layers.scatter.has_dirty(), "scatter change marks cells")
	layers.scatter.flush()
	assert_false(layers.scatter.has_dirty())
	layers.heights_changed(Rect2(0.0, 0.0, 10.0, 10.0))
	assert_true(layers.scatter.has_dirty(), "height rect marks cells")
	layers.scatter.flush()
	var objects_only := WorldChange.new()
	objects_only.before_objects["x"] = null
	layers.present_change(doc, objects_only)
	assert_false(layers.scatter.has_dirty(), "object-only changes redraw nothing")
	layers.free()


func test_perf_rebuild_all_20000_instances() -> void:
	var layer := ScatterLayer.new()
	var ids := [SPRUCE, GRASS, PEBBLES, "nature.cover.fern_a", "nature.rock.boulder_a"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in WorldConstants.MAX_SCATTER_INSTANCES:
		var id: String = ids[i % ids.size()]
		layer.add(id, catalog.get_asset(id).version, rng.randf_range(-127.0, 127.0), rng.randf_range(-127.0, 127.0),
				rng.randf_range(-PI, PI), 1.0, ScatterLayer.FLAG_TILT if i % 2 == 0 else 0)
	doc.scatter = layer
	renderer.rebuild_all(doc)
	var full_ms := float(renderer.stats().last_rebuild_ms)
	renderer.mark_rect(Rect2(0.0, 0.0, 20.0, 20.0), true)
	renderer.flush()
	var one_cell_ms := float(renderer.stats().last_rebuild_ms)
	print("    PERF scatter rebuild_all 20000: %.1f ms (%d multimeshes); one dirty cell: %.2f ms" % [
			full_ms, renderer.stats().multimeshes, one_cell_ms])
	assert_eq(renderer.stats().instances, 20000)
	assert_true(full_ms < 5000.0, "rebuild_all sanity bound")
	assert_true(one_cell_ms < full_ms, "a dirty cell is cheaper than a full rebuild")


func test_perf_scatter_dab_cost() -> void:
	doc.scatter = ScatterLayer.new()
	var placer := ScatterPlacer.new(doc, catalog, {"name": "Meadow", "items": [{"asset_id": GRASS, "weight": 1.0}],
			"density": 3.0, "spacing": 0.35, "slope_min": 0.0, "slope_max": 90.0, "align": true}, true, 2)
	var tries := ScatterOperation.dab_tries(3.0, 7.0, 0.7, 1.0)
	var t0 := Time.get_ticks_usec()
	var dabs := 40
	for d in dabs:
		var c := Vector2(-60.0 + float(d) * 3.5, 20.0)
		for _i in tries:
			var a := placer.rng().randf() * TAU
			var r := 7.0 * sqrt(placer.rng().randf())
			placer.try_add(c.x + cos(a) * r, c.y + sin(a) * r)
	var per_dab_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(dabs)
	print("    PERF scatter dab (meadow, r 7, %d tries): %.3f ms/dab, %d instances" % [tries, per_dab_ms, doc.scatter.count()])
	assert_true(per_dab_ms < 50.0, "dab sanity bound")


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
	layers.rebuild(doc)
	cam.look_at_from_position(Vector3(-15, 38, 75), Vector3(-15, 0, 0), Vector3.UP)
	cam.current = true
	for i in 16:
		await tree.process_frame
	var img := vp.get_texture().get_image()
	var dir := OS.get_environment("WP_SCATTER_EVIDENCE_DIR")
	if dir != "" and img != null:
		DirAccess.make_dir_recursive_absolute(dir)
		img.save_png(dir.path_join("gentle_hills_scatter.png"))
	assert_eq(layers.stats().instances, 550)
	assert_true(img != null and img.get_width() == 1280, "screenshot captured")
	vp.get_parent().remove_child(vp)
	vp.free()
	assert_true(filter.unexpected.is_empty(), str(filter.unexpected))
	OS.remove_logger(filter)
