class_name RenderPlatformTelemetry
extends RefCounted
## Optional platform telemetry (docs/rendering-performance-spec.md §18.2): thermal state, process footprint and
## memory-warning count from the native WPPlatformTelemetry class (native/ios_input/README.md). Unavailable
## metrics are explicit ("unavailable", level -1, footprint null), never zero. Separate from the input bridge.
## Call sample() at low frequency; it is cheap but memory warnings are consumed by each call.

const NATIVE_CLASS := "WPPlatformTelemetry"
const THERMAL_NAMES: Array[String] = ["nominal", "fair", "serious", "critical"]
const MIB := 1048576.0

var _native: RefCounted = null
var _injected_thermal := -1
var _injected_warnings := 0
var _injecting := false


func _init(force_unavailable: bool = false) -> void:
	if force_unavailable or not ClassDB.class_exists(NATIVE_CLASS) or not ClassDB.can_instantiate(NATIVE_CLASS):
		return
	var obj: Variant = ClassDB.instantiate(NATIVE_CLASS)
	if obj is RefCounted and bool(obj.call("is_available")):
		_native = obj


func is_native_available() -> bool:
	return _native != null


## Test injection: the injected thermal level (clamped to 0..3) overrides the native one; injected warnings add to
## the next sample's count. Either sets source "injected".
func inject_thermal(level: int) -> void:
	_injected_thermal = clampi(level, 0, 3)
	_injecting = true


func inject_memory_warning(count: int = 1) -> void:
	_injected_warnings += maxi(count, 0)
	_injecting = true


func clear_injection() -> void:
	_injected_thermal = -1
	_injected_warnings = 0
	_injecting = false


func sample() -> Dictionary:
	var level := -1
	var footprint: Variant = null
	var warnings := 0
	var source := "unavailable"
	if _native != null:
		level = int(_native.call("thermal_state"))
		var bytes := int(_native.call("footprint_bytes"))
		if bytes > 0:
			footprint = float(bytes) / MIB
		warnings = int(_native.call("consume_memory_warnings"))
		source = String(_native.call("source"))
	if _injecting:
		if _injected_thermal >= 0:
			level = _injected_thermal
		warnings += _injected_warnings
		_injected_warnings = 0
		source = "injected"
	var thermal := "unavailable"
	if level >= 0 and level < THERMAL_NAMES.size():
		thermal = THERMAL_NAMES[level]
	else:
		level = -1
	return {
		"thermal": thermal,
		"thermal_level": level,
		"footprint_mib": footprint,
		"memory_warnings": warnings,
		"source": source,
	}
