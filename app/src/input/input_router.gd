class_name InputRouter
extends RefCounted
## Input ownership and gesture state machine (spec §7). Pure logic: consumes mapped
## PointerSamples (position_viewport already set) and returns action dictionaries; see
## docs/input-contract.md for the normative vocabulary. Never touches the scene tree.
##
## Invariants:
## - Only PENCIL/MOUSE_DEV contacts ever produce tool_* or ui_* actions.
## - Only non-suppressed FINGER contacts ever produce camera_* actions.
## - Every camera_*_begin is followed by exactly one camera_end; tool_begin by exactly one
##   tool_end/tool_cancel; ui_press by exactly one ui_release/ui_cancel.
## - Non-finite positions (NAN = no sample) never reach hit-testing, tools, UI or camera: BEGIN
##   and MOVE are dropped, END/CANCEL cancel the contact with reason "invalid_position".
## - A suppressed contact stays suppressed until it physically ends or cancels.
## - Inert contacts (UNKNOWN source, fingers that begin over interface) are tracked for
##   diagnostics only: they never affect the state and never hold the machine in WAIT_RELEASE.

enum State { IDLE, PENCIL_UI, PENCIL_TOOL, ORBIT_CANDIDATE, ORBIT, PAN_ZOOM, WAIT_RELEASE }

const ROLE_PENCIL_UI := "pencil_ui"
const ROLE_PENCIL_TOOL := "pencil_tool"
const ROLE_CAMERA := "camera_finger"
const ROLE_SUPPRESSED := "suppressed"
const ROLE_UNKNOWN := "unknown"
const ROLE_FINGER_UI := "finger_on_ui"

const INVALID_POSITION_REASON := "invalid_position"

const CANCEL_REASONS := [
	"native_cancel", "app_deactivated", "mapping_changed", "queue_overflow", "explicit",
	"provider_failed", "modal", "tool_error", "view_changed", "invalid_phase",
	"invalid_position", "godot_ambiguous_release",
]


class Contact:
	extends RefCounted
	var id: int = -1
	var source: int = PointerSample.Source.UNKNOWN
	var role: String = ROLE_SUPPRESSED
	var suppressed := true
	var start_pos := Vector2.ZERO
	var last_pos := Vector2.ZERO


## Viewport units a finger must travel from its start before orbit begins.
var orbit_threshold: float = 5.0
## Callable(Vector2) -> bool; true when the viewport position is over interface.
var ui_hit_test: Callable = func(_p: Vector2) -> bool: return false

var _state: State = State.IDLE
var _contacts: Dictionary = {}  # int -> Contact
var _pencil_id: int = -1
var _camera_fingers: Array[int] = []
var _camera_begun := false
var _orbit_anchor := Vector2.ZERO
var _tool_paused := false
var _modal := false


func state() -> State:
	return _state


func state_name() -> String:
	return State.keys()[_state]


func is_modal() -> bool:
	return _modal


func has_active_contacts() -> bool:
	return not _contacts.is_empty()


## Diagnostics snapshot: id -> {source, role, suppressed, start_pos, last_pos}.
func contacts() -> Dictionary:
	var out := {}
	for id: int in _contacts:
		var c: Contact = _contacts[id]
		out[id] = {
			"source": PointerSample.source_name(c.source), "role": c.role,
			"suppressed": c.suppressed, "start_pos": c.start_pos, "last_pos": c.last_pos,
		}
	return out


func process(sample: PointerSample) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if sample.is_predicted:
		return out  # predicted samples never reach tools, UI or camera (spec §6.4)
	if not sample.position_viewport.is_finite():
		_on_invalid_position(sample, out)
		return out
	match sample.phase:
		PointerSample.Phase.BEGIN:
			_on_begin(sample, out)
		PointerSample.Phase.MOVE:
			_on_move(sample, out)
		PointerSample.Phase.END, PointerSample.Phase.CANCEL:
			_on_terminal(sample, out)
		_:
			out.append(_diag("invalid_phase", "phase %d" % sample.phase, sample.pointer_id))
	return out


## Cancels every active operation; all live contacts become suppressed until released.
func cancel_all(reason: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_end_active_operation(reason, out)
	for id: int in _contacts:
		_suppress(_contacts[id])
	_settle()
	return out


func set_modal(on: bool) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if on == _modal:
		return out
	_modal = on
	if on and _state != State.PENCIL_UI:
		_end_active_operation("modal", out)
		for id: int in _contacts:
			_suppress(_contacts[id])
		_settle()
	return out


# --- BEGIN ---------------------------------------------------------------------------------

func _on_begin(s: PointerSample, out: Array[Dictionary]) -> void:
	if _contacts.has(s.pointer_id):
		out.append(_diag("duplicate_begin", "BEGIN for active contact ignored", s.pointer_id))
		return
	var c := Contact.new()
	c.id = s.pointer_id
	c.source = s.source
	c.start_pos = s.position_viewport
	c.last_pos = s.position_viewport
	_contacts[c.id] = c
	if s.is_pencil_like():
		_begin_pencil(c, s, out)
	elif s.source == PointerSample.Source.FINGER:
		_begin_finger(c, out)
	else:
		c.role = ROLE_UNKNOWN
		out.append(_diag("unknown_source", "contact without source identity never edits", c.id))


func _begin_pencil(c: Contact, s: PointerSample, out: Array[Dictionary]) -> void:
	if _pencil_id != -1:
		out.append(_diag("second_pencil", "second pencil-like contact ignored", c.id))
		return
	var over_ui: bool = ui_hit_test.call(s.position_viewport)
	if _modal and not over_ui:
		out.append(_diag("modal_active", "world input blocked while a modal is open", c.id))
		_settle()
		return
	if _state in [State.ORBIT_CANDIDATE, State.ORBIT, State.PAN_ZOOM]:
		_end_camera("pencil_took_ownership", out)
		for id: int in _contacts:
			if id != c.id:
				_suppress(_contacts[id])
	_pencil_id = c.id
	c.suppressed = false
	if over_ui:
		c.role = ROLE_PENCIL_UI
		_state = State.PENCIL_UI
		out.append({"type": "ui_press", "pos": s.position_viewport, "pointer_id": c.id})
	else:
		c.role = ROLE_PENCIL_TOOL
		_state = State.PENCIL_TOOL
		_tool_paused = false
		out.append({"type": "tool_begin", "sample": s})


func _begin_finger(c: Contact, out: Array[Dictionary]) -> void:
	if ui_hit_test.call(c.start_pos):
		c.role = ROLE_FINGER_UI  # ignored; never UI, never camera behind the interface
		return
	match _state:
		State.IDLE:
			if _modal:
				_settle()
				return
			_join_camera(c)
			_state = State.ORBIT_CANDIDATE
		State.ORBIT_CANDIDATE, State.ORBIT:
			if _camera_begun:  # keep the first finger; only the orbit gesture ends
				out.append({"type": "camera_end", "reason": "second_finger"})
			_join_camera(c)
			_state = State.PAN_ZOOM
			var cs := _centroid_span()
			out.append({"type": "camera_pan_zoom_begin", "centroid": cs[0], "span": cs[1]})
			_camera_begun = true
		State.PAN_ZOOM:
			_end_camera("third_finger", out)
			for id: int in _contacts:
				_suppress(_contacts[id])
			_state = State.WAIT_RELEASE
		_:
			pass  # pencil active or waiting for release: stays suppressed until lifted


func _join_camera(c: Contact) -> void:
	c.role = ROLE_CAMERA
	c.suppressed = false
	_camera_fingers.append(c.id)


# --- MOVE ----------------------------------------------------------------------------------

func _on_move(s: PointerSample, out: Array[Dictionary]) -> void:
	var c: Contact = _contacts.get(s.pointer_id)
	if c == null:
		out.append(_diag("orphan_sample", "MOVE for unknown contact", s.pointer_id))
		return
	c.last_pos = s.position_viewport
	if c.suppressed:
		return
	match c.role:
		ROLE_PENCIL_UI:
			out.append({"type": "ui_move", "pos": s.position_viewport})
		ROLE_PENCIL_TOOL:
			_move_tool(s, out)
		ROLE_CAMERA:
			_move_camera(c, out)


func _move_tool(s: PointerSample, out: Array[Dictionary]) -> void:
	var over_ui: bool = ui_hit_test.call(s.position_viewport)
	if over_ui:
		if not _tool_paused:
			_tool_paused = true
			out.append({"type": "tool_pause", "sample": s})
		return  # occluded samples are dropped; the panel is never activated
	if _tool_paused:
		_tool_paused = false
		out.append({"type": "tool_resume", "sample": s})  # new segment; no interpolation
	else:
		out.append({"type": "tool_move", "sample": s})


func _move_camera(c: Contact, out: Array[Dictionary]) -> void:
	match _state:
		State.ORBIT_CANDIDATE:
			if c.last_pos.distance_to(c.start_pos) > orbit_threshold:
				_state = State.ORBIT
				_camera_begun = true
				_orbit_anchor = c.last_pos
				out.append({"type": "camera_orbit_begin", "pos": c.last_pos})
		State.ORBIT:
			var delta := c.last_pos - _orbit_anchor
			_orbit_anchor = c.last_pos
			if delta != Vector2.ZERO:
				out.append({"type": "camera_orbit", "delta": delta})
		State.PAN_ZOOM:
			var cs := _centroid_span()
			out.append({"type": "camera_pan_zoom", "centroid": cs[0], "span": cs[1]})


# --- END / CANCEL --------------------------------------------------------------------------

func _on_terminal(s: PointerSample, out: Array[Dictionary]) -> void:
	var c: Contact = _contacts.get(s.pointer_id)
	if c == null:
		out.append(_diag("orphan_sample", "%s for unknown contact" % PointerSample.phase_name(s.phase),
				s.pointer_id))
		return
	c.last_pos = s.position_viewport
	var cancelled := s.phase == PointerSample.Phase.CANCEL
	_terminate(c, s, cancelled, _cancel_reason(s) if cancelled else "released", out)


## A contact can end with an unusable position; it must still end, but nothing may be applied.
func _on_invalid_position(s: PointerSample, out: Array[Dictionary]) -> void:
	out.append(_diag(INVALID_POSITION_REASON, "non-finite position dropped", s.pointer_id))
	var c: Contact = _contacts.get(s.pointer_id)
	if c != null and s.is_terminal():
		_terminate(c, s, true, INVALID_POSITION_REASON, out)


func _terminate(c: Contact, s: PointerSample, cancelled: bool, reason: String,
		out: Array[Dictionary]) -> void:
	_contacts.erase(c.id)
	if c.suppressed:
		_settle()
		return
	match c.role:
		ROLE_PENCIL_UI:
			_pencil_id = -1
			if cancelled:
				out.append({"type": "ui_cancel", "reason": reason})
			else:
				out.append({"type": "ui_release", "pos": s.position_viewport})
		ROLE_PENCIL_TOOL:
			_pencil_id = -1
			_finish_tool(s, cancelled, reason, out)
		ROLE_CAMERA:
			_release_camera_finger(c, reason, out)
	_settle()


func _finish_tool(s: PointerSample, cancelled: bool, reason: String, out: Array[Dictionary]) -> void:
	if cancelled:
		out.append({"type": "tool_cancel", "reason": reason})
		return
	var over_ui: bool = ui_hit_test.call(s.position_viewport)
	if _tool_paused and not over_ui:
		out.append({"type": "tool_resume", "sample": s})  # lifted back over the world
	_tool_paused = false
	out.append({"type": "tool_end", "sample": s, "over_ui": over_ui})


func _release_camera_finger(c: Contact, reason: String, out: Array[Dictionary]) -> void:
	_camera_fingers.erase(c.id)
	if _state == State.PAN_ZOOM:
		# Two -> one finger: freeze until everything lifts; never becomes an orbit (spec §7.2).
		_end_camera("finger_lifted" if reason == "released" else reason, out)
		for id: int in _contacts:
			_suppress(_contacts[id])
	elif _camera_fingers.is_empty():
		_end_camera(reason, out)


# --- helpers -------------------------------------------------------------------------------

## Ends whatever operation currently owns input (tool, UI press, camera) with `reason`.
func _end_active_operation(reason: String, out: Array[Dictionary]) -> void:
	match _state:
		State.PENCIL_TOOL:
			out.append({"type": "tool_cancel", "reason": reason})
		State.PENCIL_UI:
			out.append({"type": "ui_cancel", "reason": reason})
		State.ORBIT_CANDIDATE, State.ORBIT, State.PAN_ZOOM:
			_end_camera(reason, out)
	_pencil_id = -1
	_tool_paused = false


## Emits camera_end only when a camera_*_begin was emitted, then clears camera ownership.
func _end_camera(reason: String, out: Array[Dictionary]) -> void:
	if _camera_begun:
		out.append({"type": "camera_end", "reason": reason})
	_camera_begun = false
	_camera_fingers.clear()


func _suppress(c: Contact) -> void:
	c.suppressed = true
	if not _is_inert(c):
		c.role = ROLE_SUPPRESSED


## Recomputes the resting state when no operation owns input.
func _settle() -> void:
	if _pencil_id != -1 or not _camera_fingers.is_empty():
		return
	_camera_begun = false
	for id: int in _contacts:
		if not _is_inert(_contacts[id]):
			_state = State.WAIT_RELEASE
			return
	_state = State.IDLE


func _is_inert(c: Contact) -> bool:
	return c.role == ROLE_UNKNOWN or c.role == ROLE_FINGER_UI


func _centroid_span() -> Array:
	var a: Contact = _contacts[_camera_fingers[0]]
	var b: Contact = _contacts[_camera_fingers[1]]
	return [(a.last_pos + b.last_pos) * 0.5, a.last_pos.distance_to(b.last_pos)]


func _cancel_reason(s: PointerSample) -> String:
	return s.cancel_reason if s.cancel_reason != "" else "native_cancel"


func _diag(code: String, message: String, pointer_id: int) -> Dictionary:
	return {"type": "diagnostic", "code": code, "message": message, "pointer_id": pointer_id}
