extends TestCase
## Representative bench scenarios (spec §20.1-§20.3): deterministic worlds with exact counts, camera paths, step
## planning, streaming statistics and the CLI flags. Documents only; nothing is presented or saved.

const SEED := 1234

var _editor: AssetCatalog
var _bench: AssetCatalog


func before_each() -> void:
	_editor = AssetCatalog.load_from()[0]
	_bench = AssetCatalog.load_from("res://assets/bench")[0]


func _build(name: String, overrides: Dictionary = {}, seed_value: int = SEED) -> Dictionary:
	var made := BenchWorlds.build(name, _editor, _bench, seed_value, overrides)
	assert_eq(made.error, "", name)
	return made


func _signature(doc: WorldDocument) -> Array:
	var out := []
	for id in doc.sorted_object_ids():
		var r := doc.get_object(id)
		out.append([id, doc.assets.definition(r.binding_id).asset_id, r.position, r.rotation_xyzw, r.uniform_scale])
	return out


func _inside(doc: WorldDocument, x: float, z: float) -> bool:
	return doc.layout.is_inside_world(x, z)


func test_mixed_world_is_deterministic_with_exact_counts_and_consistent_heights() -> void:
	var a := _build("mixed_world_10k", {"objects": 500, "scatter": 400})
	var b := _build("mixed_world_10k", {"objects": 500, "scatter": 400})
	var doc: WorldDocument = a.doc
	assert_eq(doc.objects.size(), 500)
	assert_eq(doc.scatter.count(), 400)
	assert_eq(a.population.authored_meaningful, 500)
	assert_eq(a.population.decorative, 400)
	assert_eq(a.population.layout, "km1")
	assert_eq(_signature(doc), _signature(b.doc), "same seed, same world")
	assert_eq(doc.scatter.x, (b.doc as WorldDocument).scatter.x)
	assert_eq(a.anchors.focus, b.anchors.focus)
	var other := _build("mixed_world_10k", {"objects": 500, "scatter": 400}, SEED + 1)
	assert_ne(_signature(doc), _signature(other.doc), "a different seed gives a different world")
	assert_eq(a.population.by_asset, {"bench.tree.broadleaf_geo": 175, "bench.tree.pine_cards": 175,
			"bench.shrub.bush_cards": 90, "bench.rock.slab_a": 50, "bench.structure.tower_a": 10})
	for i in 500:
		assert_true(doc.objects.has(BenchPlan.bench_object_id(SEED, i)), "deterministic id %d" % i)
	for id in doc.objects:
		var r: ObjectRecord = doc.objects[id]
		assert_true(_inside(doc, r.position[0], r.position[2]), "inside the layout")
		assert_eq(r.grounding, WorldConstants.GROUNDING_FOLLOW)
		assert_near(r.position[1], doc.sample_height(r.position[0], r.position[2]) + r.height_offset_m, 1e-9)
		assert_eq(r.origin, WorldConstants.ORIGIN_MANUAL)
	var layer := doc.scatter
	for i in layer.count():
		assert_eq(doc.assets.definition(layer.binding_of(i)).asset_id, "bench.cover.grass_cards")
		assert_true(_inside(doc, layer.x[i], layer.z[i]), "grass inside the layout")


func test_forest_scenarios_use_one_species_each_inside_patches() -> void:
	var geo := _build("geometry_forest_10k", {"objects": 300})
	var cards := _build("card_forest_10k", {"objects": 300})
	assert_eq(geo.population.by_asset, {"bench.tree.broadleaf_geo": 300})
	assert_eq(cards.population.by_asset, {"bench.tree.pine_cards": 300})
	assert_eq(geo.population.patches, 24)
	assert_eq(geo.population.decorative, 0)
	var layout_data := BenchWorlds._patch_layout(geo.doc, BenchScenarios.definition("geometry_forest_10k"), SEED)
	var inside := 0
	for r: ObjectRecord in (geo.doc as WorldDocument).objects.values():
		var p := Vector2(r.position[0], r.position[2])
		inside += 0 if BenchWorlds.is_open(layout_data, p) else 1
	assert_eq(inside, 300, "every tree stands in a patch, outside its clearings")
	assert_true(geo.anchors.densest_count > 0)


func test_grass_is_decorative_only_and_stays_in_the_open() -> void:
	var made := _build("grass_50k", {"scatter": 1000})
	var doc: WorldDocument = made.doc
	assert_eq([doc.objects.size(), doc.scatter.count()], [0, 1000])
	var layout_data := BenchWorlds._patch_layout(doc, BenchScenarios.definition("grass_50k"), SEED)
	var in_forest := 0
	for i in doc.scatter.count():
		in_forest += 0 if BenchWorlds.is_open(layout_data, Vector2(doc.scatter.x[i], doc.scatter.z[i])) else 1
	assert_eq(in_forest, 0)
	var mixed := _build("mixed_world_10k", {"objects": 200, "scatter": 300})
	var forest := BenchWorlds._patch_layout(mixed.doc, BenchScenarios.definition("mixed_world_10k"), SEED)
	for i in (mixed.doc as WorldDocument).scatter.count():
		var p := Vector2(mixed.doc.scatter.x[i], mixed.doc.scatter.z[i])
		assert_true(BenchWorlds.is_open(forest, p), "decorative grass sits in an open area")


func test_full_size_10k_scenarios_have_exact_counts() -> void:
	var geo := _build("geometry_forest_10k")
	assert_eq([geo.doc.objects.size(), geo.doc.scatter.count()], [10000, 0])
	var mixed := _build("mixed_world_10k")
	assert_eq([mixed.doc.objects.size(), mixed.doc.scatter.count()], [10000, 20000])
	assert_eq(mixed.population.by_asset.get("bench.tree.broadleaf_geo"), 3500)
	assert_true(mixed.build_ms > 0.0)


func test_50k_scenarios_are_defined_at_full_size_and_build_small_variants() -> void:
	var def := BenchScenarios.definition("mixed_world_50k")
	assert_eq([def.objects, def.scatter], [50000, 50000])
	assert_eq(BenchScenarios.definition("grass_50k").scatter, 50000)
	var small := _build("mixed_world_50k", {"objects": 400, "scatter": 600})
	assert_eq([small.doc.objects.size(), small.doc.scatter.count()], [400, 600])
	assert_eq(small.population.patches, 40)


func test_terrain_only_and_primitive_scenarios() -> void:
	var legacy := _build("terrain_only_legacy")
	assert_eq([legacy.doc.objects.size(), legacy.doc.scatter.count(), legacy.doc.layout.name()], [0, 0, "legacy"])
	assert_eq(legacy.catalog_kind, "editor")
	var km := _build("terrain_only_1km")
	assert_eq([km.doc.objects.size(), km.doc.layout.name(), km.catalog_kind], [0, "km1", "bench"])
	var primitive := _build("primitive_1k", {"objects": 40})
	assert_eq(primitive.doc.objects.size(), 40)
	assert_eq(primitive.catalog_kind, "editor")
	var first: ObjectRecord = (primitive.doc as WorldDocument).get_object(BenchPlan.bench_object_id(SEED, 0))
	assert_true(first != null and _editor.get_asset((primitive.doc as WorldDocument).assets.definition(first.binding_id).asset_id) != null, "editor catalog primitives with deterministic ids")
	assert_eq(BenchScenarios.definition("primitive_5k").primitive, 5000)
	assert_error_contains(str(BenchWorlds.build("nope", _editor, _bench, SEED).error), "Unknown bench scenario")


func test_asset_diversity_is_reported_not_run() -> void:
	assert_true(BenchScenarios.NOT_RUN.has("asset_diversity"))
	assert_false(BenchScenarios.is_scenario("asset_diversity"))
	assert_true(BenchScenarios.scenario_names().has("asset_diversity"))


func test_plan_steps() -> void:
	var steps := BenchScenarios.plan_steps(["terrain_only_legacy", "mixed_world_10k"], ["performance", "detailed"], [])
	var terrain_kinds := BenchScenarios.default_kinds("terrain_only_legacy")
	assert_false(terrain_kinds.has("canopy") or terrain_kinds.has("edit_move"), "no objects, no canopy or move")
	assert_eq(BenchScenarios.default_kinds("mixed_world_10k").size(), 12)
	assert_eq(steps.size(), 2 * terrain_kinds.size() + 2 * 12 + 1)
	assert_true(steps[steps.size() - 1].repeat)
	assert_eq(steps[steps.size() - 1].id, str(steps[0].id) + "-repeat")
	var ids := {}
	for step in steps:
		ids[step.id] = true
	assert_eq(ids.size(), steps.size())
	var filtered := BenchScenarios.plan_steps(["mixed_world_10k"], ["balanced"], ["focus", "edit_sculpt"])
	assert_eq(filtered.size(), 3)
	assert_eq([filtered[0].workload, filtered[1].workload], ["camera_path", "edit_sculpt"])
	assert_eq(filtered[0].profile, "balanced")
	assert_true(BenchScenarios.plan_steps(["mixed_world_10k"], ["legacy_shadows_diagnostic"], ["focus"])[0].diagnostic)
	assert_true(BenchScenarios.plan_steps([], ["performance"], []).is_empty())


func _ctx(made: Dictionary) -> Dictionary:
	var doc: WorldDocument = made.doc
	return {"anchors": made.anchors, "height": doc.sample_height, "fit_distance": 900.0}


func test_camera_paths_are_deterministic_and_world_relative() -> void:
	var made := _build("mixed_world_10k", {"objects": 300, "scatter": 0})
	var ctx := _ctx(made)
	var made2 := _build("mixed_world_10k", {"objects": 300, "scatter": 0})  # keeps the document alive for the callable
	var again := _ctx(made2)
	for name in BenchScenarios.CAMERA_KINDS:
		for t in [0.0, 1.3, 4.0, 9.9]:
			assert_eq(BenchCameraPaths.pose(name, ctx, t, 10.0), BenchCameraPaths.pose(name, again, t, 10.0), "%s@%s" % [name, t])
	var focus: Vector2 = made.anchors.focus
	var overview := BenchCameraPaths.pose("overview", ctx, 0.0, 10.0)
	assert_near(rad_to_deg(overview.pitch), 70.0, 1e-6)
	assert_eq(overview.distance, 900.0)
	var f := BenchCameraPaths.pose("focus", ctx, 0.0, 10.0)
	assert_near(rad_to_deg(f.pitch), 35.0, 1e-6)
	assert_eq(f.distance, 40.0)
	assert_near((f.pivot as Vector3).x, focus.x, 1e-6)
	var shallow := BenchCameraPaths.pose("shallow", ctx, 0.0, 10.0)
	assert_near(rad_to_deg(shallow.pitch), 15.0, 1e-6)
	assert_eq(shallow.distance, 25.0)
	var canopy := BenchCameraPaths.pose("canopy", ctx, 0.0, 10.0)
	assert_eq(canopy.distance, 6.0)
	assert_true((canopy.pivot as Vector3).y > (f.pivot as Vector3).y + 3.0, "pivot at crown height")
	var near := BenchCameraPaths.pose("travel", ctx, 0.5, 10.0)
	var far := BenchCameraPaths.pose("travel", ctx, 2.5, 10.0)
	assert_eq((near.pivot as Vector3).x, focus.x)
	assert_eq((far.pivot as Vector3).x, (made.anchors.far as Vector2).x)
	assert_eq(BenchCameraPaths.pose("travel", ctx, 4.5, 10.0), near, "alternates every 2 s")
	var start := BenchCameraPaths.pose("path", ctx, 0.0, 10.0)
	var mid := BenchCameraPaths.pose("path", ctx, 2.5, 10.0)
	assert_ne(start.yaw, mid.yaw)
	assert_ne(start.distance, mid.distance, "zooms")
	assert_true(absf(rad_to_deg(float(BenchCameraPaths.pose("path", ctx, 10.0, 10.0).yaw) - float(start.yaw))) > 359.0, "full orbit")
	var summary := BenchCameraPaths.summary("path", ctx, 10.0)
	assert_eq(summary.samples.size(), BenchCameraPaths.SUMMARY_SAMPLES)
	assert_eq(summary, BenchCameraPaths.summary("path", again, 10.0))


func test_stream_stats_match_exact_percentiles_within_the_bin_and_stay_bounded() -> void:
	var stats := BenchStreamStats.new(60.0)
	for i in 100:
		stats.add_frame(float(i + 1))
	var s := stats.summary(RenderCounters.NOT_RUN, RenderCounters.NOT_RUN)
	assert_eq(s.frames, 100)
	assert_near(s.frame_p50_ms, 50.0, 0.11)
	assert_near(s.frame_p95_ms, 95.0, 0.11)
	assert_near(s.frame_p99_ms, 99.0, 0.11)
	assert_eq(s.frame_max_ms, 100.0)
	assert_eq([s.hitches_over_50_ms, s.over_100_ms, s.over_250_ms], [50, 0, 0])
	assert_eq(s.missed_target, 100 - 25, "frames over 1.5 x 16.67 ms")
	assert_eq([s.gpu_p50_ms, s.gpu_p95_ms, s.gpu_p99_ms], [null, null, null], "no timing is null, never 0")
	assert_eq(s.gpu_samples, 0)
	var exact := BenchPlan.summarize(PackedFloat64Array(range(1, 101)), PackedFloat64Array(), PackedFloat64Array())
	for key in ["hitches_over_50_ms", "over_100_ms", "over_250_ms", "missed_target", "over_16_7", "over_33_4"]:
		assert_eq(s[key], exact[key], key)
	stats.add_timing(4.0, 2.0)
	assert_near(stats.summary("AVAILABLE", "AVAILABLE").gpu_p95_ms, 4.0, 0.11)
	stats.add_frame(900.0)
	assert_eq(stats.summary("x", "x").frame_max_ms, 900.0, "overflow bin keeps the exact max")
	var size_before := stats._frame.size()
	for i in 10000:
		stats.add_frame(16.0)
	assert_eq(stats._frame.size(), size_before, "fixed memory")
	stats.reset()
	assert_eq(stats.frames, 0)


func test_parse_bench_args_for_scenarios() -> void:
	var out := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench",
		"--bench-scenarios=mixed_world_10k,grass_50k,asset_diversity", "--bench-profiles=performance,detailed,scale_100",
		"--bench-seconds=60", "--bench-warmup-seconds=5", "--bench-cameras=focus,edit_sculpt", "--bench-quit"]))
	assert_false(out.has("error"), str(out))
	assert_eq(out.scenarios, ["mixed_world_10k", "grass_50k", "asset_diversity"])
	assert_eq(out.profiles, ["performance", "detailed", "scale_100"])
	assert_eq([out.seconds, out.warmup_seconds], [60.0, 5.0])
	assert_eq(out.cameras, ["focus", "edit_sculpt"])
	var sustained := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench", "--bench-sustained-minutes=30"]))
	assert_eq(sustained.sustained_minutes, 30.0)
	var legacy := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench", "--bench-counts=0,10",
		"--bench-profiles=scale_100", "--bench-cameras=ground"]))
	assert_false(legacy.has("error"))
	assert_false(legacy.has("scenarios"))


func test_parse_bench_args_rejects_invalid_values() -> void:
	var cases := {
		"--bench-scenarios=nope": "--bench-scenarios",
		"--bench-seconds=0": "--bench-seconds",
		"--bench-seconds=abc": "--bench-seconds",
		"--bench-warmup-seconds=-1": "--bench-warmup-seconds",
		"--bench-sustained-minutes=0": "--bench-sustained-minutes",
		"--bench-sustained-minutes=500": "--bench-sustained-minutes",
		"--bench-profiles=turbo": "--bench-profiles",
		"--bench-cameras=orbit": "--bench-cameras",
		"--bench-profiles=performance": "needs --bench-scenarios",
		"--bench-seconds=5": "needs --bench-scenarios",
	}
	for arg: String in cases:
		var out := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench", arg]))
		assert_true(out.has("error") and str(out.error).contains(str(cases[arg])), "%s -> %s" % [arg, str(out)])
	var both := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench",
		"--bench-scenarios=grass_50k", "--bench-sustained-minutes=1"]))
	assert_true(str(both.get("error", "")).contains("exclusive"))
	var ground := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench",
		"--bench-scenarios=grass_50k", "--bench-cameras=ground"]))
	assert_true(str(ground.get("error", "")).contains("not valid"), "legacy camera names do not apply to scenarios")


func test_size_transition_paths_keep_world_and_plan_identity() -> void:
	var made := _build("mixed_world_10k", {"objects": 10, "scatter": 0})
	var ctx := _ctx(made)
	var before := CanonicalEncoder.authored_hash(made.doc)
	ctx.threshold_distance = 700.0
	for name in ["zoom_transition", "threshold_oscillation", "rotation"]:
		assert_true(name in BenchScenarios.camera_names())
		var steps := BenchScenarios.plan_steps(["mixed_world_10k"], ["performance"], [name])
		assert_eq(steps.size(), 2)
		assert_eq(steps[0].camera, name)
		assert_eq(steps[0].workload, "camera_path")
	var close := BenchCameraPaths.pose("zoom_transition", ctx, 0.0, 10.0)
	var wide := BenchCameraPaths.pose("zoom_transition", ctx, 10.0, 10.0)
	assert_eq(close.distance, BenchCameraPaths.FOCUS_DISTANCE_M)
	assert_near(wide.distance, float(ctx.fit_distance), 0.001)
	assert_eq(close.pivot, wide.pivot)
	var rotation := BenchCameraPaths.pose("rotation", ctx, 5.0, 10.0)
	assert_eq(rotation.distance, BenchCameraPaths.FOCUS_DISTANCE_M)
	assert_ne(rotation.yaw, close.yaw)
	var threshold_low := BenchCameraPaths.pose("threshold_oscillation", ctx, 1.5, 10.0)
	var threshold_high := BenchCameraPaths.pose("threshold_oscillation", ctx, 0.5, 10.0)
	assert_near(threshold_low.distance, float(ctx.threshold_distance) * 0.95, 0.001)
	assert_near(threshold_high.distance, float(ctx.threshold_distance) * 1.05, 0.001)
	assert_eq(CanonicalEncoder.authored_hash(made.doc), before)


func test_oscillation_straddles_projected_overview_boundary() -> void:
	var snapshot := RenderCameraSnapshot.new()
	snapshot.valid = true
	snapshot.viewport_size = Vector2(1180.0, 820.0)
	snapshot.internal_size = snapshot.viewport_size
	snapshot.projection = Projection.create_perspective(60.0, 1180.0 / 820.0, 0.05, 5000.0)
	var bounds := AABB(Vector3(-500.0, -20.0, -500.0), Vector3(1000.0, 60.0, 1000.0))
	var centered := BenchCameraPaths.threshold_distance(snapshot, bounds, Vector3.ZERO, 1500.0, 1.10)
	var controller := OrbitCameraController.new()
	controller.yaw = deg_to_rad(BenchCameraPaths.YAW_DEG)
	controller.pitch = deg_to_rad(BenchCameraPaths.OVERVIEW_PITCH_DEG)
	controller.distance = centered * 0.95
	snapshot.transform = controller.camera_transform()
	assert_true(ProjectedBounds.measure(bounds, snapshot).extent_ratio > 1.10)
	controller.distance = centered * 1.05
	snapshot.transform = controller.camera_transform()
	assert_true(ProjectedBounds.measure(bounds, snapshot).extent_ratio < 1.10)
