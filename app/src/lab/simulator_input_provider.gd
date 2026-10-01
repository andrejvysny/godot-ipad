class_name SimulatorInputProvider
extends IOSNativeInputProvider
## Simulator touches can exercise tools, but never establish Pencil identity or G1.

var pencil_mode := true
var _development_samples: Array[PointerSample] = []
var _development_id := 1000000


static func simulator_available() -> bool:
	if OS.get_name() != "iOS" or not Engine.has_singleton(SINGLETON_NAME):
		return false
	var bridge := Engine.get_singleton(SINGLETON_NAME)
	var caps: Dictionary = bridge.call("get_capabilities")
	return caps.get("platform", "") == "ios_simulator"


func is_development() -> bool:
	return true


func provider_name() -> String:
	return "ios_simulator_development"


func label() -> String:
	return "SIMULATOR DEVELOPMENT — %s (P toggles; arrows orbit)" % ("probe/UI" if pencil_mode else "finger navigation")


func drain_samples() -> Array[PointerSample]:
	var samples := super.drain_samples()
	if pencil_mode and simulator_available():
		for sample in samples:
			if sample.source == PointerSample.Source.FINGER:
				sample.source = PointerSample.Source.MOUSE_DEV
	samples.append_array(_development_samples)
	_development_samples.clear()
	return samples


func queue_camera_drag(start: Vector2, end: Vector2) -> void:
	if not simulator_available():
		return
	_development_id += 1
	var positions := [start, start.lerp(end, 0.5), end, end]
	for index in 4:
		var sample := PointerSample.new()
		sample.source = PointerSample.Source.FINGER
		sample.pointer_id = _development_id
		sample.phase = [PointerSample.Phase.BEGIN, PointerSample.Phase.MOVE,
			PointerSample.Phase.MOVE, PointerSample.Phase.END][index]
		sample.position_raw = positions[index]
		sample.timestamp_s = now_seconds() + index * 0.000001
		_development_samples.append(sample)


func cancel_all(reason: String) -> void:
	_development_samples.clear()
	super.cancel_all(reason)


func diagnostics() -> Dictionary:
	var details := super.diagnostics()
	details["development_input"] = true
	details["simulated_pencil"] = pencil_mode
	details["keyboard_gestures_are_synthetic"] = true
	return details
