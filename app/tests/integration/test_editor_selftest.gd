extends TestCase
## The in-app self-test (spec §21.1 sequence, SYNTHETIC input) runs headless against a scratch
## storage root and must report PASS for every step S01-S11. Screenshots are skipped headless.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const TIMEOUT_MSEC := 240000

var session: EditorSession
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	# The pinned Terrain3D binary emits one known deprecation warning when it enters the tree.
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


func test_scripted_scenario_passes() -> void:
	session = EditorSession.new()
	session.storage_root = scratch_dir() + "/worlds"
	session.provider_override = ScriptedInputProvider.new()
	session.build_ui = false
	tree.root.add_child(session)
	await tree.process_frame
	var runner := EditorSelfTest.new()
	runner.output_dir = scratch_dir() + "/out"
	session.add_child(runner)
	var done := [false]
	runner.finished.connect(func(_report: Dictionary) -> void: done[0] = true)
	runner.start(session)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not done[0] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not assert_true(done[0], "self-test did not finish"):
		return
	var failed: Array = []
	var seen := {}
	for entry: Dictionary in runner.report.steps:
		seen[entry.id] = true
		if entry.result != "PASS":
			failed.append("%s %s %s" % [entry.id, entry.title, JSON.stringify(entry.details)])
	for n in range(1, 12):
		assert_true(seen.has("S%02d" % n), "missing step S%02d" % n)
	assert_true(failed.is_empty(), "failed checks: " + "\n".join(failed))
	assert_eq(runner.report.result, "PASS", "overall result")
	assert_true(FileAccess.file_exists(scratch_dir() + "/out/report.json"), "report.json written")
