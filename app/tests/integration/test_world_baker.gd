extends ApplyTestCase
## World bake (ADR 0017 A4): a frozen world becomes an ordinary scene that, reloaded from disk like a game does,
## reproduces objects (ids, transforms), scatter counts per binding, paths and the exact terrain buffers.

var catalog: AssetCatalog
var doc: WorldDocument
var base := ""


func before_each() -> void:
	super()
	catalog = AssetCatalog.load_from()[0]
	doc = ApplyTestKit.make_doc(catalog)
	base = "user://test_scratch/%s/bake" % current_test.replace("::", "_")


func _ctx() -> BakeContext:
	var deliveries := ApplyDeliveries.new()
	deliveries.catalog = catalog
	var ctx := BakeContext.new(doc, base, deliveries)
	ctx.identity = {"world_id": doc.world_id}
	return ctx


func test_bake_reproduces_the_document() -> void:
	var ctx := _ctx()
	assert_empty_string(WorldBaker.bake(ctx), "bake")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(ctx.scene_res())), "world.tscn written")
	var summary := WorldSceneCheck.summarize(ctx.scene_res(), tree)
	assert_eq(WorldSceneCheck.compare(summary, doc), PackedStringArray(), "scene reproduces the document")
	assert_eq(summary.objects.size(), 3, "object instances")
	assert_eq(summary.regions.size(), 4, "terrain regions")
	assert_eq(summary.paths.size(), 2, "path ribbons")
	assert_eq(ctx.stats.paths, 2)
	var total := 0
	for n: int in summary.scatter.values():
		total += n
	assert_eq(total, doc.scatter.count() - int(ctx.stats.scatter_skipped), "scatter instances minus the ones over holes")
	assert_true(summary.scatter_nodes > 4, "scatter is split into cell batches (%d)" % summary.scatter_nodes)
	assert_true(summary.scatter_nodes < doc.scatter.count() / 2, "not one node per instance")


func test_objects_keep_ids_and_exact_transforms() -> void:
	var ctx := _ctx()
	assert_empty_string(WorldBaker.bake(ctx))
	var summary := WorldSceneCheck.summarize(ctx.scene_res(), tree)
	for id: String in doc.objects:
		var rec := doc.get_object(id)
		var def := doc.assets.definition(rec.binding_id)
		assert_true(summary.objects.has(id), "object %s present" % id)
		assert_eq(summary.objects[id].transform, rec.node_transform(def.anchor_local), "exact transform")
		assert_eq(summary.objects[id].binding, rec.binding_id)


func test_terrain_data_is_exact_with_holes_and_tint() -> void:
	var ctx := _ctx()
	assert_empty_string(WorldBaker.bake(ctx))
	var summary := WorldSceneCheck.summarize(ctx.scene_res(), tree)
	var holed: RegionBuffers = doc.get_region(Vector2i(0, 0))
	assert_true((holed.control[1000] & ControlCodec.HOLE_BIT) != 0, "fixture has holes")
	for loc: Vector2i in doc.regions:
		var rb: RegionBuffers = doc.regions[loc]
		assert_eq(summary.regions[loc].height, CanonicalEncoder.sha256_hex(rb.height_bytes()), "height %s" % loc)
		assert_eq(summary.regions[loc].control, CanonicalEncoder.sha256_hex(rb.control_bytes()), "control %s" % loc)
		assert_eq(summary.regions[loc].color, CanonicalEncoder.sha256_hex(rb.color_bytes()), "tint %s" % loc)
	assert_eq(summary.collision_mode, 1, "default policy: dynamic game collision")


func test_scatter_over_holes_is_skipped_and_counted() -> void:
	var binding := doc.assets.bundled_binding_for(ApplyTestKit.GRASS)
	var holed: RegionBuffers = doc.get_region(Vector2i(0, 0))
	var hole_x := 232.0 * 0.5 + 0.25
	var hole_z := 3.0 * 0.5 + 0.25
	assert_true((doc.get_control_at_sample(232, 3) & ControlCodec.HOLE_BIT) != 0, "sample is a hole (%d)" % holed.control[1000])
	doc.scatter.add(binding, hole_x, hole_z, 0.0, 1.0, 0, 100000)
	var ctx := _ctx()
	assert_empty_string(WorldBaker.bake(ctx))
	assert_true(int(ctx.stats.scatter_skipped) >= 1, "the instance over the hole is skipped")
	assert_eq(WorldSceneCheck.compare(WorldSceneCheck.summarize(ctx.scene_res(), tree), doc), PackedStringArray())


func test_generated_scene_has_no_editor_or_preview_script() -> void:
	var ctx := _ctx()
	assert_empty_string(WorldBaker.bake(ctx))
	var text := FileAccess.get_file_as_string(ctx.scene_res())
	assert_eq(WorldSceneCheck.script_errors(text), PackedStringArray(), "no forbidden script reference")
	assert_false(text.contains("addons/assetstudio"), "no AssetStudio reference")
	assert_false(text.contains("addons/world_painter/editor") or text.contains("addons/world_painter/preview")
			or text.contains("addons/world_painter/live"), "no editor/preview/live reference")
	assert_eq(WorldSceneCheck.script_errors('[ext_resource type="Script" path="res://addons/world_painter/preview/x.gd" id="1"]'),
			PackedStringArray(["scene references res://addons/world_painter/preview/x.gd",
			"scene carries the script res://addons/world_painter/preview/x.gd"]), "the check itself catches a preview script")


func test_scatter_collision_is_opt_in_per_binding() -> void:
	var ctx := _ctx()
	ctx.collision_bindings = PackedStringArray([doc.assets.bundled_binding_for(ApplyTestKit.FERN)])
	assert_empty_string(WorldBaker.bake(ctx))
	var packed := ResourceLoader.load(ctx.scene_res(), "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	var inst := packed.instantiate()
	var bodies := inst.find_children("Collision", "StaticBody3D", true, false)
	var ferns := 0
	for node in inst.get_node("Scatter").get_children():
		var is_fern: bool = node.get_meta("wp_binding_id") == ctx.collision_bindings[0]
		ferns += 1 if is_fern else 0
		assert_eq(node.get_child_count() > 0, is_fern, "only the opted-in binding has collision")
	assert_eq(bodies.size(), ferns, "one body per opted-in node")
	inst.free()
