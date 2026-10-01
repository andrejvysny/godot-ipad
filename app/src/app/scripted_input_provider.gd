class_name ScriptedInputProvider
extends InputProvider
## Queue-driven provider for the in-app self-test. Everything it emits is SYNTHETIC: it never
## claims Pencil identity (editing contacts are MOUSE_DEV) and never satisfies a device gate.
## Positions are root-viewport coordinates; timestamps use the provider clock at push time.

var cancel_events := 0  ## cancel_all() calls, so a scenario can tell a stall cancel from a normal end
var last_cancel_reason := ""

var _queue: Array[PointerSample] = []
var _open: Dictionary = {}  # contact id -> source
var _ignored: Dictionary = {}  # contacts cancelled by cancel_all, silent until they end
var _sequence := 0


func provider_name() -> String:
	return "selftest_script"


func label() -> String:
	return "SYNTHETIC SELF-TEST INPUT"


func is_development() -> bool:
	return true


func is_available() -> bool:
	return true


func capabilities() -> Dictionary:
	return {"source_identity": false, "pressure": false, "tilt": false, "coalesced": false,
		"native_cancel": false, "native_timestamps": false}


func coordinate_space() -> String:
	return SPACE_VIEWPORT


func drain_samples() -> Array[PointerSample]:
	var out := _queue
	_queue = []
	return out


func push(source: int, id: int, phase: int, viewport_pos: Vector2, pressure_valid := false,
		pressure := 0.0, reason := "") -> void:
	if _ignored.has(id):
		if phase == PointerSample.Phase.END or phase == PointerSample.Phase.CANCEL:
			_ignored.erase(id)
		return
	var s := PointerSample.new()
	s.source = source
	s.pointer_id = id
	s.phase = phase
	s.position_raw = viewport_pos
	s.pressure_valid = pressure_valid
	s.pressure = pressure
	s.cancel_reason = reason
	s.timestamp_s = now_seconds()
	_sequence += 1
	s.sample_sequence = _sequence
	if phase == PointerSample.Phase.END or phase == PointerSample.Phase.CANCEL:
		_open.erase(id)
	else:
		_open[id] = source
	_queue.append(s)


func cancel_all(reason: String) -> void:
	cancel_events += 1
	last_cancel_reason = reason
	var kept: Array[PointerSample] = []
	for s in _queue:
		if not _open.has(s.pointer_id):
			kept.append(s)
	_queue = kept
	for id: int in _open:
		var s := PointerSample.new()
		s.source = _open[id]
		s.pointer_id = id
		s.phase = PointerSample.Phase.CANCEL
		s.cancel_reason = reason if reason in InputRouter.CANCEL_REASONS else "explicit"
		s.timestamp_s = now_seconds()
		_sequence += 1
		s.sample_sequence = _sequence
		_queue.append(s)
		_ignored[id] = true
	_open.clear()


func diagnostics() -> Dictionary:
	return {"synthetic": true, "cancel_events": cancel_events, "last_cancel_reason": last_cancel_reason}
