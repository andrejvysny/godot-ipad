extends TestCase
## Scenario and sustained RenderBench runs headless (spec §19.3, §20, §21.2 BENCH-02/03/05): short windows, the
## bench catalog attached for the run and the editor's attachment, profile, selection, camera and document
## restored afterwards, the user's document and history untouched.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const TIMEOUT_MSEC := 240000
const SMALL := {"objects": 120, "scatter": 150, "preview_cycles": 2}

var session: EditorSession
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	if is_instance_valid(session):
		if session.get_parent() != null:
			tree.root.remove_child(session)
		session.free()
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


## The user's profile is Balanced, three objects exist and one is selected.
func _boot() -> void:
	session = EditorSession.new()
	session.storage_root = scratch_dir() + "/worlds"
	session.provider_override = ScriptedInputProvider.new()
	session.build_ui = false
	tree.root.add_child(session)
	await tree.process_frame
	for rec in BenchPlan.synth_objects(session.document, session.catalog, 3, 99):
		session.document.put_object(rec)
	session.presenter.rebuild(session.document)
	session.tools.select(session.document.sorted_object_ids()[0])
	session.request_profile("balanced")
	session.sun.directional_shadow_max_distance = 77.0


func _make(scenarios: Array[String], profiles: Array[String], kinds: Array[String]) -> RenderBench:
	var bench := RenderBench.new()
	bench.output_dir = scratch_dir() + "/out"
	bench.scenarios = scenarios
	bench.scenario_profiles = profiles
	bench.scenario_kinds = kinds
	bench.measure_seconds = 0.2
	bench.warmup_seconds = 0.1
	bench.world_overrides = SMALL
	session.add_child(bench)
	return bench


func _state() -> Dictionary:
	var viewport := session.get_viewport()
	return {"shadows": session.sun.shadow_enabled, "distance": session.sun.directional_shadow_max_distance,
		"scale": viewport.scaling_3d_scale, "probe": session.terrain.get_render_probe(),
		"pose": session.rig.controller.get_pose(), "selected": session.tools.selected_id(),
		"presenter": session.presenter.authored_object_count(), "hash": session.authored_hash(),
		"revision": session.document.document_revision, "history": session.history.size(),
		"profile": session.render_profiles.active_name(), "max_fps": Engine.max_fps,
		"attach": BenchAttach.state(session), "preview": session.texture_preview_status().state in [
		TexturePreviewController.OFF, TexturePreviewController.RELEASING], "vegetation": session.vegetation_hidden(),
		"objects": session.document.objects.size(), "mesh_config": session.terrain.mesh_config()}


func _wait_until(cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return cond.call()


func _run_to_end(bench: RenderBench) -> Dictionary:
	var done := [false]
	bench.finished.connect(func(_r: Dictionary) -> void: done[0] = true)
	bench.aborted.connect(func(_reason: String, _r: Dictionary) -> void: done[0] = true)
	assert_empty_string(bench.start(session))
	if not assert_true(await _wait_until(func() -> bool: return done[0]), "bench did not finish"):
		return {}
	return bench.report


func _assert_restored(before: Dictionary) -> void:
	await tree.process_frame
	await tree.process_frame
	assert_eq(_state(), before, "session state restored")
	assert_false(session.bench_active())
	assert_eq(session.presenter.render_world().get_parent(), session.presenter, "one render world")


func test_scenario_run_reports_populations_and_restores_everything() -> void:
	await _boot()
	var before := _state()
	assert_eq(before.profile, "balanced")
	assert_eq(before.attach.presenter_catalog, "poc_nature")
	var bench := _make(["terrain_only_legacy", "geometry_forest_10k"], ["performance", "detailed"], ["focus", "edit_sculpt"])
	var report := await _run_to_end(bench)
	if report.is_empty():
		return
	assert_eq(report.status, "COMPLETED")
	assert_eq(report.evidence_class, "HEADLESS")
	assert_eq(report.evidence.acceptance, "NOT_ACCEPTANCE_RUN")
	assert_true(report.not_run.has("asset_diversity"))
	assert_eq(report.idle_pacing, "never_enabled")
	var c: Dictionary = report.correctness  # BENCH-05
	assert_eq(c.authored_hash_before, c.authored_hash_after)
	assert_eq([c.revision_before, c.history_size_before], [c.revision_after, c.history_size_after])
	assert_true(c.restored)
	var steps: Array = report.steps
	assert_eq(steps.size(), 2 * 2 * 2 + 1, "scenarios x profiles x kinds + repeat")
	for step: Dictionary in steps:
		_check_step(step)
	var forest: Dictionary = steps[4]
	assert_eq(forest.scenario, "geometry_forest_10k")
	assert_eq(int(forest.population.authored_meaningful), 120, "exact population")  # BENCH-02
	assert_eq(int(forest.population.presented), 120, "presented from the bench document, not the user's")
	assert_eq(int(forest.population.decorative), 0)
	assert_eq(forest.population.by_asset, {"bench.tree.broadleaf_geo": 120})
	assert_true(report.populations.has("geometry_forest_10k") and report.populations.has("terrain_only_legacy"))
	assert_true(forest.has("render_stats") and forest.has("cache") and forest.has("telemetry"))
	assert_eq(forest.camera_poses.path, "focus")
	var sculpt: Dictionary = steps[1]
	assert_eq(sculpt.workload, "edit_sculpt")
	assert_true(int(sculpt.workload_result.strokes) >= 1)
	assert_true(sculpt.workload_result.has("terrain_latency"))
	assert_eq(steps[0].profile, "performance")
	assert_eq(steps[2].profile, "detailed")
	assert_eq(steps[2].target_fps, 30.0)
	assert_near(steps[2].target_budget_ms, 1000.0 / 30.0, 1e-6)
	assert_eq(steps[0].target_fps, 60.0)
	assert_true(steps[steps.size() - 1].repeat)
	await _assert_restored(before)
	assert_eq(session.render_profiles.active_name(), "balanced", "the user's profile is back")


func _check_step(step: Dictionary) -> void:
	var s: Dictionary = step.summary
	assert_true(int(s.frames) > 0 and s.has("frame_p99_ms") and s.has("missed_target") and s.has("hitches_over_50_ms"), str(step.id))
	assert_eq(s.gpu_status, "UNSUPPORTED", "BENCH-04")
	assert_eq([s.gpu_p50_ms, s.gpu_p95_ms, s.gpu_p99_ms], [null, null, null])
	assert_true(step.has("settled") and step.has("prepare_ms") and step.has("counters_peak"), str(step.id))
	assert_true(step.telemetry.has("start") and step.telemetry.has("end"))
	assert_eq(step.telemetry.start.safety_state, "normal")
	assert_eq(step.cache.errors, 0)
	assert_true(step.population.has("presented") and step.population.has("authored_meaningful"))


func test_terrain_mesh_ablations_apply_per_step_and_restore() -> void:
	await _boot()
	var before := _state()
	var original: Dictionary = before.mesh_config
	var bench := _make(["terrain_only_legacy"], ["terrain_mesh_24", "terrain_mesh_32", "performance"], ["focus"])
	var report := await _run_to_end(bench)
	if report.is_empty():
		return
	var steps: Array = report.steps
	assert_eq(steps.size(), 3 + 1)
	if not original.is_empty():
		assert_eq(steps[0].terrain_mesh, {"mesh_size": 24, "lods": original.lods})
		assert_eq(steps[1].terrain_mesh, {"mesh_size": 32, "lods": original.lods})
		assert_eq(steps[2].terrain_mesh, original, "a real profile step returns to the original config")
	assert_true(report.correctness.restored)
	await _assert_restored(before)


func test_edit_workloads_and_preview_cycles_leave_the_user_document_alone() -> void:
	await _boot()
	var before := _state()
	var bench := _make(["mixed_world_10k"], ["performance"], ["edit_move", "preview_cycles"])
	var report := await _run_to_end(bench)
	if report.is_empty():
		return
	var move: Dictionary = report.steps[0]
	assert_eq(move.workload, "edit_move")
	assert_true(int(move.workload_result.moves) > 0)
	assert_ne(move.workload_result.object_id, "")
	var preview: Dictionary = report.steps[1]
	var result: Dictionary = preview.workload_result
	assert_eq(int(result.cycles_requested), 2)
	assert_eq(int(result.cycles_done), 2, str(result))
	assert_true(result.completed)
	for cycle: Dictionary in result.cycles:
		assert_true(cycle.has("before") and cycle.has("after") and cycle.has("state_reached"), str(cycle))
		assert_true(cycle.before.has("resident_bytes") and cycle.after.has("preview_bytes"))
	assert_eq(report.correctness.authored_hash_before, report.correctness.authored_hash_after)
	await _assert_restored(before)


func test_sustained_mode_is_bounded_and_restores() -> void:
	await _boot()
	var before := _state()
	var bench := RenderBench.new()
	bench.output_dir = scratch_dir() + "/out"
	bench.sustained_minutes = 0.05
	bench.measure_seconds = 1.0
	bench.warmup_seconds = 0.0
	bench.world_overrides = SMALL
	session.add_child(bench)
	var report := await _run_to_end(bench)
	if report.is_empty():
		return
	assert_eq(report.status, "COMPLETED")
	var s: Dictionary = report.sustained
	assert_eq(s.scenario, "mixed_world_10k")
	assert_eq(s.profile, "performance")
	assert_true(s.completed)
	assert_true((s.minutes as Array).size() >= 1 and (s.minutes as Array).size() <= 2, str(s.minutes.size()))
	assert_true(float(s.elapsed_s) >= 2.9 and float(s.elapsed_s) < 15.0)
	var minute: Dictionary = s.minutes[0]
	for key in ["frames", "frame_p50_ms", "frame_p95_ms", "frame_p99_ms", "hitches_over_50_ms", "missed_target",
			"gpu_status", "thermal", "footprint_mib", "cache_resident_bytes", "nodes"]:
		assert_true(minute.has(key), key)
	assert_true(int(minute.frames) > 0)
	assert_eq(report.steps.size(), 0, "no per-frame or per-step arrays in sustained mode")
	await _assert_restored(before)


func test_abort_restores_the_editor_attachment() -> void:
	await _boot()
	var before := _state()
	var bench := _make(["geometry_forest_10k"], ["performance"], ["focus"])
	var got := []
	bench.aborted.connect(func(reason: String, r: Dictionary) -> void: got.append([reason, r.status]))
	assert_empty_string(bench.start(session))
	assert_true(await _wait_until(func() -> bool: return BenchAttach.state(session).presenter_catalog == "bench_nature"), "bench catalog attached")
	assert_eq(BenchAttach.state(session).scatter_catalog, "bench_nature")
	session.abort_render_bench("user_abort")
	assert_eq(got, [["user_abort", "ABORTED"]])
	assert_true(bench.report.correctness.restored)
	await _assert_restored(before)


func test_world_replacement_during_a_scenario_run_restores_the_attachment() -> void:
	await _boot()
	var bench := _make(["geometry_forest_10k"], ["performance"], ["focus"])
	var reasons := []
	bench.aborted.connect(func(reason: String, _r: Dictionary) -> void: reasons.append(reason))
	assert_empty_string(bench.start(session))
	assert_true(await _wait_until(func() -> bool: return BenchAttach.state(session).presenter_catalog == "bench_nature"))
	session._replace_document(SessionWorldOps.load_fixture("flat", session.catalog)[0])
	assert_eq(reasons, ["world_replaced"])
	assert_eq(BenchAttach.state(session).presenter_catalog, "poc_nature")
	assert_eq(BenchAttach.state(session).scatter_catalog, "poc_nature")
	assert_true(BenchAttach.state(session).presenter_cache_shared)
	assert_eq(session.presenter.authored_object_count(), session.document.objects.size())
	assert_false(session.bench_active())


func test_unknown_scenarios_are_skipped_and_reported() -> void:
	await _boot()
	var before := _state()
	var bench := _make(["asset_diversity", "terrain_only_legacy"], ["performance"], ["overview"])
	var report := await _run_to_end(bench)
	if report.is_empty():
		return
	assert_eq(report.steps.size(), 2, "only the runnable scenario (plus the repeat)")
	assert_true(report.not_run.has("asset_diversity"))
	await _assert_restored(before)
