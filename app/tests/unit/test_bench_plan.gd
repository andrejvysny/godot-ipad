extends TestCase
## BenchPlan: step matrix, profile table, deterministic synthetic objects, summary statistics.


func _world() -> Array:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var opened := SessionWorldOps.load_fixture("gentle_hills", catalog)
	return [opened[0], catalog]


func _signature(records: Array[ObjectRecord]) -> Array:
	var out := []
	for r in records:
		out.append([r.asset_id, r.position, r.rotation_xyzw, r.uniform_scale])
	return out


func test_default_steps_matrix() -> void:
	var steps := BenchPlan.default_steps(PackedInt32Array([0, 1000, 5000]))
	assert_eq(steps.size(), 3 * 5 * 2 + 2 + 1)
	var ids := {}
	for step in steps:
		ids[step.id] = true
	assert_eq(ids.size(), steps.size(), "ids unique (repeat has a suffix)")
	var first := steps[0]
	var last := steps[steps.size() - 1]
	assert_true(last.repeat and not first.repeat)
	assert_eq(last.id, str(first.id) + "-repeat")
	for key in ["count", "profile", "camera"]:
		assert_eq(last[key], first[key], key)
	assert_eq(steps[30].profile, "terrain_hidden")
	assert_eq(steps[30].count, 0)
	assert_eq(steps[31].camera, "ground")
	assert_eq(steps[0].workload, "terrain_only")
	assert_eq(steps[10].workload, "primitive")
	assert_eq(steps[30].workload, "empty_scene_diagnostic")
	var diagnostic := steps.filter(func(st: Dictionary) -> bool: return st.diagnostic and st.profile != "terrain_hidden")
	assert_eq(diagnostic.size(), 3 * 2 + 0, "only legacy_shadows_diagnostic steps are diagnostic ablations")
	assert_eq(diagnostic[0].profile, "legacy_shadows_diagnostic")


func test_default_steps_subset_and_no_hidden() -> void:
	var profiles: Array[String] = ["scale_050"]
	var cameras: Array[String] = ["ground"]
	var steps := BenchPlan.default_steps(PackedInt32Array([0, 5]), profiles, cameras, false)
	assert_eq(steps.size(), 2 + 1)


func test_profile_settings_table() -> void:
	assert_eq(BenchPlan.PROFILES, ["scale_100", "scale_075", "scale_065", "scale_050", "legacy_shadows_diagnostic"])
	assert_eq(BenchPlan.profile_settings("scale_100"), {"shadows": false, "splits": 4, "shadow_distance": 100.0,
		"terrain_shadows": false, "scale": 1.0, "terrain_visible": true})
	for profile in BenchPlan.PROFILES.slice(0, 4):
		var s := BenchPlan.profile_settings(profile)
		assert_false(s.shadows or s.terrain_shadows, profile + " has no shadows")
	assert_eq(BenchPlan.profile_settings("scale_075").scale, 0.75)
	assert_eq(BenchPlan.profile_settings("scale_065").scale, 0.65)
	assert_eq(BenchPlan.profile_settings("scale_050").scale, 0.5)
	var legacy := BenchPlan.profile_settings("legacy_shadows_diagnostic")
	assert_eq([legacy.shadows, legacy.splits, legacy.shadow_distance, legacy.terrain_shadows, legacy.scale],
		[true, 4, 100.0, true, 1.0])
	assert_false(BenchPlan.profile_settings("terrain_hidden").terrain_visible)
	assert_false(BenchPlan.profile_settings("terrain_hidden").shadows)


func test_mesh_ablation_profiles() -> void:
	assert_eq(BenchPlan.profile_settings("terrain_mesh_24").mesh_size, 24)
	assert_eq(BenchPlan.profile_settings("terrain_mesh_32").mesh_size, 32)
	assert_false(BenchPlan.profile_settings("scale_100").has("mesh_size"))
	assert_true(BenchScenarios.profile_names().has("terrain_mesh_24"))
	assert_true(BenchScenarios.profile_names().has("terrain_mesh_32"))


func test_bench_object_id_format_and_determinism() -> void:
	var id := BenchPlan.bench_object_id(1234, 0)
	assert_true(ObjectRecord.is_uuid(id), id)
	assert_eq(id, id.to_lower())
	assert_eq(id[14], "4", "version nibble")
	assert_true(id[19] in ["8", "9", "a", "b"], "variant bits")
	assert_eq(BenchPlan.bench_object_id(1234, 0), id)
	assert_ne(BenchPlan.bench_object_id(1234, 1), id)
	assert_ne(BenchPlan.bench_object_id(1235, 0), id)


func test_synth_objects_deterministic_and_valid() -> void:
	var world := _world()
	var doc: WorldDocument = world[0]
	var catalog: AssetCatalog = world[1]
	var a := BenchPlan.synth_objects(doc, catalog, 200, 7)
	var b := BenchPlan.synth_objects(doc, catalog, 200, 7)
	var c := BenchPlan.synth_objects(doc, catalog, 200, 8)
	assert_eq(a.size(), 200)
	assert_eq(_signature(a), _signature(b), "same seed, same objects")
	assert_ne(_signature(a), _signature(c), "other seed differs")
	var ids := {}
	for r in a:
		ids[r.object_id] = true
		var asset := catalog.get_asset(r.asset_id)
		if not assert_true(asset != null, "known asset " + r.asset_id):
			continue
		assert_true(asset.scale_in_range(r.uniform_scale), "scale in range")
		assert_true(doc.layout.is_inside_world(r.position[0], r.position[2]), "inside the document layout")
		assert_true(is_finite(r.position[1]), "finite y")
		assert_eq(r.grounding, WorldConstants.GROUNDING_FOLLOW)
		assert_eq(r.origin, WorldConstants.ORIGIN_MANUAL)
		assert_true(ObjectRecord.is_uuid(r.object_id))
	assert_eq(ids.size(), 200, "unique ids")
	assert_eq(a.map(func(r: ObjectRecord) -> String: return r.object_id),
			b.map(func(r: ObjectRecord) -> String: return r.object_id), "same seed, same ids")
	assert_eq(BenchPlan.synth_objects(doc, catalog, 0, 7).size(), 0)


func test_summarize_known_array() -> void:
	var frame := PackedFloat64Array()
	for i in range(1, 101):
		frame.append(float(i))
	var s := BenchPlan.summarize(frame, PackedFloat64Array([1.0, 2.0, 3.0, 4.0]), PackedFloat64Array([5.0]))
	assert_eq(s.frames, 100)
	assert_near(s.frame_p50_ms, 50.0, 1e-9)
	assert_near(s.frame_p95_ms, 95.0, 1e-9)
	assert_near(s.frame_p99_ms, 99.0, 1e-9)
	assert_near(s.frame_max_ms, 100.0, 1e-9)
	assert_eq(s.over_16_7, 84)
	assert_eq(s.over_33_4, 67)
	assert_near(s.target_ms, 1000.0 / 60.0, 1e-9)
	assert_eq(s.missed_target, 75, "intervals over 1.5 x 16.67 = 25 ms")
	assert_eq(s.hitches_over_50_ms, 50)
	assert_eq(s.over_100_ms, 0)
	assert_eq(s.over_250_ms, 0)
	assert_near(s.gpu_p50_ms, 2.0, 1e-9)
	assert_near(s.gpu_p99_ms, 4.0, 1e-9)
	assert_near(s.cpu_p95_ms, 5.0, 1e-9)
	assert_eq([s.gpu_samples, s.gpu_status, s.frame_interval_source], [4, "AVAILABLE", "wall_clock_proxy"])
	var slow := BenchPlan.summarize(PackedFloat64Array([60.0, 120.0, 300.0]), PackedFloat64Array(), PackedFloat64Array())
	assert_eq([slow.hitches_over_50_ms, slow.over_100_ms, slow.over_250_ms], [3, 2, 1])
	assert_near(BenchPlan.summarize(PackedFloat64Array([40.0]), PackedFloat64Array(), PackedFloat64Array(), "AVAILABLE", "AVAILABLE", 30.0).target_ms, 1000.0 / 30.0, 1e-9)


func test_summarize_without_valid_gpu_samples_is_null_not_zero() -> void:
	var s := BenchPlan.summarize(PackedFloat64Array([16.0]), PackedFloat64Array(), PackedFloat64Array(), "UNSUPPORTED", "UNSUPPORTED")
	assert_eq([s.gpu_p50_ms, s.gpu_p95_ms, s.gpu_p99_ms, s.cpu_p50_ms, s.cpu_p99_ms], [null, null, null, null, null])
	assert_eq([s.gpu_samples, s.gpu_status], [0, "UNSUPPORTED"])
	assert_eq(JSON.parse_string(JSON.stringify(s)).gpu_p50_ms, null)
	var measured_zero := BenchPlan.summarize(PackedFloat64Array([16.0]), PackedFloat64Array([0.0]), PackedFloat64Array([0.0]))
	assert_eq(measured_zero.gpu_p50_ms, 0.0, "a measured zero is kept")
	assert_near(BenchPlan.summarize(PackedFloat64Array(), PackedFloat64Array(), PackedFloat64Array()).frame_max_ms, 0.0, 0.0)


func test_parse_bench_args() -> void:
	assert_eq(SessionWorldOps.parse_bench_args(PackedStringArray(["--bench-frames=5"])), {})
	var plain := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench", "--bench-quit"]))
	assert_eq([plain.enabled, plain.counts, plain.frames], [true, PackedInt32Array(), 0])
	var full := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench", "--bench-counts=0,10",
		"--bench-frames=60", "--bench-warmup=0", "--bench-seed=-7", "--bench-profiles=scale_100,scale_050",
		"--bench-cameras=ground"]))
	assert_eq([full.counts, full.frames, full.warmup, full.seed], [PackedInt32Array([0, 10]), 60, 0, -7])
	assert_eq(full.profiles, ["scale_100", "scale_050"])
	assert_eq(full.cameras, ["ground"])
	for bad in ["--bench-counts=a", "--bench-counts=-1", "--bench-frames=0", "--bench-frames=x", "--bench-warmup=-1",
			"--bench-seed=1.5", "--bench-profiles=nope", "--bench-cameras=top", "--bench-profiles="]:
		var res := SessionWorldOps.parse_bench_args(PackedStringArray(["--render-bench", bad]))
		assert_true(res.has("error") and not res.has("enabled"), bad)


func test_frame_stats_p99_in_snapshot() -> void:
	var fs := FrameStats.new(200)
	for i in range(1, 101):
		fs.add(float(i))
	assert_near(fs.p99(), 99.0, 1e-9)
	assert_near(fs.snapshot().p99_ms, 99.0, 1e-9)
