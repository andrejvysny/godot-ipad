extends TestCase
## RenderBench runs headless against a scratch storage root, writes its JSON report and leaves the
## session exactly as it found it on every exit path (spec §19.3, §21.2 BENCH-01..BENCH-05).

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const TIMEOUT_MSEC := 240000
const USER_OBJECTS := 3

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


## A session whose own world holds USER_OBJECTS objects, one of them selected, with non-default
## render settings so that restoration is observable.
func _boot() -> void:
	session = EditorSession.new()
	session.storage_root = scratch_dir() + "/worlds"
	session.provider_override = ScriptedInputProvider.new()
	session.build_ui = false
	tree.root.add_child(session)
	await tree.process_frame
	for rec in BenchPlan.synth_objects(session.document, session.catalog, USER_OBJECTS, 99):
		session.document.put_object(rec)
	session.presenter.rebuild(session.document)
	session.tools.select(session.document.sorted_object_ids()[0])
	session.sun.shadow_enabled = true
	session.sun.directional_shadow_max_distance = 77.0
	session.get_viewport().scaling_3d_scale = 0.8
	session.terrain.set_render_probe(true, false)


func _make_bench(output: String = "/out") -> RenderBench:
	var bench := RenderBench.new()
	bench.output_dir = scratch_dir() + output
	bench.warmup_frames = 2
	bench.measure_frames = 3
	bench.counts = PackedInt32Array([0, 10])
	session.add_child(bench)
	return bench


func _state() -> Dictionary:
	var viewport := session.get_viewport()
	return {"shadows": session.sun.shadow_enabled, "mode": session.sun.directional_shadow_mode,
		"distance": session.sun.directional_shadow_max_distance, "scale": viewport.scaling_3d_scale,
		"scaling_mode": viewport.scaling_3d_mode, "msaa": viewport.msaa_3d,
		"probe": session.terrain.get_render_probe(), "pose": session.rig.controller.get_pose(),
		"selected": session.tools.selected_id(), "presenter": session.presenter.authored_object_count(),
		"hash": session.authored_hash(), "revision": session.document.document_revision,
		"history": session.history.size(), "mesh_config": session.terrain.mesh_config()}


func _wait_until(cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return cond.call()


func _assert_clean(bench: Variant, before: Dictionary) -> void:
	await tree.process_frame
	await tree.process_frame
	assert_eq(_state(), before, "session state restored")
	assert_false(session.bench_active(), "guard released")
	assert_false(is_instance_valid(bench) and bench.is_inside_tree(), "runner left the tree")


func test_bench_writes_report_and_restores_session() -> void:
	await _boot()
	var before := _state()
	var bench := _make_bench()
	var done := [false]
	bench.finished.connect(func(_report: Dictionary) -> void: done[0] = true)
	assert_false(session.bench_active())
	assert_empty_string(bench.start(session))
	assert_true(session.bench_active(), "bench_active during the run")
	assert_error_contains(bench.start(session), "already running")
	var second := _make_bench("/out2")
	assert_error_contains(second.start(session), "already running")
	second.queue_free()
	if not assert_true(await _wait_until(func() -> bool: return done[0]), "bench did not finish"):
		return
	_check_report(bench)
	await _assert_clean(bench, before)


func _check_report(bench: RenderBench) -> void:
	var files := DirAccess.get_files_at(scratch_dir() + "/out")
	if not assert_eq(files.size(), 1, "one report file"):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(scratch_dir() + "/out/" + files[0]))
	if not assert_true(typeof(parsed) == TYPE_DICTIONARY, "report parses"):
		return
	assert_eq(parsed.status, "COMPLETED")
	assert_eq(parsed.abort_reason, null)
	assert_eq(parsed.evidence.acceptance, "NOT_ACCEPTANCE_RUN")
	assert_eq(parsed.evidence.platform_class, "HEADLESS")
	assert_false(parsed.has("evidence_class"))
	assert_true(parsed.fingerprints.has("source_sha256") and parsed.fingerprints.has("config_sha256"))
	assert_eq(str(parsed.fingerprints.catalog_sha256), session.catalog.sha256)
	var c: Dictionary = parsed.correctness  # BENCH-05
	assert_eq(c.authored_hash_before, c.authored_hash_after)
	assert_eq([c.revision_before, c.history_size_before], [c.revision_after, c.history_size_after])
	assert_true(c.restored)
	var steps: Array = parsed.steps
	assert_eq(steps.size(), 2 * 5 * 2 + 2 + 1)
	assert_eq(steps.size(), bench.report.steps.size())
	for step: Dictionary in steps:
		assert_true(int(step.summary.frames) == 3 and step.has("counters_peak") and step.has("prepare_ms"), str(step.id))
		for key in ["batches", "instances", "estimated_triangles", "full_uploads", "partial_uploads", "overview"]:
			assert_true((step.render as Dictionary).has(key), "step %s carries render.%s" % [str(step.id), key])
		assert_true((step.render.overview as Dictionary).has("proxy_triangles"), "overview stats in the step")
		assert_eq(int(step.objects_presented), int(step.count), "exact population " + str(step.id))  # BENCH-02
		assert_eq(step.population.fixture, "gentle_hills")  # JSON numbers parse as float
		assert_eq([int(step.population.objects), int(step.population.scatter_instances), int(step.population.paths)],
				[int(step.count), 0, 0])
		assert_true(step.has("first_frame_ms") and step.has("settle_ms") and step.settled, str(step.id))
		assert_eq(step.summary.gpu_status, "UNSUPPORTED", "BENCH-04")
		assert_eq([step.summary.gpu_p50_ms, step.summary.gpu_p95_ms, step.summary.gpu_p99_ms], [null, null, null])
		assert_eq(int(step.summary.gpu_samples), 0)
		assert_eq(step.summary.frame_interval_source, "wall_clock_proxy")
	assert_eq(steps[0].workload, "terrain_only")
	assert_eq(steps[10].workload, "primitive")


func test_population_ignores_user_world_and_input_is_isolated() -> void:
	await _boot()
	session.set_vegetation_hidden(true)
	var before := _state()
	var bench := _make_bench()
	var seen := {"counts": [], "ids": []}
	bench.finished.connect(func(r: Dictionary) -> void: seen.counts = r.steps.map(func(s: Dictionary) -> int: return s.objects_presented))
	assert_empty_string(bench.start(session))
	await tree.process_frame
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.PENCIL
	sample.phase = PointerSample.Phase.BEGIN
	sample.position_viewport = session.get_viewport().get_visible_rect().size * 0.5
	session.input.tool_action.emit({"type": "tool_begin", "sample": sample})
	assert_false(session.tools.has_active_operation(), "tool action dropped while the bench runs")
	assert_eq(session.undo(), EditorSession.BENCH_MESSAGE)
	assert_eq(session.redo(), EditorSession.BENCH_MESSAGE)
	assert_eq(session.save_now(), EditorSession.BENCH_MESSAGE)
	assert_eq(session.export_world().error, EditorSession.BENCH_MESSAGE)
	assert_eq(session.open_fixture("flat"), EditorSession.BENCH_MESSAGE)
	assert_eq(str(session.request_profile("detailed").status), SessionRender.BLOCKED)
	assert_false(session.vegetation_hidden(), "bench measures with vegetation visible")
	assert_eq(Engine.max_fps, 0)
	assert_true(session.last_message_is_error)
	assert_eq(session.authored_hash(), before.hash)
	assert_true(await _wait_until(func() -> bool: return not session.bench_active()), "bench did not finish")
	assert_eq(seen.counts.size(), 23)
	assert_true(seen.counts.all(func(n: int) -> bool: return n == 0 or n == 10), "exact counts, not user objects + N")
	await _assert_clean(bench, before)
	assert_true(session.vegetation_hidden(), "vegetation hiding restored")
	assert_eq(session.render_profiles.active_name(), "performance")
	session.input.tool_action.emit({"type": "tool_begin", "sample": sample})
	assert_true(session.tools.has_active_operation(), "control: the same action works after the bench")
	session.tools.cancel_active("explicit")


func test_abort_restores_and_writes_partial_report() -> void:
	await _boot()
	var before := _state()
	var bench := _make_bench()
	var got := []
	bench.aborted.connect(func(reason: String, r: Dictionary) -> void: got.append([reason, r.status, r.steps.size()]))
	assert_empty_string(bench.start(session))
	await tree.process_frame
	await tree.process_frame
	session.abort_render_bench("user_abort")
	assert_false(session.bench_active())
	assert_eq(got.size(), 1)
	assert_eq(got[0][0], "user_abort")
	assert_eq(got[0][1], "ABORTED")
	assert_eq(DirAccess.get_files_at(scratch_dir() + "/out").size(), 1, "partial report written")
	assert_eq(bench.report.abort_reason, "user_abort")
	assert_true(bench.report.correctness.restored)
	await _assert_clean(bench, before)


func test_input_contact_aborts_the_run() -> void:
	await _boot()
	var before := _state()
	var bench := _make_bench()
	var got := []
	bench.aborted.connect(func(reason: String, _r: Dictionary) -> void: got.append(reason))
	assert_empty_string(bench.start(session))
	await tree.process_frame
	(session.input.active_provider() as ScriptedInputProvider).push(PointerSample.Source.PENCIL, 7,
			PointerSample.Phase.BEGIN, Vector2(100, 100))
	assert_true(await _wait_until(func() -> bool: return not got.is_empty()), "abort after contact")
	assert_eq(got, ["input_disturbance"])
	(session.input.active_provider() as ScriptedInputProvider).cancel_all("explicit")
	await tree.process_frame
	session.tools.cancel_active("explicit")
	session.input.cancel_all("explicit")
	await tree.process_frame
	before.pose = session.rig.controller.get_pose()
	await _assert_clean(bench, before)


func test_freeing_the_runner_restores_the_session() -> void:
	await _boot()
	var before := _state()
	var bench := _make_bench()
	assert_empty_string(bench.start(session))
	await tree.process_frame
	await tree.process_frame
	session.remove_child(bench)
	bench.free()
	assert_false(session.bench_active())
	await _assert_clean(bench, before)


func test_focus_out_aborts_the_run() -> void:
	await _boot()
	var before := _state()
	var bench := _make_bench()
	var reasons := []
	bench.aborted.connect(func(reason: String, _r: Dictionary) -> void: reasons.append(reason))
	assert_empty_string(bench.start(session))
	await tree.process_frame
	await tree.process_frame
	session._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_eq(reasons, ["app_deactivated"])
	await _assert_clean(bench, before)


func test_report_write_failure_still_restores() -> void:
	await _boot()
	var before := _state()
	var blocker := scratch_dir() + "/blocker"
	var file := FileAccess.open(blocker, FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var bench := _make_bench("/blocker/below")
	var done := [false]
	bench.finished.connect(func(_r: Dictionary) -> void: done[0] = true)
	assert_empty_string(bench.start(session))
	assert_true(await _wait_until(func() -> bool: return done[0]), "bench did not finish")
	assert_ne(bench.write_error, "")
	assert_true(session.last_message_is_error)
	assert_string_contains_safe(session.last_message, "could not be written")
	await _assert_clean(bench, before)


func test_world_replacement_aborts_the_run() -> void:
	await _boot()
	var bench := _make_bench()
	var reasons := []
	bench.aborted.connect(func(reason: String, _r: Dictionary) -> void: reasons.append(reason))
	assert_empty_string(bench.start(session))
	await tree.process_frame
	session._replace_document(SessionWorldOps.load_fixture("flat", session.catalog)[0])
	assert_eq(reasons, ["world_replaced"])
	assert_true(bench.report.correctness.restored)
	assert_false(session.bench_active())
	assert_eq(session.presenter.authored_object_count(), session.document.objects.size())


func assert_string_contains_safe(text: String, needle: String) -> bool:
	return assert_true(text.contains(needle), "'%s' contains '%s'" % [text, needle])
