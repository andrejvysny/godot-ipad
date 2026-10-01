extends TestCase
## InputSystem composition: provider selection, iOS single-path swallowing (IN-04) including
## embedded dialogs/popups, pause and tree order, synthetic Pencil-only UI events (IN-02/IN-03
## logic), cancellation paths (IN-09, IN-10), re-entrant cancels, mapping.


class FakeProvider:
	extends InputProvider
	var queue: Array[PointerSample] = []
	var metrics: Dictionary = {}
	var cancels: Array[String] = []

	func provider_name() -> String:
		return "fake"

	func is_available() -> bool:
		return true

	func view_metrics() -> Dictionary:
		return metrics

	func drain_samples() -> Array[PointerSample]:
		var out := queue
		queue = []
		return out

	func cancel_all(reason: String) -> void:
		cancels.append(reason)

	func push(source: int, id: int, phase: int, pos: Vector2, reason: String = "") -> void:
		var s := PointerSample.new()
		s.source = source
		s.pointer_id = id
		s.phase = phase
		s.position_raw = pos
		s.cancel_reason = reason
		queue.append(s)


class TouchProbe:
	extends Node
	var unhandled := 0

	func _unhandled_input(_e: InputEvent) -> void:
		unhandled += 1


class InputSpy:
	extends Node
	var seen := 0

	func _input(e: InputEvent) -> void:
		if e is InputEventScreenTouch or e is InputEventMouseButton:
			seen += 1


## Stand-in for the WPNativeInput singleton (same method set as the GDExtension).
class FakeBridge:
	extends RefCounted
	var pending := PackedFloat64Array()
	var overflow_count := 0
	var cancel_codes: Array[int] = []

	func start() -> bool:
		return true

	func stop() -> void:
		pass

	func is_active() -> bool:
		return true

	func drain() -> PackedFloat64Array:
		var out := pending
		pending = PackedFloat64Array()
		return out

	func get_record_stride() -> int:
		return 14

	func native_now() -> float:
		return 10.0

	func get_view_metrics() -> Dictionary:
		return {"view_size_points": Vector2(1180, 820), "content_scale": 2.0, "safe_area": Rect2()}

	func get_capabilities() -> Dictionary:
		return {"source_identity": true, "pressure": true}

	func cancel_all(code: int) -> void:
		cancel_codes.append(code)

	func get_diagnostics() -> Dictionary:
		return {"overflow_count": overflow_count}

	func get_platform_info() -> Dictionary:
		return {}


const PENCIL := PointerSample.Source.PENCIL
const FINGER := PointerSample.Source.FINGER
const BEGIN := PointerSample.Phase.BEGIN
const MOVE := PointerSample.Phase.MOVE
const END := PointerSample.Phase.END
const CANCEL := PointerSample.Phase.CANCEL
const BUTTON_RECT := Rect2(20, 100, 80, 60)

var sys: InputSystem
var fake: FakeProvider
var button: Button
var probe: TouchProbe
var got: Dictionary = {}
var pressed := 0
var gui_events := 0
var _extra: Array[Node] = []


func before_each() -> void:
	got = {"camera": [], "tool": [], "ui": [], "diagnostic": []}
	pressed = 0
	gui_events = 0


func after_each() -> void:
	tree.paused = false
	for n: Node in [sys, button, probe] + _extra:
		if is_instance_valid(n):
			n.get_parent().remove_child(n)
			n.free()
	_extra.clear()
	sys = null
	button = null
	probe = null


func _keep(n: Node) -> Node:
	tree.root.add_child(n)
	_extra.append(n)
	return n


## Raw-input guards are attached deferred; wait until the root has one.
func _await_guards() -> void:
	for i in 10:
		for c: Node in tree.root.get_children(true):
			if c is InputSystem.RawInputGuard and (c as InputSystem.RawInputGuard).system == sys:
				return
		await tree.process_frame
	fail("raw input guard never installed")


func _make_system(platform: String, provider: InputProvider = null) -> void:
	sys = InputSystem.new()
	sys.platform_override = platform
	sys.provider_override = provider
	sys.native_provider_path = "res://tests/does_not_exist_native_provider.gd"
	sys.camera_action.connect(func(a: Dictionary) -> void: got.camera.append(a))
	sys.tool_action.connect(func(a: Dictionary) -> void: got.tool.append(a))
	sys.ui_action.connect(func(a: Dictionary) -> void: got.ui.append(a))
	sys.diagnostic.connect(func(a: Dictionary) -> void: got.diagnostic.append(a))
	tree.root.add_child(sys)


func _make_button() -> void:
	button = Button.new()
	button.text = "Paint"
	button.position = BUTTON_RECT.position
	button.size = BUTTON_RECT.size
	tree.root.add_child(button)
	button.pressed.connect(func() -> void: pressed += 1)
	button.gui_input.connect(func(_e: InputEvent) -> void: gui_events += 1)
	sys.ui_hits.register(button)
	probe = TouchProbe.new()
	tree.root.add_child(probe)


func _types(list: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for a: Dictionary in list:
		out.append(a.type)
	return out


func _codes() -> PackedStringArray:
	var out := PackedStringArray()
	for a: Dictionary in got.diagnostic:
		out.append(a.code)
	return out


func _touch(index: int, pressed_: bool, pos: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.index = index
	t.pressed = pressed_
	t.position = pos
	tree.root.push_input(t, true)


func _mouse_click(pos: Vector2) -> void:
	for down: bool in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = down
		mb.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		mb.position = pos
		mb.global_position = pos
		tree.root.push_input(mb, true)


# --- provider selection ------------------------------------------------------------------------

func test_desktop_selects_labelled_mac_provider() -> void:
	_make_system("")
	assert_true(sys.active_provider() is MacDevInputProvider)
	assert_true(sys.is_development_input())
	assert_true(sys.editing_enabled())
	assert_eq(sys.provider_label(), "MAC DEVELOPMENT INPUT")
	assert_eq(sys.banner_text(), "")
	assert_false(sys.is_ios_path())


func test_ios_without_native_bridge_uses_fallback_and_disables_editing() -> void:
	_make_system("iOS")
	assert_true(sys.active_provider() is GodotTouchFallbackProvider)
	assert_false(sys.editing_enabled())
	assert_eq(sys.banner_text(), "Native Pencil input unavailable — editing disabled")
	assert_true(sys.provider_label().contains("EDITING DISABLED"))
	await tree.process_frame
	assert_true(_codes().has("native_input_unavailable"), "diagnostic shown")
	_touch(0, true, Vector2(600, 400))
	_touch(0, false, Vector2(600, 400))
	sys.run_frame()
	assert_eq(got.tool.size(), 0, "UNKNOWN touches never edit")
	assert_eq(got.camera.size(), 0)
	assert_true(_codes().has("unknown_source"))


func test_fallback_ambiguous_release_becomes_cancel() -> void:
	var fb := GodotTouchFallbackProvider.new()
	var t := InputEventScreenTouch.new()
	t.index = 3
	t.pressed = true
	t.position = Vector2(200, 200)
	fb.ingest_event(t)
	var rel := InputEventScreenTouch.new()
	rel.index = 3
	rel.position = Vector2(-1, -1)
	fb.ingest_event(rel)
	var s := fb.drain_samples()
	assert_eq(s.size(), 2)
	assert_eq(s[0].source, PointerSample.Source.UNKNOWN)
	assert_eq(s[1].phase, CANCEL, "ambiguous release is never END")
	assert_eq(s[1].cancel_reason, "godot_ambiguous_release")
	assert_eq(s[1].position_raw, Vector2(200, 200), "last known position kept")
	fb.free()


# --- iOS single path (IN-04) and synthetic UI ----------------------------------------------------

func test_ios_swallows_godot_touch_and_mouse_single_logical_action() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	var center := BUTTON_RECT.get_center()
	_touch(0, true, center)
	_touch(0, false, center)
	_mouse_click(center)
	var drag := InputEventScreenDrag.new()
	drag.position = Vector2(600, 400)
	tree.root.push_input(drag, true)
	assert_eq(pressed, 0, "Godot touch/mouse cannot operate UI")
	assert_eq(gui_events, 0, "control never saw them")
	assert_eq(probe.unhandled, 0, "nothing reaches unhandled input (world)")
	assert_eq(sys.stats().swallowed, 5)
	# Same physical Pencil contact delivered by the provider: exactly one logical action.
	fake.push(PENCIL, 1, BEGIN, Vector2(600, 400))
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin"]))
	fake.push(PENCIL, 1, END, Vector2(600, 400))
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_end"]))


func test_ios_pencil_on_button_injects_one_synthetic_click() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	var center := BUTTON_RECT.get_center()
	fake.push(PENCIL, 1, BEGIN, center)
	fake.push(PENCIL, 1, MOVE, center + Vector2(2, 1))
	fake.push(PENCIL, 1, END, center + Vector2(2, 1))
	sys.run_frame()
	assert_eq(pressed, 1, "IN-03: Pencil operates the control")
	assert_eq(_types(got.ui), PackedStringArray(["ui_press", "ui_move", "ui_release"]))
	assert_eq(got.tool.size(), 0)
	assert_true(sys.stats().synthetic >= 3)
	assert_eq(probe.unhandled, 0, "synthetic events consumed by the GUI")


func test_ios_ui_cancel_does_not_fire_button() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	fake.push(PENCIL, 1, BEGIN, BUTTON_RECT.get_center())
	fake.push(PENCIL, 1, CANCEL, BUTTON_RECT.get_center(), "native_cancel")
	sys.run_frame()
	assert_eq(_types(got.ui), PackedStringArray(["ui_press", "ui_cancel"]))
	assert_eq(pressed, 0, "cancelled press never activates")
	fake.push(PENCIL, 2, BEGIN, BUTTON_RECT.get_center())
	fake.push(PENCIL, 2, END, BUTTON_RECT.get_center())
	sys.run_frame()
	assert_eq(pressed, 1, "button still usable afterwards")


func test_ios_finger_tap_on_button_clicks_once_as_finger_ui() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	fake.push(FINGER, 10, BEGIN, BUTTON_RECT.get_center())
	fake.push(FINGER, 10, END, BUTTON_RECT.get_center())
	sys.run_frame()
	assert_eq(pressed, 1, "finger operates the button")
	assert_eq(_types(got.ui), PackedStringArray(["ui_press", "ui_release"]))
	assert_eq(got.ui[0].source, "finger")
	assert_false(sys.ui_press_is_pencil())
	assert_eq(got.camera.size() + got.tool.size(), 0, "never camera or tool")
	assert_true(sys.stats().synthetic > 0)


func test_ios_finger_drag_off_button_does_not_fire_or_navigate() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	fake.push(FINGER, 10, BEGIN, BUTTON_RECT.get_center())
	fake.push(FINGER, 10, MOVE, BUTTON_RECT.get_center() + Vector2(300, 0))
	fake.push(FINGER, 10, END, BUTTON_RECT.get_center() + Vector2(300, 0))
	sys.run_frame()
	assert_eq(pressed, 0, "released off the button")
	assert_eq(got.camera.size() + got.tool.size(), 0)


func test_palm_guard_params_come_from_config() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	assert_eq(sys.router.finger_ui_guard_s, 0.3)
	assert_eq(sys.router.palm_radius_pt, 30.0)


func test_ios_pencil_ui_press_is_pencil_source() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	fake.push(PENCIL, 1, BEGIN, BUTTON_RECT.get_center())
	sys.run_frame()
	assert_true(sys.ui_press_is_pencil())
	fake.push(PENCIL, 1, END, BUTTON_RECT.get_center())
	sys.run_frame()
	assert_eq(pressed, 1)


func test_desktop_does_not_swallow_or_inject() -> void:
	_make_system("")
	_make_button()
	_mouse_click(BUTTON_RECT.get_center())
	assert_eq(pressed, 1, "real mouse still drives the GUI")
	sys.run_frame()
	assert_eq(_types(got.ui), PackedStringArray(["ui_press", "ui_release"]), "provider observed it")
	assert_eq(sys.stats().synthetic, 0, "no injection on desktop")
	assert_eq(sys.stats().swallowed, 0)
	assert_eq(pressed, 1, "still exactly one activation")


func test_desktop_escape_cancels_explicitly() -> void:
	_make_system("")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = Vector2(600, 400)
	tree.root.push_input(mb, true)
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin"]))
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.pressed = true
	tree.root.push_input(k, true)
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_cancel"]))
	assert_eq(got.tool[1].reason, "explicit")
	sys.run_frame()
	assert_eq(sys.router.state_name(), "IDLE", "provider CANCEL cleared the contact")
	mb.pressed = false
	tree.root.push_input(mb, true)
	sys.run_frame()
	assert_eq(got.tool.size(), 2, "release of a cancelled contact is silent")


# --- cancellation paths (IN-09, IN-10) -----------------------------------------------------------

func _start_stroke() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	fake.push(PENCIL, 1, BEGIN, Vector2(600, 400))
	fake.push(PENCIL, 1, MOVE, Vector2(610, 400))
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_move"]))


func test_mapping_change_cancels_active_stroke() -> void:
	_start_stroke()
	var gen := sys.mapper.generation
	fake.metrics = {"content_scale": 3.0}
	fake.push(PENCIL, 1, MOVE, Vector2(620, 400))
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_move", "tool_cancel"]),
			"IN-10: no action with a stale mapping")
	assert_eq(got.tool[2].reason, "mapping_changed")
	assert_eq(sys.mapper.generation, gen + 1)
	assert_eq(fake.cancels, [] as Array[String] + (["mapping_changed"] as Array[String]))
	assert_true(_codes().has("input_cancelled"), "visible diagnostic")


func test_queue_overflow_failure_cancels_with_reason() -> void:
	_start_stroke()
	fake.provider_failed.emit("queue overflow")  # IOSNativeInputProvider's wording
	assert_eq(got.tool.back().type, "tool_cancel")
	assert_eq(got.tool.back().reason, "queue_overflow")
	assert_true(_codes().has("provider_failed"))
	fake.push(PENCIL, 1, CANCEL, Vector2(610, 400), "queue_overflow")
	sys.run_frame()
	assert_eq(got.tool.size(), 3, "no half-applied action afterwards")
	assert_eq(sys.router.state_name(), "IDLE")


func test_generic_provider_failure_uses_provider_failed_reason() -> void:
	_start_stroke()
	fake.provider_failed.emit("bridge_lost")
	assert_eq(got.tool.back().reason, "provider_failed")


func test_failure_reason_normalization() -> void:
	assert_eq(InputSystem.failure_cancel_reason("queue overflow"), "queue_overflow")
	assert_eq(InputSystem.failure_cancel_reason(" Queue Overflow "), "queue_overflow")
	assert_eq(InputSystem.failure_cancel_reason("queue_overflow"), "queue_overflow")
	assert_eq(InputSystem.failure_cancel_reason("bridge inactive"), "provider_failed")
	assert_eq(InputSystem.failure_cancel_reason("malformed native records: x"), "provider_failed")


func _native_record(field: Dictionary, phase: int, pos: Vector2, cancel_code: int = 0) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(14)
	r[field.SOURCE] = 1.0  # pencil
	r[field.POINTER_ID] = 7.0
	r[field.PHASE] = float(phase)
	r[field.X] = pos.x
	r[field.Y] = pos.y
	r[field.CANCEL_REASON] = float(cancel_code)
	return r


func test_native_provider_overflow_reaches_tools_as_queue_overflow() -> void:
	const NATIVE := "res://src/input/ios_native_input_provider.gd"
	if not assert_true(ResourceLoader.exists(NATIVE), "native provider present"):
		return
	var script: Script = load(NATIVE)
	var field: Dictionary = script.get_script_constant_map().Field
	var native: InputProvider = script.new()
	var bridge := FakeBridge.new()
	native.call("_bind_bridge", bridge)
	_make_system("iOS", native)
	bridge.pending = _native_record(field, BEGIN, Vector2(300, 200)) \
			+ _native_record(field, MOVE, Vector2(305, 200))
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_move"]))
	bridge.overflow_count = 1
	bridge.pending = _native_record(field, CANCEL, Vector2(305, 200), 3)  # 3 = queue_overflow
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_move", "tool_cancel"]),
			"IN-10: exactly one cancel, no half-applied action")
	assert_eq(got.tool.back().reason, "queue_overflow", "the real provider's overflow reason survives")
	assert_true(_codes().has("provider_failed"))
	assert_eq(bridge.cancel_codes, [4] as Array[int], "bridge told to cancel (explicit code)")
	assert_eq(sys.router.state_name(), "IDLE")
	assert_true(sys.router.contacts().is_empty(), "native CANCEL cleared the contact")


func test_cancel_from_tool_handler_replaces_pending_tool_end() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	sys.tool_action.connect(func(a: Dictionary) -> void:
		if a.type == "tool_resume":
			sys.cancel_all("tool_error"))
	fake.push(PENCIL, 1, BEGIN, Vector2(600, 400))
	fake.push(PENCIL, 1, MOVE, BUTTON_RECT.get_center())
	fake.push(PENCIL, 1, END, Vector2(600, 400))  # router batch: [tool_resume, tool_end]
	sys.run_frame()
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin", "tool_pause", "tool_resume", "tool_cancel"]),
			"a tool that asked to cancel never gets tool_end")
	assert_eq(got.tool.back().reason, "tool_error")
	assert_true(sys.router.contacts().is_empty())
	fake.push(PENCIL, 2, BEGIN, Vector2(600, 400))
	fake.push(PENCIL, 2, END, Vector2(600, 400))
	sys.run_frame()
	assert_eq(_types(got.tool).slice(4), PackedStringArray(["tool_begin", "tool_end"]), "next stroke clean")


func test_cancel_from_camera_handler_drops_pending_begin() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	sys.camera_action.connect(func(a: Dictionary) -> void:
		if a.type == "camera_end" and a.reason == "second_finger":
			sys.cancel_all("explicit"))
	fake.push(FINGER, 10, BEGIN, Vector2(500, 400))
	fake.push(FINGER, 10, MOVE, Vector2(700, 400))
	fake.push(FINGER, 10, MOVE, Vector2(720, 400))
	fake.push(FINGER, 11, BEGIN, Vector2(800, 400))  # router batch: [camera_end, pan_zoom_begin]
	fake.push(FINGER, 11, MOVE, Vector2(900, 400))
	sys.run_frame()
	assert_eq(_types(got.camera), PackedStringArray(["camera_orbit_begin", "camera_orbit", "camera_end"]),
			"no camera_pan_zoom_begin left open after the cancel")


func test_app_deactivation_cancels_and_leaves_no_stale_contact() -> void:
	_start_stroke()
	sys.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_eq(got.tool.back().type, "tool_cancel", "IN-09")
	assert_eq(got.tool.back().reason, "app_deactivated")
	assert_eq(fake.cancels.back(), "app_deactivated")
	fake.push(PENCIL, 1, CANCEL, Vector2(610, 400), "app_deactivated")
	sys.run_frame()
	assert_true(sys.router.contacts().is_empty(), "no stale contact")
	fake.push(PENCIL, 2, BEGIN, Vector2(500, 400))
	sys.run_frame()
	assert_eq(got.tool.back().type, "tool_begin", "next stroke starts cleanly")


func test_modal_cancels_stroke_through_system() -> void:
	_start_stroke()
	sys.set_modal(true)
	assert_eq(got.tool.back().reason, "modal")
	sys.set_modal(false)


# --- embedded windows, pause, tree order (iOS single path) ---------------------------------------

func test_ios_dialog_raw_touch_and_mouse_ignored_finger_and_pencil_confirm_once() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = "Delete object?"
	var confirmed := [0]
	dialog.confirmed.connect(func() -> void: confirmed[0] += 1)
	_keep(dialog)
	dialog.popup_centered()
	await _await_guards()
	await tree.process_frame
	var ok_center := UiHitTester.screen_rect(dialog.get_ok_button()).get_center()
	assert_true(UiHitTester.window_rect(dialog).has_point(ok_center), "OK rect in root coordinates")
	assert_true(sys.ui_hits.is_over_ui(ok_center))
	assert_true(sys.ui_hits.is_over_ui(Vector2(5, 5)), "an exclusive dialog covers the screen")
	button.position = ok_center - button.size / 2.0  # a control right under the OK button
	var swallowed: int = sys.stats().swallowed
	_touch(0, true, ok_center)
	_touch(0, false, ok_center)
	_mouse_click(ok_center)
	assert_eq(confirmed[0], 0, "IN-02: raw touch/mouse cannot operate a dialog")
	assert_true(dialog.visible)
	assert_eq(sys.stats().swallowed, swallowed + 4)
	fake.push(FINGER, 10, BEGIN, ok_center)
	fake.push(FINGER, 10, END, ok_center)
	sys.run_frame()
	assert_eq(confirmed[0], 1, "a finger tap confirms once (ADR 0011)")
	await tree.process_frame
	assert_false(dialog.visible)
	dialog.popup_centered()
	await tree.process_frame
	fake.push(PENCIL, 1, BEGIN, ok_center)
	fake.push(PENCIL, 1, END, ok_center)
	sys.run_frame()
	assert_eq(confirmed[0], 2, "IN-03/IN-04: one Pencil tap = one confirmation")
	await tree.process_frame
	assert_false(dialog.visible)
	assert_eq(pressed, 0, "nothing under the dialog fires")
	assert_eq(got.tool.size() + got.camera.size(), 0, "no stroke or camera under the dialog")
	assert_eq(probe.unhandled, 0)


func test_ios_windows_created_before_the_system_are_guarded() -> void:
	var dialog := AcceptDialog.new()
	var confirmed := [0]
	dialog.confirmed.connect(func() -> void: confirmed[0] += 1)
	_keep(dialog)
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	dialog.popup_centered()
	await _await_guards()
	await tree.process_frame
	var ok_center := UiHitTester.screen_rect(dialog.get_ok_button()).get_center()
	_touch(0, true, ok_center)
	_touch(0, false, ok_center)
	assert_eq(confirmed[0], 0, "raw touch cannot operate a pre-existing dialog")
	assert_true(dialog.visible)


func test_ios_dialog_pencil_cancel_does_not_confirm() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	var dialog := ConfirmationDialog.new()
	var confirmed := [0]
	dialog.confirmed.connect(func() -> void: confirmed[0] += 1)
	_keep(dialog)
	dialog.popup_centered()
	await _await_guards()
	var ok_center := UiHitTester.screen_rect(dialog.get_ok_button()).get_center()
	fake.push(PENCIL, 1, BEGIN, ok_center)
	fake.push(PENCIL, 1, CANCEL, ok_center, "native_cancel")
	sys.run_frame()
	assert_eq(_types(got.ui), PackedStringArray(["ui_press", "ui_cancel"]))
	assert_eq(confirmed[0], 0, "cancelled press inside a window never activates")
	assert_true(dialog.visible)


func test_ios_option_popup_raw_touch_ignored_finger_and_pencil_select() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	var option := OptionButton.new()
	for label: String in ["Grass", "Rock", "Sand"]:
		option.add_item(label)
	option.position = Vector2(400, 100)
	option.size = Vector2(160, 40)
	_keep(option)
	await _await_guards()
	option.show_popup()
	await tree.process_frame
	var popup := option.get_popup()
	assert_true(popup.visible, "popup open")
	var rect := UiHitTester.window_rect(popup)
	var last_item := Vector2(rect.get_center().x, rect.position.y + rect.size.y * 5.0 / 6.0)
	assert_true(sys.ui_hits.is_over_ui(Vector2(1100, 700)), "an open popup owns the screen")
	_touch(0, true, last_item)
	_touch(0, false, last_item)
	assert_eq(option.selected, 0, "raw touch never selects")
	assert_true(popup.visible, "raw touch never dismisses")
	fake.push(FINGER, 10, BEGIN, last_item)
	fake.push(FINGER, 10, END, last_item)
	sys.run_frame()
	assert_eq(got.camera.size(), 0, "no orbit behind an open popup")
	assert_eq(option.selected, 2, "a finger selects the item it taps")
	await tree.process_frame  # popups hide deferred
	assert_false(popup.visible)
	option.show_popup()
	await tree.process_frame
	var first_item := Vector2(rect.get_center().x, rect.position.y + rect.size.y / 6.0)
	fake.push(PENCIL, 1, BEGIN, first_item)
	fake.push(PENCIL, 1, END, first_item)
	sys.run_frame()
	assert_eq(option.selected, 0, "Pencil selects the item it taps")
	await tree.process_frame
	assert_false(popup.visible)
	option.show_popup()
	await tree.process_frame
	fake.push(PENCIL, 2, BEGIN, Vector2(1100, 700))
	fake.push(PENCIL, 2, END, Vector2(1100, 700))
	sys.run_frame()
	await tree.process_frame
	assert_false(popup.visible, "Pencil tap outside dismisses the popup")
	assert_eq(got.tool.size(), 0, "and never paints")
	assert_eq(option.selected, 0, "dismissal keeps the Pencil selection")


func test_hit_tester_uses_root_coordinates_inside_plain_window() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	var w := Window.new()
	w.borderless = true
	w.position = Vector2i(300, 300)
	w.size = Vector2i(200, 100)
	var inner := Button.new()
	inner.position = Vector2(10, 20)
	inner.size = Vector2(50, 30)
	w.add_child(inner)
	_keep(w)
	await tree.process_frame
	assert_true(w.is_embedded())
	assert_eq(UiHitTester.screen_rect(inner), Rect2(310, 320, 50, 30), "window offset included")
	assert_true(sys.ui_hits.is_over_ui(Vector2(450, 390)), "inside a non-modal window")
	assert_false(sys.ui_hits.is_over_ui(Vector2(250, 390)), "outside it is world")
	assert_false(sys.ui_hits.is_over_ui(Vector2(NAN, NAN)), "NaN is never interface")
	w.hide()
	assert_false(sys.ui_hits.is_over_ui(Vector2(450, 390)), "hidden window is not interface")


func test_ios_paused_tree_still_swallows_and_routes() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	button.process_mode = Node.PROCESS_MODE_ALWAYS
	await _await_guards()
	tree.paused = true
	_touch(0, true, BUTTON_RECT.get_center())
	_touch(0, false, BUTTON_RECT.get_center())
	assert_eq(pressed, 0, "a paused tree does not reopen the raw path")
	fake.push(PENCIL, 1, BEGIN, Vector2(600, 400))
	for i in 5:
		if not got.tool.is_empty():
			break
		await tree.process_frame
	tree.paused = false
	assert_eq(_types(got.tool), PackedStringArray(["tool_begin"]), "routing continues while paused")


func test_ios_nodes_added_later_never_see_raw_input() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	await _await_guards()
	var spy := InputSpy.new()
	_keep(spy)
	_touch(0, true, Vector2(600, 400))
	_touch(0, false, Vector2(600, 400))
	_mouse_click(Vector2(600, 400))
	assert_eq(spy.seen, 0, "the guard runs first whatever is added after InputSystem")
	assert_true(sys.stats().swallowed >= 4)


# --- mapping and trace ---------------------------------------------------------------------------

func test_reduced_3d_render_scale_does_not_change_mapping() -> void:
	fake = FakeProvider.new()
	fake.metrics = {"content_scale": 2.0}
	_make_system("iOS", fake)
	sys.run_frame()
	var gen := sys.mapper.generation
	var before := sys.mapper.map(Vector2(300, 200))
	var old_scale := tree.root.scaling_3d_scale
	tree.root.scaling_3d_scale = 0.5
	sys.run_frame()
	assert_eq(sys.mapper.generation, gen, "IN-12: UI picking unaffected by 3D resolution")
	assert_eq(sys.mapper.map(Vector2(300, 200)), before)
	tree.root.scaling_3d_scale = old_scale


func test_samples_are_mapped_once_and_stamped() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	fake.push(PENCIL, 1, BEGIN, Vector2(600, 400))
	sys.run_frame()
	var s: PointerSample = got.tool[0].sample
	assert_eq(s.position_viewport, Vector2(600, 400), "viewport space is identity")
	assert_eq(s.mapping_generation, sys.mapper.generation)


func test_trace_records_samples_actions_and_events() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	sys.trace.start()
	fake.push(PENCIL, 1, BEGIN, Vector2(600, 400))
	sys.run_frame()
	sys.cancel_all("explicit")
	var kinds := PackedStringArray()
	for e: Dictionary in sys.trace.entries():
		kinds.append(e.kind)
	assert_eq(kinds, PackedStringArray(["sample", "action", "event", "action", "action"]))
	var replayed := InputTrace.replay(InputRouter.new(), sys.trace.entries())
	assert_eq(_types(replayed), PackedStringArray(["tool_begin", "tool_cancel"]))


func test_fatal_failure_cancels_then_switches_to_inert_fallback() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	fake.push(PENCIL, 1, BEGIN, Vector2(700, 700))
	sys.run_frame()
	fake.provider_failed.emit("bridge inactive")
	assert_eq(got.tool[-1].type, "tool_cancel")
	assert_eq(got.tool[-1].reason, "provider_failed")
	assert_true(sys.active_provider() is GodotTouchFallbackProvider)
	assert_false(sys.editing_enabled())
	assert_eq(sys.banner_text(), InputSystem.FALLBACK_BANNER)
	assert_false(sys.router.has_active_contacts())


func test_overflow_cancels_but_keeps_healthy_provider() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	fake.push(PENCIL, 1, BEGIN, Vector2(700, 700))
	sys.run_frame()
	fake.provider_failed.emit("queue overflow")
	assert_eq(got.tool[-1].type, "tool_cancel")
	assert_eq(got.tool[-1].reason, "queue_overflow")
	assert_true(sys.active_provider() == fake)
	assert_true(sys.editing_enabled())


func test_ui_cancel_notifies_application_before_release() -> void:
	fake = FakeProvider.new()
	_make_system("iOS", fake)
	_make_button()
	var observations: Array[String] = []
	sys.ui_cancelled.connect(func(reason: String) -> void: observations.append(reason))
	fake.push(PENCIL, 1, BEGIN, BUTTON_RECT.get_center())
	sys.run_frame()
	var releases_before: int = sys.stats().synthetic
	sys.ui_cancelled.connect(func(_reason: String) -> void:
		assert_eq(sys.stats().synthetic, releases_before, "rollback signal precedes injected release"))
	sys.cancel_all("explicit")
	assert_eq(observations, ["explicit"] as Array[String])
	assert_eq(pressed, 0)
