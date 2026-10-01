class_name GodotTouchFallbackProvider
extends InputProvider
## iOS-only fallback when the native bridge is unavailable. Godot's touch events carry no
## contact type, so every sample is UNKNOWN: the router never lets it edit, operate UI or
## navigate. The app must show label() so the disabled state is obvious.
##
## InputSystem forwards InputEventScreenTouch/Drag here via ingest_event() before swallowing
## them (this provider has no _input of its own, so handling order cannot matter).
## Godot's iOS view reports touchesCancelled as a release at window pixel (-1,-1); that release
## is indistinguishable from a real one at that pixel, so it becomes CANCEL
## ("godot_ambiguous_release") rather than END.

const AMBIGUOUS_RELEASE_REASON := "godot_ambiguous_release"
const AMBIGUOUS_WINDOW_PX := Vector2(-1, -1)

var _queue: Array[PointerSample] = []
var _sequence := 0
var _active: Dictionary = {}  # touch index -> last position
var _ignored: Dictionary = {}  # touch index -> true after cancel_all until it lifts


func provider_name() -> String:
	return "godot_touch_fallback"


func is_available() -> bool:
	return true


func label() -> String:
	return "GODOT TOUCH FALLBACK — NO PENCIL IDENTITY, EDITING DISABLED"


func capabilities() -> Dictionary:
	return {
		"source_identity": false, "pressure": false, "tilt": false, "coalesced": false,
		"native_cancel": false, "native_timestamps": false,
	}


func ingest_event(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if _active.has(d.index) and not _ignored.has(d.index):
			_active[d.index] = d.position
			_push(d.index, PointerSample.Phase.MOVE, d.position)


func drain_samples() -> Array[PointerSample]:
	var out := _queue
	_queue = []
	return out


func cancel_all(reason: String) -> void:
	for idx: int in _active:
		if not _ignored.has(idx):
			_ignored[idx] = true
			_push(idx, PointerSample.Phase.CANCEL, _active[idx], reason)


func diagnostics() -> Dictionary:
	return {"active": _active.size(), "queued": _queue.size()}


func _on_touch(t: InputEventScreenTouch) -> void:
	if t.pressed:
		if _active.has(t.index):
			return
		_active[t.index] = t.position
		_push(t.index, PointerSample.Phase.BEGIN, t.position)
		return
	if not _active.has(t.index):
		return
	var was_ignored := _ignored.has(t.index)
	var last: Vector2 = _active[t.index]
	_active.erase(t.index)
	_ignored.erase(t.index)
	if was_ignored:
		return
	if t.canceled:
		_push(t.index, PointerSample.Phase.CANCEL, last, "native_cancel")
	elif is_ambiguous_release(t.position):
		_push(t.index, PointerSample.Phase.CANCEL, last, AMBIGUOUS_RELEASE_REASON)
	else:
		_push(t.index, PointerSample.Phase.END, t.position)


## `pos` is viewport-local (Godot already applied the root final transform to the event).
func is_ambiguous_release(pos: Vector2) -> bool:
	if pos == AMBIGUOUS_WINDOW_PX:
		return true
	if is_inside_tree():
		var local := get_viewport().get_final_transform().affine_inverse() * AMBIGUOUS_WINDOW_PX
		return pos.is_equal_approx(local)
	return false


func _push(idx: int, phase: int, pos: Vector2, reason: String = "") -> void:
	var s := PointerSample.new()
	s.source = PointerSample.Source.UNKNOWN
	s.pointer_id = idx
	s.phase = phase
	s.timestamp_s = now_seconds()
	s.position_raw = pos
	s.position_viewport = pos
	s.sample_sequence = _sequence
	s.cancel_reason = reason
	_sequence += 1
	_queue.append(s)
