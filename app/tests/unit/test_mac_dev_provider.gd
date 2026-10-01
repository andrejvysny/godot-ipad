extends TestCase
## MacDevInputProvider event synthesis (spec §6.2). Events are fed to _input directly.

const BEGIN := PointerSample.Phase.BEGIN
const MOVE := PointerSample.Phase.MOVE
const END := PointerSample.Phase.END
const CANCEL := PointerSample.Phase.CANCEL
const FINGER := PointerSample.Source.FINGER

var p: MacDevInputProvider


func before_each() -> void:
	p = MacDevInputProvider.new()


func after_each() -> void:
	p.free()


func _button(button: MouseButton, pressed: bool, pos: Vector2, shift: bool = false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.shift_pressed = shift
	p._input(e)


func _motion(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	p._input(e)


## "SOURCE id PHASE x,y" per sample, compact for assertions.
func _describe(samples: Array[PointerSample]) -> PackedStringArray:
	var out := PackedStringArray()
	for s in samples:
		out.append("%s %d %s %d,%d" % [PointerSample.source_name(s.source), s.pointer_id,
				PointerSample.phase_name(s.phase), roundi(s.position_raw.x), roundi(s.position_raw.y)])
	return out


func test_identity_and_labels() -> void:
	assert_eq(p.provider_name(), "mac_development")
	assert_true(p.is_development())
	assert_true(p.is_available())
	assert_eq(p.label(), "MAC DEVELOPMENT INPUT")
	assert_eq(p.capabilities().pressure, false)
	assert_eq(p.capabilities().source_identity, false)
	assert_eq(p.coordinate_space(), InputProvider.SPACE_VIEWPORT)


func test_left_button_is_mouse_dev_contact() -> void:
	_motion(Vector2(10, 10))
	assert_eq(p.drain_samples().size(), 0, "hover produces nothing")
	_button(MOUSE_BUTTON_LEFT, true, Vector2(100, 200))
	_motion(Vector2(110, 205))
	_button(MOUSE_BUTTON_LEFT, false, Vector2(110, 205))
	var got := p.drain_samples()
	assert_eq(_describe(got), PackedStringArray([
		"MOUSE_DEV 1 BEGIN 100,200", "MOUSE_DEV 1 MOVE 110,205", "MOUSE_DEV 1 END 110,205"]))
	assert_true(got[0].sample_sequence < got[1].sample_sequence, "monotonic sequence")
	assert_eq(got[0].position_viewport, got[0].position_raw, "viewport space")
	assert_false(got[0].pressure_valid, "no pressure")
	assert_eq(p.drain_samples().size(), 0)


func test_right_drag_is_one_finger() -> void:
	_button(MOUSE_BUTTON_RIGHT, true, Vector2(500, 400))
	_motion(Vector2(520, 400))
	_button(MOUSE_BUTTON_RIGHT, false, Vector2(520, 400))
	assert_eq(_describe(p.drain_samples()), PackedStringArray([
		"FINGER 101 BEGIN 500,400", "FINGER 101 MOVE 520,400", "FINGER 101 END 520,400"]))


func test_middle_and_shift_right_drag_are_two_finger_pan() -> void:
	_button(MOUSE_BUTTON_MIDDLE, true, Vector2(500, 400))
	_motion(Vector2(510, 420))
	_button(MOUSE_BUTTON_MIDDLE, false, Vector2(510, 420))
	assert_eq(_describe(p.drain_samples()), PackedStringArray([
		"FINGER 201 BEGIN 460,400", "FINGER 202 BEGIN 540,400",
		"FINGER 201 MOVE 470,420", "FINGER 202 MOVE 550,420",
		"FINGER 201 END 470,420", "FINGER 202 END 550,420"]))
	_button(MOUSE_BUTTON_RIGHT, true, Vector2(300, 300), true)
	_button(MOUSE_BUTTON_RIGHT, false, Vector2(300, 300), false)
	assert_eq(_describe(p.drain_samples()), PackedStringArray([
		"FINGER 201 BEGIN 260,300", "FINGER 202 BEGIN 340,300",
		"FINGER 201 END 260,300", "FINGER 202 END 340,300"]), "release matches by button")


func test_wheel_is_pinch_across_two_drains() -> void:
	_button(MOUSE_BUTTON_WHEEL_UP, true, Vector2(600, 400))
	_button(MOUSE_BUTTON_WHEEL_UP, false, Vector2(600, 400))
	assert_eq(_describe(p.drain_samples()), PackedStringArray([
		"FINGER 301 BEGIN 540,400", "FINGER 302 BEGIN 660,400"]), "BEGIN in first drain")
	var second := p.drain_samples()
	assert_eq(second.size(), 4)
	assert_near(second[0].position_raw.x, 600.0 - 66.0, 1e-3, "zoom in spreads fingers x1.1")
	assert_near(second[1].position_raw.x, 600.0 + 66.0, 1e-3)
	assert_eq(second[2].phase, END)
	assert_eq(second[3].phase, END)
	assert_eq(p.drain_samples().size(), 0)


func test_wheel_accumulates_until_move_drain() -> void:
	_button(MOUSE_BUTTON_WHEEL_DOWN, true, Vector2(600, 400))
	p.drain_samples()
	_button(MOUSE_BUTTON_WHEEL_DOWN, true, Vector2(600, 400))
	var second := p.drain_samples()
	assert_eq(second.size(), 4, "no new BEGIN while a pinch is pending")
	assert_near(second[1].position_raw.x - 600.0, 60.0 / 1.21, 1e-3, "two notches")


func test_magnify_and_pan_gestures() -> void:
	var mg := InputEventMagnifyGesture.new()
	mg.position = Vector2(400, 300)
	mg.factor = 0.5
	p._input(mg)
	p.drain_samples()
	var second := p.drain_samples()
	assert_near(second[1].position_raw.x, 430.0, 1e-3, "pinch in")
	var pg := InputEventPanGesture.new()
	pg.position = Vector2(400, 300)
	pg.delta = Vector2(1, 0)
	p._input(pg)
	assert_eq(_describe(p.drain_samples()), PackedStringArray([
		"FINGER 401 BEGIN 360,300", "FINGER 402 BEGIN 440,300"]))
	var moved := p.drain_samples()
	assert_eq(_describe(moved)[0], "FINGER 401 MOVE %d,300" % roundi(360 - MacDevInputProvider.PAN_GESTURE_SCALE))


func test_pinch_through_router_is_a_real_transition() -> void:
	var r := InputRouter.new()
	var types := PackedStringArray()
	_button(MOUSE_BUTTON_WHEEL_UP, true, Vector2(600, 400))
	for frame in 3:
		for s in p.drain_samples():
			for a in r.process(s):
				types.append(a.type)
	assert_eq(types, PackedStringArray([
		"camera_pan_zoom_begin", "camera_pan_zoom", "camera_pan_zoom", "camera_end"]))
	assert_eq(r.state_name(), "IDLE")


func test_escape_requests_explicit_cancel() -> void:
	var got: Array[String] = []
	p.cancel_requested.connect(func(reason: String) -> void: got.append(reason))
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.pressed = true
	p._input(k)
	assert_eq(got.size(), 1)
	assert_eq(got[0] if got.size() > 0 else "", "explicit")


func test_cancel_all_cancels_held_contacts_until_release() -> void:
	_button(MOUSE_BUTTON_LEFT, true, Vector2(100, 100))
	_motion(Vector2(120, 100))
	p.drain_samples()
	p.cancel_all("explicit")
	var got := p.drain_samples()
	assert_eq(_describe(got), PackedStringArray(["MOUSE_DEV 1 CANCEL 120,100"]))
	assert_eq(got[0].cancel_reason, "explicit")
	_motion(Vector2(140, 100))
	_button(MOUSE_BUTTON_LEFT, false, Vector2(140, 100))
	assert_eq(p.drain_samples().size(), 0, "ignored until physically released")
	_button(MOUSE_BUTTON_LEFT, true, Vector2(150, 100))
	assert_eq(_describe(p.drain_samples()), PackedStringArray(["MOUSE_DEV 1 BEGIN 150,100"]))


func test_press_after_cancel_with_lost_release_starts_new_contact() -> void:
	_button(MOUSE_BUTTON_LEFT, true, Vector2(100, 100))
	_button(MOUSE_BUTTON_RIGHT, true, Vector2(100, 100))
	p.cancel_all("app_deactivated")  # focus out; both releases are then lost
	assert_eq(p.drain_samples().size(), 4, "BEGIN x2 + CANCEL x2")
	_button(MOUSE_BUTTON_LEFT, true, Vector2(300, 200))
	_button(MOUSE_BUTTON_RIGHT, true, Vector2(300, 200))
	assert_eq(_describe(p.drain_samples()), PackedStringArray(["MOUSE_DEV 1 BEGIN 300,200",
			"FINGER 101 BEGIN 300,200"]), "first clicks after refocus are not swallowed")
	_button(MOUSE_BUTTON_LEFT, false, Vector2(300, 200))
	assert_eq(_describe(p.drain_samples()), PackedStringArray(["MOUSE_DEV 1 END 300,200"]))
	_button(MOUSE_BUTTON_RIGHT, true, Vector2(310, 200))
	assert_eq(p.drain_samples().size(), 0, "a live (not cancelled) contact still ignores a repeat press")


func test_cancel_all_cancels_pending_pinch() -> void:
	_button(MOUSE_BUTTON_WHEEL_UP, true, Vector2(600, 400))
	p.drain_samples()
	p.cancel_all("app_deactivated")
	var got := p.drain_samples()
	assert_eq(got.size(), 2)
	assert_eq(got[0].phase, CANCEL)
	assert_eq(p.drain_samples().size(), 0)
