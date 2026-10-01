class_name InputSystem
extends Node
## Composition of the single authoritative input path (spec §6.2, docs/input-contract.md):
## provider -> CoordinateMapper -> InputRouter -> camera/tool/ui/diagnostic signals.
##
## iOS single-path rule: every Godot InputEventScreenTouch/Drag and every mouse event not
## created here is swallowed before any node or control sees it, so no second path can operate UI
## or world. Embedded Windows (dialogs, popups) get raw input forwarded by the root *before* the
## root's _input phase, so a RawInputGuard is installed as the last internal child of the root and
## of every Window: _input runs in reverse tree order, so each guard runs first in its viewport,
## whatever is added later, and guards (like this node) ignore pause. Pencil-owned ui_* actions
## are re-injected as mouse events tagged with SYNTHETIC_DEVICE_ID. On desktop the real mouse
## drives the GUI and MacDevInputProvider only observes, so nothing is swallowed.
##
## Listener-side pairing: a handler may call cancel_all() while a batch of actions is being
## dispatched. The rest of that batch was computed before the cancel and is dropped, and any
## operation the listeners still see as open is closed with the cancel reason (tool_cancel,
## ui_cancel, camera_end), so a tool never gets tool_end after asking for a cancel.

signal sample_received(sample: PointerSample)
signal camera_action(action: Dictionary)
signal tool_action(action: Dictionary)
signal ui_action(action: Dictionary)
## Emitted before synthetic release so application transactions can roll back first.
signal ui_cancelled(reason: String)
signal diagnostic(action: Dictionary)

const SYNTHETIC_DEVICE_ID := 4242
const NATIVE_PROVIDER_PATH := "res://src/input/ios_native_input_provider.gd"
const FALLBACK_BANNER := "Native Pencil input unavailable — editing disabled"
const OFFSCREEN := Vector2(-100000, -100000)
const MAX_DIAGNOSTICS := 32
const GUARD_NAME := "InputSystemRawGuard"
const _BEGIN_TYPES := ["tool_begin", "ui_press", "camera_orbit_begin", "camera_pan_zoom_begin"]
const _END_TYPES := ["tool_end", "tool_cancel", "ui_release", "ui_cancel", "camera_end"]
const _CLOSE_TYPES := {"tool": "tool_cancel", "ui": "ui_cancel", "camera": "camera_end"}


## Swallows raw pointer events in its viewport (root or an embedded Window) before any other node
## or control there sees them; see the class comment.
class RawInputGuard:
	extends Node
	var system: InputSystem

	func _init(owner_system: InputSystem) -> void:
		system = owner_system
		name = InputSystem.GUARD_NAME
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _input(event: InputEvent) -> void:
		if is_instance_valid(system) and system.filter_raw_event(event, get_viewport()):
			get_viewport().set_input_as_handled()


## Set before adding to the tree (tests): "iOS" forces the iOS path; "" uses OS.get_name().
var platform_override: String = ""
## Set before adding to the tree (tests): used instead of automatic provider selection.
var provider_override: InputProvider = null
var native_provider_path: String = NATIVE_PROVIDER_PATH
var orbit_threshold_pt: float = 5.0
## Palm guards for finger UI (config input.*); forwarded to the router.
var finger_ui_guard_s: float = 0.3
var palm_radius_pt: float = 30.0

var router := InputRouter.new()
var mapper := CoordinateMapper.new()
var ui_hits := UiHitTester.new()
var trace := InputTrace.new()

var _provider: InputProvider = null
var _is_ios := false
var _editing_enabled := true
var _banner := ""
var _recent_diagnostics: Array[Dictionary] = []
var _stats := {"samples": 0, "swallowed": 0, "synthetic": 0, "cancels": 0}
var _ui_last := Vector2.ZERO
var _ui_press_control: Control = null
var _ui_press_source := "pencil"
var _guards: Dictionary = {}  # guarded viewport instance id -> RawInputGuard
var _open := {"tool": false, "ui": false, "camera": false}  # as listeners have seen it
var _cancel_serial := 0


func _ready() -> void:
	process_priority = -1000  # route input before tools, camera and UI refresh this frame
	process_mode = Node.PROCESS_MODE_ALWAYS  # a paused tree must not reopen the raw path
	_is_ios = (platform_override if platform_override != "" else OS.get_name()) == "iOS"
	ui_hits.root = get_tree().root
	router.ui_hit_test = ui_hits.hit_callable()
	_load_input_config()
	_select_provider()
	_provider.provider_failed.connect(_on_provider_failed)
	if _provider.has_signal("cancel_requested"):
		_provider.connect("cancel_requested", cancel_all)
	if _is_ios:
		Input.emulate_mouse_from_touch = false  # touches must never arrive as a second, mouse path
		_install_guards()


func _enter_tree() -> void:
	if is_node_ready() and _is_ios:
		_install_guards()


func _exit_tree() -> void:
	_remove_guards()


func active_provider() -> InputProvider:
	return _provider


## True when the open UI press came from a Pencil (or the desktop mouse); false for a finger.
func ui_press_is_pencil() -> bool:
	return _ui_press_source != "finger"


func is_ios_path() -> bool:
	return _is_ios


func is_development_input() -> bool:
	return _provider != null and _provider.is_development()


func editing_enabled() -> bool:
	return _editing_enabled


## Non-empty when the user must be told input is degraded (shown as a banner).
func banner_text() -> String:
	return _banner


func provider_label() -> String:
	if _provider != null and _provider.has_method("label"):
		return str(_provider.call("label"))
	return _provider.provider_name() if _provider != null else ""


func recent_diagnostics() -> Array[Dictionary]:
	return _recent_diagnostics.duplicate()


func stats() -> Dictionary:
	var out := _stats.duplicate()
	out["state"] = router.state_name()
	out["provider"] = _provider.provider_name() if _provider != null else ""
	out["mapping_generation"] = mapper.generation
	return out


func set_modal(on: bool) -> void:
	trace.record_event("set_modal", {"on": on})
	_dispatch(router.set_modal(on))


## Cancels every active operation and contact (spec §16.3 reasons).
func cancel_all(reason: String) -> void:
	var had_contacts := router.has_active_contacts()
	trace.record_event("cancel_all", {"reason": reason})
	_cancel_serial += 1
	if _provider != null:
		_provider.cancel_all(reason)
	_dispatch(router.cancel_all(reason))
	_close_open_operations(reason)
	_stats.cancels += 1
	if had_contacts:
		_emit_diagnostic("input_cancelled", "input cancelled: %s" % reason)


## True when `event` is a raw Godot pointer event that must not reach anything (iOS only). Touches
## go to the fallback provider (in root-viewport coordinates) before being swallowed.
func filter_raw_event(event: InputEvent, vp: Viewport) -> bool:
	if not _is_ios or not is_inside_tree() or event.device == SYNTHETIC_DEVICE_ID:
		return false
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		if _provider != null and _provider.has_method("ingest_event"):
			var root_event: InputEvent = event if vp == get_tree().root \
					else event.xformed_by(UiHitTester.to_root_transform(vp))
			_provider.call("ingest_event", root_event)
	elif not event is InputEventMouse:
		return false
	_stats.swallowed += 1
	return true


## Covers the moment before the deferred root guard is installed.
func _input(event: InputEvent) -> void:
	if filter_raw_event(event, get_viewport()):
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	run_frame()


## One routing pass: refresh mapping, drain, map, route, dispatch.
func run_frame() -> void:
	if _provider == null:
		return
	_refresh_mapping()
	var draining := _provider
	var samples := draining.drain_samples()
	if draining != _provider:
		return  # fatal failure closed operations; never route the failed drain
	for s in samples:
		s.position_viewport = mapper.map(s.position_raw)
		s.mapping_generation = mapper.generation
		_stats.samples += 1
		trace.record_sample(s)
		sample_received.emit(s)
		_dispatch(router.process(s))


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, \
				NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			if is_node_ready():
				cancel_all("app_deactivated")


func _load_input_config() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://config/poc_defaults.json"))
	if typeof(parsed) != TYPE_DICTIONARY or typeof((parsed as Dictionary).get("input")) != TYPE_DICTIONARY:
		_apply_finger_ui_params()
		return
	var cfg: Dictionary = (parsed as Dictionary)["input"]
	finger_ui_guard_s = maxf(0.0, float(cfg.get("finger_ui_guard_s", finger_ui_guard_s)))
	palm_radius_pt = maxf(0.0, float(cfg.get("palm_radius_pt", palm_radius_pt)))
	_apply_finger_ui_params()


func _apply_finger_ui_params() -> void:
	router.finger_ui_guard_s = finger_ui_guard_s
	router.palm_radius_pt = palm_radius_pt  # raw points: compared with the native touch radius


func _refresh_mapping() -> void:
	var root := get_tree().root
	var was_valid := mapper.is_valid()
	var changed := mapper.configure(_provider.coordinate_space(), _provider.view_metrics(),
			root.get_final_transform(), root.get_visible_rect().size)
	var threshold := mapper.points_to_viewport(orbit_threshold_pt)
	if is_finite(threshold) and threshold > 0.0:
		router.orbit_threshold = threshold  # a degenerate mapping keeps the last usable threshold
	if was_valid and not mapper.is_valid():
		_emit_diagnostic("mapping_invalid", "root transform is singular; positions unavailable")
	if changed and router.has_active_contacts():
		cancel_all("mapping_changed")


# --- provider selection --------------------------------------------------------------------

func _select_provider() -> void:
	if provider_override != null:
		_use_provider(provider_override)
		_editing_enabled = not provider_override is GodotTouchFallbackProvider
		return
	if not _is_ios:
		_use_provider(MacDevInputProvider.new())
		return
	var native := _load_native_provider()
	if native != null:
		_use_provider(native)
		if native.is_available():
			return
		remove_child(native)
		native.queue_free()
	_use_provider(GodotTouchFallbackProvider.new())
	_editing_enabled = false
	_banner = FALLBACK_BANNER
	_emit_diagnostic.call_deferred("native_input_unavailable", FALLBACK_BANNER)


func _use_provider(p: InputProvider) -> void:
	_provider = p
	if p.get_parent() == null:
		add_child(p)


## Loaded dynamically so this file parses whether or not the native provider exists.
func _load_native_provider() -> InputProvider:
	if native_provider_path == "" or not ResourceLoader.exists(native_provider_path):
		return null
	var script: Script = load(native_provider_path) as Script
	if script == null or not script.can_instantiate():
		return null
	var obj: Object = script.new()
	if obj is InputProvider:
		return obj as InputProvider
	if obj is Node:
		(obj as Node).free()
	return null


func _on_provider_failed(reason: String) -> void:
	_emit_diagnostic("provider_failed", "input provider failed: %s" % reason)
	var cancellation := failure_cancel_reason(reason)
	cancel_all(cancellation)
	if cancellation != "queue_overflow" and not _provider is GodotTouchFallbackProvider:
		var failed := _provider
		failed.provider_failed.disconnect(_on_provider_failed)
		failed.set_process(false)
		remove_child(failed)  # native provider stops its observer on exit
		failed.queue_free()
		var was_modal := router.is_modal()
		var threshold := router.orbit_threshold
		router = InputRouter.new()  # IDs and suppressed contacts belong to the old provider
		router.ui_hit_test = ui_hits.hit_callable()
		router.orbit_threshold = threshold
		_apply_finger_ui_params()
		router.set_modal(was_modal)
		_use_provider(GodotTouchFallbackProvider.new())
		_provider.provider_failed.connect(_on_provider_failed)
		_editing_enabled = false
		_banner = FALLBACK_BANNER


## Providers describe failures in prose (e.g. "queue overflow"); a known cancellation reason is
## passed through so tools see why (IN-10), anything else becomes "provider_failed".
static func failure_cancel_reason(reason: String) -> String:
	var key := reason.strip_edges().to_lower().replace(" ", "_")
	return key if InputRouter.CANCEL_REASONS.has(key) else "provider_failed"


# --- raw input guards (iOS) ----------------------------------------------------------------

func _install_guards() -> void:
	var tree := get_tree()
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
	var pending: Array[Node] = [tree.root]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		if n is Viewport:
			_attach_guard.call_deferred(n.get_instance_id())
		pending.append_array(n.get_children(true))


func _on_node_added(n: Node) -> void:
	if n is Window:
		_attach_guard.call_deferred(n.get_instance_id())  # the new window's parent is busy now


func _attach_guard(viewport_id: int) -> void:
	var vp := instance_from_id(viewport_id) as Viewport
	if not is_inside_tree() or vp == null or not vp.is_inside_tree() or not (vp is Window):
		return
	var existing: Variant = _guards.get(viewport_id)
	if is_instance_valid(existing) and (existing as Node).get_parent() == vp:
		return
	var guard := RawInputGuard.new(self)
	vp.add_child(guard, false, Node.INTERNAL_MODE_BACK)
	_guards[viewport_id] = guard


## queue_free: the root may be busy removing this node right now.
func _remove_guards() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	for g: Variant in _guards.values():
		if is_instance_valid(g):
			(g as Node).queue_free()
	_guards.clear()


# --- dispatch ------------------------------------------------------------------------------

func _dispatch(actions: Array[Dictionary]) -> void:
	var serial := _cancel_serial
	for a in actions:
		if serial != _cancel_serial and a.type != "diagnostic":
			continue  # computed before a handler's cancel_all, which already closed it
		_emit_action(a)


func _emit_action(a: Dictionary) -> void:
	var t: String = a.type
	var kind := t.get_slice("_", 0)
	if kind != "diagnostic" and not _track_open(kind, t):
		return
	trace.record_action(a)
	match kind:
		"camera":
			camera_action.emit(a)
		"tool":
			tool_action.emit(a)
		"ui":
			if t == "ui_press":
				_ui_press_source = str(a.get("source", "pencil"))
			if t == "ui_cancel":
				ui_cancelled.emit(str(a.reason))
			if _is_ios:
				_inject_ui(a)
			ui_action.emit(a)
		_:
			_remember_diagnostic(a)
			diagnostic.emit(a)


## False for an action continuing an operation the listeners already saw closed.
func _track_open(kind: String, t: String) -> bool:
	if not _open.has(kind):
		return true
	if t in _BEGIN_TYPES:
		_open[kind] = true
		return true
	if not _open[kind]:
		return false
	if t in _END_TYPES:
		_open[kind] = false
	return true


## Closes operations whose terminal action was still pending in an outer dispatch.
func _close_open_operations(reason: String) -> void:
	for kind: String in _CLOSE_TYPES:
		if _open[kind]:
			_emit_action({"type": _CLOSE_TYPES[kind], "reason": reason})


func _emit_diagnostic(code: String, message: String) -> void:
	var a := {"type": "diagnostic", "code": code, "message": message, "pointer_id": -1}
	trace.record_action(a)
	_remember_diagnostic(a)
	diagnostic.emit(a)


func _remember_diagnostic(a: Dictionary) -> void:
	_recent_diagnostics.append(a)
	if _recent_diagnostics.size() > MAX_DIAGNOSTICS:
		_recent_diagnostics.pop_front()


# --- synthetic Pencil-only UI events (iOS) -------------------------------------------------

func _inject_ui(a: Dictionary) -> void:
	match str(a.type):
		"ui_press":
			var pos: Vector2 = a.pos
			_push_motion(pos, 0)
			_push_button(pos, true)
			_ui_press_control = _hovered_control_at(pos)
		"ui_move":
			_push_motion(a.pos, MOUSE_BUTTON_MASK_LEFT)
		"ui_release":
			_push_button(a.pos, false)
			_ui_press_control = null
		"ui_cancel":
			# A button must not fire on cancel: drag the press off it first. Other controls
			# (sliders) keep their last value and just release in place.
			var release_at := _ui_last
			if is_instance_valid(_ui_press_control) and _ui_press_control is BaseButton:
				release_at = OFFSCREEN
				_push_motion(release_at, MOUSE_BUTTON_MASK_LEFT)
			_push_button(release_at, false)
			_ui_press_control = null


## The hovered control lives in the viewport under `pos`: an embedded window or the root.
func _hovered_control_at(pos: Vector2) -> Control:
	var root := get_tree().root
	var windows := root.get_embedded_subwindows()
	for i in range(windows.size() - 1, -1, -1):
		var w: Window = windows[i]
		if w.visible and not w.mouse_passthrough and UiHitTester.window_rect(w).has_point(pos):
			return w.gui_get_hovered_control()
	return root.gui_get_hovered_control()


func _push_motion(pos: Vector2, mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = pos - _ui_last
	ev.button_mask = mask
	_push(ev)
	_ui_last = pos


func _push_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	_push(ev)
	_ui_last = pos


func _push(ev: InputEventMouse) -> void:
	ev.device = SYNTHETIC_DEVICE_ID
	_stats.synthetic += 1
	get_tree().root.push_input(ev, true)
