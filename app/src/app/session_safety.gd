class_name SessionSafety
extends RefCounted
## Resource-safety state of the session (spec §18.1, MEMORY-04). Polls RenderPlatformTelemetry at 1 Hz and
## derives safety_state: "normal"; "warning" (thermal serious: shown, nothing stops); "restricted" (a memory
## warning within the last 60 s, thermal critical, or an over_budget rejection of a critical cache request).
## Entering restricted stops optional work only: Texture Preview is suspended and stays off, queued
## speculative requests are cancelled and the cache is trimmed. The selected profile, the document and the
## history are never touched. `clock_msec` (tests) replaces the real clock so recovery windows need no waiting.

const NORMAL := "normal"
const WARNING := "warning"
const RESTRICTED := "restricted"
const SAMPLE_MSEC := 1000
const RESTRICT_WINDOW_MSEC := 60000
const THERMAL_SERIOUS := 2
const THERMAL_CRITICAL := 3
const SPECULATIVE_PRIORITY := 2
const TRIM_FRACTION := 0.5
const PREVIEW_REFUSED := "Texture Preview is unavailable while resources are restricted."

var telemetry := RenderPlatformTelemetry.new()
var clock_msec := Callable()

var _render: SessionRender
var _session: EditorSession
var _state := NORMAL
var _reason := ""
var _sample: Dictionary = {}
var _sample_msec := -1
var _trigger_msec := -1
var _rejections_seen := 0
var _interventions := 0


func _init(session: EditorSession, render: SessionRender) -> void:
	_session = session
	_render = render


func state() -> String:
	return _state


func is_restricted() -> bool:
	return _state == RESTRICTED


func interventions() -> int:
	return _interventions


## Latest telemetry sample (empty before the first tick). Benchmarks read this instead of calling
## telemetry.sample() themselves, which would consume memory warnings.
func last_sample() -> Dictionary:
	return _sample.duplicate()


## First call samples immediately (registers the platform observer); later calls at most once per second.
func tick() -> void:
	var now_msec := int(clock_msec.call()) if clock_msec.is_valid() else Time.get_ticks_msec()
	if _sample_msec >= 0 and now_msec - _sample_msec < SAMPLE_MSEC:
		return
	_sample_msec = now_msec
	_sample = telemetry.sample()
	var cause := _trigger_cause()
	if cause != "":
		_trigger_msec = now_msec
		_intervene(cause)
	_update_state(now_msec)


func status() -> Dictionary:
	var thermal := str(_sample.get("thermal", "unavailable"))
	return {"safety_state": _state, "safety_reason": _reason, "thermal": thermal,
		"footprint_mib": _sample.get("footprint_mib")}


func _trigger_cause() -> String:
	var cause := ""
	if int(_sample.get("thermal_level", -1)) >= THERMAL_CRITICAL:
		cause = "thermal critical"
	var rejected := int(_render.cache.stats().critical_over_budget)
	if rejected > _rejections_seen:
		cause = "cache over budget"
	_rejections_seen = rejected
	if int(_sample.get("memory_warnings", 0)) > 0:
		cause = "memory warning"
	return cause


func _update_state(now_msec: int) -> void:
	if _state == RESTRICTED and now_msec - _trigger_msec < RESTRICT_WINDOW_MSEC:
		return
	var serious := int(_sample.get("thermal_level", -1)) >= THERMAL_SERIOUS
	var next := WARNING if serious else NORMAL
	_reason = "thermal serious" if serious else ""
	if next != _state:
		_state = next
		_session.status_changed.emit()


func _intervene(cause: String) -> void:
	var entering := _state != RESTRICTED
	_state = RESTRICTED
	_reason = cause
	_interventions += 1
	_render.suspend_texture_preview(cause)
	_render.cache.cancel_queued(SPECULATIVE_PRIORITY)
	_render.cache.trim(int(float(_render.cache.stats().soft_bytes) * TRIM_FRACTION))
	if entering:
		_session.post_message("Resource safety: %s — preview stopped, caches trimmed" % cause)
	_session.status_changed.emit()
