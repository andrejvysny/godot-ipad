class_name MacDevInputProvider
extends InputProvider
## Mac development input (spec §6.2). Synthesizes PointerSamples from mouse/trackpad events.
## It observes events in _input and NEVER consumes them: the real mouse still drives the GUI.
## Development-only: the app must show label() and it never satisfies an iPad gate.
##
## Mapping: left = MOUSE_DEV id 1; right-drag = FINGER 101 (orbit); middle or Shift+right drag =
## FINGERs 201/202 at cursor ±(40,0) (pan); wheel / magnify = pinch FINGERs 301/302 at cursor
## ±(60,0) -> ±(60f,0); trackpad pan gesture = FINGERs 401/402 translated together.
## Synthetic pinch/pan gestures BEGIN in one drain and MOVE+END in the next, so the router sees
## a real two-finger transition. Escape emits cancel_requested("explicit").

signal cancel_requested(reason: String)

const PENCIL_ID := 1
const ORBIT_ID := 101
const PAN_IDS: Array[int] = [201, 202]
const PINCH_IDS: Array[int] = [301, 302]
const GESTURE_PAN_IDS: Array[int] = [401, 402]
const PAN_OFFSET := Vector2(40, 0)
const PINCH_OFFSET := Vector2(60, 0)
const WHEEL_FACTOR := 1.1
const PAN_GESTURE_SCALE := 8.0  ## viewport units per InputEventPanGesture delta unit

var _queue: Array[PointerSample] = []
var _sequence := 0
var _cursor := Vector2.ZERO
## Held groups: name ("pencil"/"orbit"/"pan") -> {ids: Array[int], offsets: Array[Vector2],
## button: MouseButton, cancelled: bool}. A cancelled group ignores events until released or
## pressed again.
var _held: Dictionary = {}
var _gesture: Dictionary = {}  # pending synthetic gesture: {kind, center, factor, shift, drained}


func provider_name() -> String:
	return "mac_development"


func is_development() -> bool:
	return true


func is_available() -> bool:
	return true


func label() -> String:
	return "MAC DEVELOPMENT INPUT"


func capabilities() -> Dictionary:
	return {
		"source_identity": false, "pressure": false, "tilt": false, "coalesced": false,
		"native_cancel": false, "native_timestamps": false,
	}


func view_metrics() -> Dictionary:
	return {"content_scale": DisplayServer.screen_get_scale()}


func _input(event: InputEvent) -> void:
	ingest_event(event)  # observe only; never set_input_as_handled


func ingest_event(event: InputEvent) -> void:
	if event is InputEventMouse:
		_cursor = (event as InputEventMouse).position
	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion()
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_queue_gesture("pinch", mg.position, mg.factor, Vector2.ZERO)
	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		_queue_gesture("pan", pg.position, 1.0, -pg.delta * PAN_GESTURE_SCALE)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			cancel_requested.emit("explicit")


func drain_samples() -> Array[PointerSample]:
	var out := _queue
	_queue = []
	if not _gesture.is_empty():
		if _gesture.drained:
			_finish_gesture(out)
		else:
			_gesture.drained = true
	return out


func cancel_all(reason: String) -> void:
	for group: String in _held:
		var h: Dictionary = _held[group]
		if h.cancelled:
			continue
		h.cancelled = true
		_emit_group(group, PointerSample.Phase.CANCEL, reason)
	if not _gesture.is_empty():
		for i in 2:
			_queue.append(_make(PointerSample.Source.FINGER, _gesture_ids()[i],
					PointerSample.Phase.CANCEL, _gesture_positions()[i], reason))
		_gesture = {}


func diagnostics() -> Dictionary:
	return {"held_groups": _held.keys(), "queued": _queue.size(), "gesture": _gesture.get("kind", "")}


# --- held buttons ----------------------------------------------------------------------------

func _on_mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				_queue_gesture("pinch", mb.position, WHEEL_FACTOR, Vector2.ZERO)
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_queue_gesture("pinch", mb.position, 1.0 / WHEEL_FACTOR, Vector2.ZERO)
		MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_press(_group_for(mb), mb.button_index)
			else:
				_release(mb.button_index)


func _group_for(mb: InputEventMouseButton) -> String:
	if mb.button_index == MOUSE_BUTTON_LEFT:
		return "pencil"
	if mb.button_index == MOUSE_BUTTON_RIGHT and not mb.shift_pressed:
		return "orbit"
	return "pan"


func _press(group: String, button: MouseButton) -> void:
	if _held.has(group):
		if not _held[group].cancelled:
			return
		# Its release was lost while unfocused (the CANCEL already went out): start a new contact.
		_held.erase(group)
	var ids: Array[int] = PAN_IDS.duplicate()
	var offsets: Array[Vector2] = [-PAN_OFFSET, PAN_OFFSET]
	if group != "pan":
		ids = [PENCIL_ID if group == "pencil" else ORBIT_ID]
		offsets = [Vector2.ZERO]
	_held[group] = {"ids": ids, "offsets": offsets, "button": button, "cancelled": false}
	_emit_group(group, PointerSample.Phase.BEGIN)


func _release(button: MouseButton) -> void:
	for group: String in _held.keys():
		var h: Dictionary = _held[group]
		if h.button != button:
			continue
		if not h.cancelled:
			_emit_group(group, PointerSample.Phase.END)
		_held.erase(group)


func _on_mouse_motion() -> void:
	for group: String in _held:
		if not _held[group].cancelled:
			_emit_group(group, PointerSample.Phase.MOVE)


func _emit_group(group: String, phase: int, reason: String = "") -> void:
	var h: Dictionary = _held[group]
	var source := PointerSample.Source.MOUSE_DEV if group == "pencil" else PointerSample.Source.FINGER
	var ids: Array[int] = h.ids
	var offsets: Array[Vector2] = h.offsets
	for i in ids.size():
		_queue.append(_make(source, ids[i], phase, _cursor + offsets[i], reason))


# --- synthetic two-finger gestures -----------------------------------------------------------

func _queue_gesture(kind: String, center: Vector2, factor: float, shift: Vector2) -> void:
	if not _gesture.is_empty() and _gesture.kind == kind:
		_gesture.factor *= factor  # accumulate until the MOVE+END drain
		_gesture.shift += shift
		return
	if not _gesture.is_empty():
		_finish_gesture(_queue)
	_gesture = {"kind": kind, "center": center, "factor": 1.0, "shift": Vector2.ZERO, "drained": false}
	var starts := _gesture_positions()
	for i in 2:
		_queue.append(_make(PointerSample.Source.FINGER, _gesture_ids()[i], PointerSample.Phase.BEGIN,
				starts[i]))
	_gesture.factor = factor
	_gesture.shift = shift


func _gesture_ids() -> Array[int]:
	return PINCH_IDS if _gesture.kind == "pinch" else GESTURE_PAN_IDS


## Current finger positions of the pending gesture (factor/shift applied).
func _gesture_positions() -> Array[Vector2]:
	var center: Vector2 = _gesture.center
	var shift: Vector2 = _gesture.shift
	var half: Vector2 = PINCH_OFFSET * float(_gesture.factor) if _gesture.kind == "pinch" else PAN_OFFSET
	return [center + shift - half, center + shift + half]


## Appends MOVE+END for the pending gesture to `out` and clears it.
func _finish_gesture(out: Array[PointerSample]) -> void:
	var ids := _gesture_ids()
	var ends := _gesture_positions()
	for phase: int in [PointerSample.Phase.MOVE, PointerSample.Phase.END]:
		for i in 2:
			out.append(_make(PointerSample.Source.FINGER, ids[i], phase, ends[i]))
	_gesture = {}


func _make(source: int, id: int, phase: int, pos: Vector2, cancel_reason: String = "") -> PointerSample:
	var s := PointerSample.new()
	s.source = source
	s.pointer_id = id
	s.phase = phase
	s.timestamp_s = now_seconds()
	s.position_raw = pos
	s.position_viewport = pos
	s.sample_sequence = _sequence
	s.cancel_reason = cancel_reason
	_sequence += 1
	return s
