extends TestCase
## RenderBench runs headless against a scratch storage root, writes its JSON report and leaves the
## session exactly as it found it (document, history, presenter, light, render scale, camera).

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const TIMEOUT_MSEC := 240000

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


func test_bench_writes_report_and_restores_session() -> void:
	session = EditorSession.new()
	session.storage_root = scratch_dir() + "/worlds"
	session.provider_override = ScriptedInputProvider.new()
	session.build_ui = false
	tree.root.add_child(session)
	await tree.process_frame
	var objects_before := session.presenter.object_count()
	var hash_before := session.authored_hash()
	var history_before := session.history.size()
	var scale_before := session.get_viewport().scaling_3d_scale
	var pose_before := session.rig.controller.get_pose()
	var sun_before := [session.sun.shadow_enabled, session.sun.directional_shadow_mode,
		session.sun.directional_shadow_max_distance]
	var bench := RenderBench.new()
	bench.output_dir = scratch_dir() + "/out"
	bench.warmup_frames = 3
	bench.measure_frames = 5
	bench.counts = PackedInt32Array([0, 10])
	session.add_child(bench)
	var done := [false]
	bench.finished.connect(func(_report: Dictionary) -> void: done[0] = true)
	assert_empty_string(bench.start(session))
	assert_error_contains(bench.start(session), "already running")
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not done[0] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not assert_true(done[0], "bench did not finish"):
		return
	_check_report(bench)
	assert_eq(session.presenter.object_count(), objects_before)
	assert_eq(session.get_viewport().scaling_3d_scale, scale_before)
	assert_eq([session.sun.shadow_enabled, session.sun.directional_shadow_mode,
		session.sun.directional_shadow_max_distance], sun_before)
	assert_eq(session.rig.controller.get_pose(), pose_before)
	assert_eq(CanonicalEncoder.authored_hash(session.document), hash_before)
	assert_eq(session.history.size(), history_before)


func _check_report(bench: RenderBench) -> void:
	var files := DirAccess.get_files_at(scratch_dir() + "/out")
	if not assert_eq(files.size(), 1, "one report file"):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(scratch_dir() + "/out/" + files[0]))
	if not assert_true(typeof(parsed) == TYPE_DICTIONARY, "report parses"):
		return
	var steps: Array = parsed.steps
	assert_eq(steps.size(), 2 * 5 * 2 + 2 + 1)
	assert_eq(steps.size(), bench.report.steps.size())
	for step: Dictionary in steps:
		assert_true(step.has("summary") and int(step.summary.frames) == 5, "summary " + str(step.id))
		assert_true(step.has("counters_peak") and step.has("counters_last") and step.has("rebuild_ms"))
	var base: int = session.document.objects.size()
	assert_eq(int(steps[0].objects_presented), base)
	assert_eq(int(steps[10].objects_presented), base + 10)
