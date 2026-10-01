class_name IOSNativeInputProvider
extends InputProvider
## iOS provider backed by the WPNativeInput GDExtension (native/ios_input). A passive UIKit
## observer supplies typed Pencil/finger contacts; this wrapper decodes its flat float64 records.
## Positions are UIKit points in the observed view (SPACE_UIKIT_POINTS); CoordinateMapper maps
## them exactly once. Timestamps use the native clock: compare only with now_seconds(), never
## with Time.get_ticks_*(). Godot's own InputEventScreenTouch/Drag for the same contacts still
## arrive and must be ignored while this provider is authoritative (IN-04).
## Only the input system decides whether this provider is authoritative; on non-iOS it stays inert.
## Create at most one instance (two would split one bridge's records) and keep it in the tree: it
## starts the bridge in _ready, stops it on exit, and does not restart if re-added. A malformed
## record buffer is fatal: the bridge is stopped and the provider stays unavailable.

const SINGLETON_NAME := "WPNativeInput"
const RECORD_STRIDE := 14
## Records at least this wide carry the optional MAJOR_RADIUS field (older bridges send 14).
const RADIUS_STRIDE := 15
const EXPLICIT_CANCEL_CODE := 4
const CANCEL_REASON_NAMES := {
	1: "native_cancel", 2: "app_deactivated", 3: "queue_overflow", 4: "explicit", 5: "view_changed",
}
const FLAG_COALESCED := 1
const FLAG_PREDICTED := 2

## Field offsets inside one record; see native/ios_input/README.md "Record layout".
enum Field {
	SOURCE, POINTER_ID, PHASE, TIMESTAMP, X, Y, PRESSURE_VALID, PRESSURE, TILT_VALID, TILT_X,
	TILT_Y, FLAGS, SEQUENCE, CANCEL_REASON, MAJOR_RADIUS,
}

var _bridge: Object = null
var _started := false
var _inactive_reported := false
var _last_overflow_count := 0
var _decode_errors := 0
var _last_decode_error := ""
var _last_cancel_request := ""
var _open: Dictionary = {}  # pointer_id -> last sample of a contact delivered without a terminal
var _last_sequence := 0


func _ready() -> void:
	if OS.get_name() == "iOS" and Engine.has_singleton(SINGLETON_NAME):
		_bind_bridge(Engine.get_singleton(SINGLETON_NAME))


func _exit_tree() -> void:
	if _started:
		_bridge.call("stop")
		_started = false


## Binds and starts an object exposing the WPNativeInput method set (the engine singleton, or a
## fake in tests). Returns whether the observer attached.
func _bind_bridge(bridge: Object) -> bool:
	_bridge = bridge
	_started = bool(bridge.call("start"))
	_inactive_reported = false
	_open = {}
	_last_sequence = 0
	_last_overflow_count = int(_bridge_diagnostics().get("overflow_count", 0))
	return _started


func provider_name() -> String:
	return "ios_native_uikit"


func is_available() -> bool:
	return _started and bool(_bridge.call("is_active"))


func capabilities() -> Dictionary:
	if _bridge == null:
		return {}
	var caps: Dictionary = _bridge.call("get_capabilities")
	return caps


func coordinate_space() -> String:
	return SPACE_UIKIT_POINTS


func view_metrics() -> Dictionary:
	if _bridge == null:
		return {}
	var metrics: Dictionary = _bridge.call("get_view_metrics")
	return metrics


func now_seconds() -> float:
	if _bridge == null:
		return super.now_seconds()
	return float(_bridge.call("native_now"))


## Health signals fire before the samples are returned, so the input system has already cancelled
## its operations when it sees the CANCEL records of the same drain.
func drain_samples() -> Array[PointerSample]:
	var out: Array[PointerSample] = []
	if not _started:
		return out
	var flat: PackedFloat64Array = _bridge.call("drain")
	var stride: int = _bridge.call("get_record_stride")
	var err := layout_error(flat.size(), stride)
	if err != "":
		return _fail_malformed(err)
	out = decode_records(flat, stride)
	_track_open_contacts(out)
	_check_health()
	return out


func cancel_all(reason: String) -> void:
	_last_cancel_request = reason
	if _started:
		_bridge.call("cancel_all", EXPLICIT_CANCEL_CODE)


func diagnostics() -> Dictionary:
	var d := {
		"provider": provider_name(), "started": _started, "decode_errors": _decode_errors,
		"last_decode_error": _last_decode_error, "last_cancel_request": _last_cancel_request,
	}
	if _bridge != null:
		d.merge(_bridge_diagnostics(), true)
		var info: Dictionary = _bridge.call("get_platform_info")
		d.merge(info, true)
	return d


## "" when `size` float64 values hold a whole number of records of `stride` (>= RECORD_STRIDE;
## extra trailing fields are ignored), otherwise the reason.
static func layout_error(size: int, stride: int) -> String:
	if stride < RECORD_STRIDE:
		return "record stride %d is smaller than %d" % [stride, RECORD_STRIDE]
	if size % stride != 0:
		return "record buffer of %d values is not a multiple of stride %d" % [size, stride]
	return ""


## Pure decode of bridge records in arrival order. Returns [] when layout_error() is not "".
static func decode_records(flat: PackedFloat64Array, stride: int) -> Array[PointerSample]:
	var out: Array[PointerSample] = []
	if layout_error(flat.size(), stride) != "":
		return out
	for i in range(0, flat.size(), stride):
		out.append(_decode_record(flat, i, stride))
	return out


static func _decode_record(flat: PackedFloat64Array, i: int, stride: int) -> PointerSample:
	var s := PointerSample.new()
	if stride >= RADIUS_STRIDE:
		var radius: float = flat[i + Field.MAJOR_RADIUS]
		s.major_radius_valid = is_finite(radius) and radius >= 0.0
		s.major_radius = radius if s.major_radius_valid else 0.0
	s.source = _decode_source(flat[i + Field.SOURCE])
	s.pointer_id = int(flat[i + Field.POINTER_ID])
	s.timestamp_s = flat[i + Field.TIMESTAMP]
	s.position_raw = Vector2(flat[i + Field.X], flat[i + Field.Y])
	var pressure: float = flat[i + Field.PRESSURE]
	s.pressure_valid = flat[i + Field.PRESSURE_VALID] != 0.0 and is_finite(pressure)
	s.pressure = clampf(pressure, 0.0, 1.0) if s.pressure_valid else 0.0
	var tilt := Vector2(flat[i + Field.TILT_X], flat[i + Field.TILT_Y])
	s.tilt_valid = flat[i + Field.TILT_VALID] != 0.0 and tilt.is_finite()
	s.tilt = tilt if s.tilt_valid else Vector2.ZERO
	var flags := int(flat[i + Field.FLAGS])
	s.is_coalesced = (flags & FLAG_COALESCED) != 0
	s.is_predicted = (flags & FLAG_PREDICTED) != 0
	s.sample_sequence = int(flat[i + Field.SEQUENCE])
	var phase_code: float = flat[i + Field.PHASE]
	if phase_code in [0.0, 1.0, 2.0, 3.0]:
		s.phase = int(phase_code)
	else:
		# An unreadable phase might have been END/CANCEL; treating it as CANCEL is the only safe reading.
		s.phase = PointerSample.Phase.CANCEL
		s.cancel_reason = "invalid_phase"
		return s
	if s.phase == PointerSample.Phase.CANCEL:
		s.cancel_reason = CANCEL_REASON_NAMES.get(int(flat[i + Field.CANCEL_REASON]), "provider_failed")
	return s


## Identity comes only from the native touch type; anything unexpected is UNKNOWN, never PENCIL.
static func _decode_source(code: float) -> int:
	if code == 1.0:
		return PointerSample.Source.PENCIL
	if code == 2.0:
		return PointerSample.Source.FINGER
	return PointerSample.Source.UNKNOWN


## A buffer that is not whole records means the native layer is broken, and the dropped values may
## hold an END/CANCEL that the bridge will never repeat: it has already forgotten that contact, so
## a bridge-side cancel_all could not close it. The provider therefore stops the bridge for good and
## closes every contact it delivered with a CANCEL of its own at the last known position.
func _fail_malformed(err: String) -> Array[PointerSample]:
	_decode_errors += 1
	_last_decode_error = err
	var out := _cancel_open_contacts("provider_failed")
	_bridge.call("stop")
	_started = false
	provider_failed.emit("malformed native records: " + err)
	return out


func _track_open_contacts(samples: Array[PointerSample]) -> void:
	for s in samples:
		_last_sequence = maxi(_last_sequence, s.sample_sequence)
		if s.is_terminal():
			_open.erase(s.pointer_id)
		elif s.phase == PointerSample.Phase.BEGIN or _open.has(s.pointer_id):
			_open[s.pointer_id] = s


func _cancel_open_contacts(reason: String) -> Array[PointerSample]:
	var out: Array[PointerSample] = []
	var now := now_seconds()
	for id: int in _open:
		var last: PointerSample = _open[id]
		var s := PointerSample.new()
		s.source = last.source
		s.pointer_id = id
		s.phase = PointerSample.Phase.CANCEL
		s.timestamp_s = now
		s.position_raw = last.position_raw
		s.sample_sequence = _last_sequence
		s.cancel_reason = reason
		out.append(s)
	_open.clear()
	return out


func _bridge_diagnostics() -> Dictionary:
	var diag: Dictionary = _bridge.call("get_diagnostics")
	return diag


func _check_health() -> void:
	var overflow := int(_bridge_diagnostics().get("overflow_count", 0))
	if overflow > _last_overflow_count:
		_last_overflow_count = overflow
		provider_failed.emit("queue overflow")
	if not _inactive_reported and not bool(_bridge.call("is_active")):
		_inactive_reported = true
		provider_failed.emit("bridge inactive")
