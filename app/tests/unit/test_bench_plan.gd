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


func test_profile_settings_table() -> void:
	var current := BenchPlan.profile_settings("current")
	assert_eq(current, {"shadows": true, "splits": 4, "shadow_distance": 100.0, "terrain_shadows": true,
		"scale": 1.0, "terrain_visible": true})
	assert_false(BenchPlan.profile_settings("no_shadows").shadows)
	var lean := BenchPlan.profile_settings("lean_shadows")
	assert_eq([lean.shadows, lean.splits, lean.shadow_distance, lean.terrain_shadows, lean.scale],
		[true, 2, 60.0, false, 1.0])
	assert_eq(BenchPlan.profile_settings("scale_075").scale, 0.75)
	assert_eq(BenchPlan.profile_settings("scale_050").scale, 0.5)
	assert_false(BenchPlan.profile_settings("terrain_hidden").terrain_visible)
	assert_true(BenchPlan.profile_settings("terrain_hidden").shadows)


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
		assert_true(r.position[0] >= WorldConstants.WORLD_MIN and r.position[0] <= WorldConstants.WORLD_MAX_SAMPLE)
		assert_true(r.position[2] >= WorldConstants.WORLD_MIN and r.position[2] <= WorldConstants.WORLD_MAX_SAMPLE)
		assert_true(is_finite(r.position[1]), "finite y")
		assert_eq(r.grounding, WorldConstants.GROUNDING_FOLLOW)
		assert_eq(r.origin, WorldConstants.ORIGIN_MANUAL)
		assert_true(ObjectRecord.is_uuid(r.object_id))
	assert_eq(ids.size(), 200, "unique ids")
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
	assert_near(s.gpu_p50_ms, 2.0, 1e-9)
	assert_near(s.cpu_p95_ms, 5.0, 1e-9)
	assert_near(BenchPlan.summarize(PackedFloat64Array(), PackedFloat64Array(), PackedFloat64Array()).frame_max_ms, 0.0, 0.0)
