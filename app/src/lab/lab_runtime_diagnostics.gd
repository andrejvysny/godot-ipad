class_name LabRuntimeDiagnostics
extends RefCounted
## Wall-clock frames expose GPU waits that Godot's capped process delta can hide.

const UI_INTERVAL_US := 250000
const REPORT_INTERVAL_US := 2000000
const REPORT_PATH := "user://input_lab_runtime.json"

var frames := FrameStats.new(600)
var frame_count := 0
var last_interval_s := 0.0
var capture_enabled := false
var _previous_us := -1
var _next_ui_us := 0
var _next_report_us := 0


func record_frame(now_us: int) -> bool:
	if _previous_us >= 0:
		last_interval_s = maxf(0.0, float(now_us - _previous_us) / 1000000.0)
		frames.add(last_interval_s * 1000.0)
	_previous_us = now_us
	frame_count += 1
	if now_us < _next_ui_us:
		return false
	_next_ui_us = now_us + UI_INTERVAL_US
	return true


func snapshot() -> Dictionary:
	var result := frames.snapshot()
	result["frame_count"] = frame_count
	result["last_interval_ms"] = last_interval_s * 1000.0
	result["clock"] = "monotonic wall time"
	return result


func write_if_due(now_us: int, read_state: Callable) -> void:
	if not capture_enabled or now_us < _next_report_us:
		return
	_next_report_us = now_us + REPORT_INTERVAL_US
	var report: Dictionary = read_state.call()
	report["timing"] = snapshot()
	report["uptime_ms"] = now_us / 1000
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))


func capture_frame(viewport: Viewport) -> void:
	if not capture_enabled or DisplayServer.get_name() == "headless":
		return
	await viewport.get_tree().create_timer(5.0).timeout
	await RenderingServer.frame_post_draw
	var rendered := viewport.get_texture().get_image()
	if rendered != null:
		rendered.save_png("user://input_lab_frame.png")
