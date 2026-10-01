extends TestCase


func test_wall_clock_stalls_are_measured_without_delta_clamping() -> void:
	var runtime := LabRuntimeDiagnostics.new()
	assert_true(runtime.record_frame(1000000))
	assert_false(runtime.record_frame(1016700))
	assert_true(runtime.record_frame(2016700))
	assert_near(runtime.last_interval_s, 1.0, 0.000001)
	assert_eq(runtime.frame_count, 3)
	assert_eq(runtime.frames.count(), 2)
	assert_near(runtime.frames.max_ms(), 1000.0, 0.000001)
	assert_eq(runtime.frames.count_over(250.0), 1)


func test_diagnostic_refresh_never_catches_up_with_a_burst() -> void:
	var runtime := LabRuntimeDiagnostics.new()
	assert_true(runtime.record_frame(0))
	assert_false(runtime.record_frame(249999))
	assert_true(runtime.record_frame(250000))
	assert_true(runtime.record_frame(5000000))
	assert_false(runtime.record_frame(5000001))
	assert_false(runtime.capture_enabled, "runtime file capture is opt-in")


func test_frame_history_stays_bounded() -> void:
	var runtime := LabRuntimeDiagnostics.new()
	for i in 1000:
		runtime.record_frame(i * 16667)
	assert_eq(runtime.frame_count, 1000)
	assert_eq(runtime.frames.count(), 600)
	assert_eq(runtime.snapshot().frame_count, 1000)


func test_state_snapshot_only_runs_when_capture_is_due() -> void:
	var runtime := LabRuntimeDiagnostics.new()
	var calls := [0]
	var read_state := func() -> Dictionary:
		calls[0] += 1
		return {"driver": "test"}
	runtime.write_if_due(0, read_state)
	assert_eq(calls[0], 0, "disabled capture does no state work")
	runtime.capture_enabled = true
	runtime.write_if_due(0, read_state)
	runtime.write_if_due(1000000, read_state)
	assert_eq(calls[0], 1, "state work is throttled with writes")
	runtime.write_if_due(2000000, read_state)
	assert_eq(calls[0], 2)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(runtime.REPORT_PATH))
	assert_eq(report.driver, "test")
	assert_eq(report.timing.frame_count, 0.0)
	DirAccess.remove_absolute(runtime.REPORT_PATH)
