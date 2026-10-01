extends TestCase
## InputRouter ownership rules (spec §7.2; IN-01, IN-02, IN-05..IN-11 logic, CA-02, CA-04).

const UI_RAIL := Rect2(0, 0, 100, 820)
const PENCIL := PointerSample.Source.PENCIL
const FINGER := PointerSample.Source.FINGER
const MOUSE := PointerSample.Source.MOUSE_DEV
const UNKNOWN := PointerSample.Source.UNKNOWN
const BEGIN := PointerSample.Phase.BEGIN
const MOVE := PointerSample.Phase.MOVE
const END := PointerSample.Phase.END
const CANCEL := PointerSample.Phase.CANCEL

var r: InputRouter
var _seq := 0


func before_each() -> void:
	r = InputRouter.new()
	r.orbit_threshold = 5.0
	r.ui_hit_test = func(p: Vector2) -> bool: return UI_RAIL.has_point(p)


func _s(source: int, id: int, phase: int, pos: Vector2, reason: String = "") -> PointerSample:
	var s := PointerSample.new()
	s.source = source
	s.pointer_id = id
	s.phase = phase
	s.position_raw = pos
	s.position_viewport = pos
	s.cancel_reason = reason
	s.sample_sequence = _seq
	_seq += 1
	return s


func _p(source: int, id: int, phase: int, x: float, y: float, reason: String = "") -> Array[Dictionary]:
	return r.process(_s(source, id, phase, Vector2(x, y), reason))


func _types(actions: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	for a in actions:
		out.append(a.type)
	return out


func _assert_types(actions: Array[Dictionary], expected: Array, msg: String = "") -> void:
	assert_eq(_types(actions), PackedStringArray(expected), msg)


# --- identity, unknown, predicted ------------------------------------------------------------

func test_pencil_and_mouse_dev_begin_edit_finger_does_not() -> void:
	_assert_types(_p(PENCIL, 1, BEGIN, 500, 400), ["tool_begin"], "pencil begin")
	assert_eq(r.state_name(), "PENCIL_TOOL")
	_assert_types(_p(PENCIL, 1, END, 500, 400), ["tool_end"])
	_assert_types(_p(MOUSE, 2, BEGIN, 500, 400), ["tool_begin"], "mouse dev is pencil-like")
	_assert_types(_p(MOUSE, 2, END, 500, 400), ["tool_end"])
	_assert_types(_p(FINGER, 3, BEGIN, 500, 400), [], "finger tap never edits")
	assert_eq(r.state_name(), "ORBIT_CANDIDATE")
	_assert_types(_p(FINGER, 3, END, 500, 400), [])
	assert_eq(r.state_name(), "IDLE")


func test_unknown_source_never_edits_operates_ui_or_navigates() -> void:
	var a := _p(UNKNOWN, 7, BEGIN, 500, 400)
	_assert_types(a, ["diagnostic"])
	assert_eq(a[0].code, "unknown_source")
	assert_eq(r.state_name(), "IDLE")
	_assert_types(_p(UNKNOWN, 7, MOVE, 700, 600), [], "no camera from unknown")
	_assert_types(_p(UNKNOWN, 7, END, 700, 600), [])
	a = _p(UNKNOWN, 8, BEGIN, 50, 50)
	_assert_types(a, ["diagnostic"], "unknown on UI: diagnostic only, never ui_press")
	_assert_types(_p(UNKNOWN, 8, END, 50, 50), [])
	assert_true(r.contacts().is_empty())
	assert_eq(r.state_name(), "IDLE")


func test_predicted_samples_never_reach_tools_ui_or_camera() -> void:
	var s := _s(PENCIL, 1, BEGIN, Vector2(500, 400))
	s.is_predicted = true
	_assert_types(r.process(s), [], "predicted begin")
	assert_true(r.contacts().is_empty(), "predicted begin not tracked")
	_p(PENCIL, 1, BEGIN, 500, 400)
	s = _s(PENCIL, 1, MOVE, Vector2(600, 400))
	s.is_predicted = true
	_assert_types(r.process(s), [], "predicted move")
	s = _s(PENCIL, 1, END, Vector2(600, 400))
	s.is_predicted = true
	_assert_types(r.process(s), [], "predicted end")
	assert_eq(r.state_name(), "PENCIL_TOOL", "predicted end does not finish")
	var f := _s(FINGER, 5, MOVE, Vector2(900, 400))
	f.is_predicted = true
	_assert_types(r.process(f), [], "predicted orphan is silent")


func test_no_pressure_samples_route_normally() -> void:
	var s := _s(PENCIL, 1, BEGIN, Vector2(500, 400))
	s.pressure_valid = false
	var a := r.process(s)
	_assert_types(a, ["tool_begin"], "IN-11: no pressure still edits")
	assert_false((a[0].sample as PointerSample).pressure_valid)
	_assert_types(_p(PENCIL, 1, MOVE, 510, 400), ["tool_move"])
	_assert_types(_p(PENCIL, 1, END, 510, 400), ["tool_end"])


# --- pencil on interface ------------------------------------------------------------------

func test_pencil_on_ui_owns_contact_until_release() -> void:
	var a := _p(PENCIL, 1, BEGIN, 50, 100)
	_assert_types(a, ["ui_press"])
	assert_eq(a[0].pos, Vector2(50, 100))
	assert_eq(a[0].pointer_id, 1)
	assert_eq(r.state_name(), "PENCIL_UI")
	_assert_types(_p(PENCIL, 1, MOVE, 400, 100), ["ui_move"], "moving off the control never strokes")
	_assert_types(_p(PENCIL, 1, MOVE, 600, 300), ["ui_move"])
	a = _p(PENCIL, 1, END, 600, 300)
	_assert_types(a, ["ui_release"])
	assert_eq(a[0].pos, Vector2(600, 300))
	assert_eq(r.state_name(), "IDLE")


func test_pencil_on_ui_cancel_emits_ui_cancel() -> void:
	_p(PENCIL, 1, BEGIN, 50, 100)
	var a := _p(PENCIL, 1, CANCEL, 50, 100)
	_assert_types(a, ["ui_cancel"])
	assert_eq(a[0].reason, "native_cancel")
	assert_eq(r.state_name(), "IDLE")


# --- pencil on world ------------------------------------------------------------------------

func test_stroke_crossing_ui_pauses_and_resumes_new_segment() -> void:
	_assert_types(_p(PENCIL, 1, BEGIN, 300, 400), ["tool_begin"])
	_assert_types(_p(PENCIL, 1, MOVE, 200, 400), ["tool_move"])
	var a := _p(PENCIL, 1, MOVE, 80, 400)
	_assert_types(a, ["tool_pause"], "IN-08: entering UI pauses, never ui_press")
	_assert_types(_p(PENCIL, 1, MOVE, 50, 420), [], "occluded samples dropped")
	_assert_types(_p(PENCIL, 1, MOVE, 60, 450), [])
	a = _p(PENCIL, 1, MOVE, 150, 480)
	_assert_types(a, ["tool_resume"], "re-entry starts a new segment")
	assert_eq((a[0].sample as PointerSample).position_viewport, Vector2(150, 480))
	_assert_types(_p(PENCIL, 1, MOVE, 200, 480), ["tool_move"])
	a = _p(PENCIL, 1, END, 200, 480)
	_assert_types(a, ["tool_end"])
	assert_eq(a[0].over_ui, false)


func test_stroke_ending_over_ui_flags_over_ui() -> void:
	_p(PENCIL, 1, BEGIN, 300, 400)
	_assert_types(_p(PENCIL, 1, MOVE, 90, 400), ["tool_pause"])
	var a := _p(PENCIL, 1, END, 90, 400)
	_assert_types(a, ["tool_end"])
	assert_eq(a[0].over_ui, true)
	assert_eq(r.state_name(), "IDLE")


func test_paused_stroke_lifting_over_world_resumes_before_end() -> void:
	_p(PENCIL, 1, BEGIN, 300, 400)
	_p(PENCIL, 1, MOVE, 90, 400)
	var a := _p(PENCIL, 1, END, 250, 400)
	_assert_types(a, ["tool_resume", "tool_end"])
	assert_eq(a[1].over_ui, false)


func test_native_cancel_mid_stroke_cancels_and_leaves_no_contact() -> void:
	_p(PENCIL, 1, BEGIN, 300, 400)
	_p(PENCIL, 1, MOVE, 320, 400)
	var a := _p(PENCIL, 1, CANCEL, 320, 400)
	_assert_types(a, ["tool_cancel"], "IN-09: CANCEL never becomes END")
	assert_eq(a[0].reason, "native_cancel")
	assert_true(r.contacts().is_empty(), "no stale contact")
	assert_eq(r.state_name(), "IDLE")
	_p(PENCIL, 2, BEGIN, 300, 400)
	a = _p(PENCIL, 2, CANCEL, 300, 400, "app_deactivated")
	assert_eq(a[0].reason, "app_deactivated", "sample cancel_reason is forwarded")


func test_second_pencil_contact_is_ignored() -> void:
	_p(PENCIL, 1, BEGIN, 300, 400)
	var a := _p(PENCIL, 2, BEGIN, 600, 400)
	_assert_types(a, ["diagnostic"])
	assert_eq(a[0].code, "second_pencil")
	_assert_types(_p(PENCIL, 2, MOVE, 650, 400), [])
	_assert_types(_p(PENCIL, 1, MOVE, 320, 400), ["tool_move"])
	_assert_types(_p(PENCIL, 1, END, 320, 400), ["tool_end"])
	assert_eq(r.state_name(), "WAIT_RELEASE", "second pencil still down")
	_assert_types(_p(PENCIL, 2, END, 650, 400), [])
	assert_eq(r.state_name(), "IDLE")


# --- pencil vs camera ----------------------------------------------------------------------

func test_pencil_begin_during_orbit_freezes_camera_and_suppresses_finger() -> void:
	_p(FINGER, 10, BEGIN, 700, 400)
	_assert_types(_p(FINGER, 10, MOVE, 720, 400), ["camera_orbit_begin"])
	var a := _p(PENCIL, 1, BEGIN, 300, 300)
	_assert_types(a, ["camera_end", "tool_begin"], "IN-06: camera frozen first")
	assert_eq(a[0].reason, "pencil_took_ownership")
	_assert_types(_p(FINGER, 10, MOVE, 800, 450), [], "suppressed finger cannot resume")
	_assert_types(_p(PENCIL, 1, END, 300, 300), ["tool_end"])
	assert_eq(r.state_name(), "WAIT_RELEASE")
	_assert_types(_p(FINGER, 10, MOVE, 900, 500), [], "still suppressed after pencil up")
	_assert_types(_p(FINGER, 10, END, 900, 500), [])
	assert_eq(r.state_name(), "IDLE")
	_p(FINGER, 11, BEGIN, 700, 400)
	_assert_types(_p(FINGER, 11, MOVE, 720, 400), ["camera_orbit_begin"], "fresh contact navigates")


func test_pencil_begin_during_pan_zoom() -> void:
	_p(FINGER, 10, BEGIN, 600, 400)
	_p(FINGER, 11, BEGIN, 800, 400)
	assert_eq(r.state_name(), "PAN_ZOOM")
	var a := _p(PENCIL, 1, BEGIN, 50, 50)
	_assert_types(a, ["camera_end", "ui_press"], "pencil on UI also takes ownership")
	_assert_types(_p(FINGER, 10, MOVE, 500, 400), [])
	_assert_types(_p(FINGER, 11, MOVE, 900, 400), [])
	_assert_types(_p(PENCIL, 1, END, 50, 50), ["ui_release"])
	_p(FINGER, 10, END, 500, 400)
	_p(FINGER, 11, END, 900, 400)
	assert_eq(r.state_name(), "IDLE")


func test_pencil_during_orbit_candidate_emits_no_camera_actions() -> void:
	_p(FINGER, 10, BEGIN, 700, 400)
	_p(FINGER, 10, MOVE, 702, 401)
	_assert_types(_p(PENCIL, 1, BEGIN, 300, 300), ["tool_begin"], "no camera_end without a begin")
	_assert_types(_p(FINGER, 10, MOVE, 800, 400), [])


func test_pencil_may_begin_in_wait_release() -> void:
	_p(PENCIL, 1, BEGIN, 300, 300)
	_p(FINGER, 10, BEGIN, 800, 500)
	_p(PENCIL, 1, END, 300, 300)
	assert_eq(r.state_name(), "WAIT_RELEASE")
	_assert_types(_p(PENCIL, 2, BEGIN, 320, 300), ["tool_begin"], "resting palm must not block")
	_assert_types(_p(PENCIL, 2, END, 320, 300), ["tool_end"])


# --- fingers --------------------------------------------------------------------------------

func _pt(source: int, id: int, phase: int, x: float, y: float, t: float,
		radius: float = -1.0) -> Array[Dictionary]:
	var s := _s(source, id, phase, Vector2(x, y))
	s.timestamp_s = t
	s.major_radius_valid = radius >= 0.0
	s.major_radius = maxf(radius, 0.0)
	return r.process(s)


func test_finger_tap_on_ui_presses_and_releases_as_ui() -> void:
	var a := _p(FINGER, 10, BEGIN, 50, 300)
	_assert_types(a, ["ui_press"])
	assert_eq(a[0].source, "finger")
	assert_eq(a[0].pointer_id, 10)
	assert_eq(r.state_name(), "FINGER_UI")
	_assert_types(_p(FINGER, 10, END, 50, 300), ["ui_release"])
	assert_eq(r.state_name(), "IDLE")


func test_pencil_ui_press_reports_pencil_source() -> void:
	assert_eq(_p(PENCIL, 1, BEGIN, 50, 300)[0].source, "pencil")
	_p(PENCIL, 1, END, 50, 300)
	assert_eq(_p(MOUSE, 2, BEGIN, 50, 300)[0].source, "pencil")


func test_finger_drag_from_ui_moves_ui_and_never_camera() -> void:
	_p(FINGER, 10, BEGIN, 50, 300)
	var all: Array[Dictionary] = []
	for x in [60.0, 200.0, 400.0, 700.0]:
		all.append_array(_p(FINGER, 10, MOVE, x, 300))
	_assert_types(all, ["ui_move", "ui_move", "ui_move", "ui_move"], "no camera from a UI finger")
	_assert_types(_p(FINGER, 10, END, 700, 300), ["ui_release"])
	assert_eq(r.state_name(), "IDLE")
	_p(FINGER, 11, BEGIN, 50, 300)
	_assert_types(_p(FINGER, 11, CANCEL, 60, 300, "native_cancel"), ["ui_cancel"])
	assert_eq(r.state_name(), "IDLE")


func test_second_finger_during_finger_ui_never_produces_camera() -> void:
	_p(FINGER, 10, BEGIN, 50, 300)
	var all: Array[Dictionary] = []
	all.append_array(_p(FINGER, 11, BEGIN, 700, 400))
	all.append_array(_p(FINGER, 11, MOVE, 800, 400))
	all.append_array(_p(FINGER, 12, BEGIN, 700, 500))
	all.append_array(_p(FINGER, 12, MOVE, 760, 500))
	all.append_array(_p(FINGER, 11, END, 800, 400))
	_assert_types(all, [], "only the first finger acts, and only on this contact")
	_assert_types(_p(FINGER, 10, MOVE, 60, 300), ["ui_move"])
	_assert_types(_p(FINGER, 10, END, 60, 300), ["ui_release"])
	assert_eq(r.state_name(), "WAIT_RELEASE", "suppressed finger 12 still down")
	_p(FINGER, 12, END, 760, 500)
	assert_eq(r.state_name(), "IDLE")


func test_finger_ui_blocked_while_pencil_down_and_inside_guard_after_it() -> void:
	_pt(PENCIL, 1, BEGIN, 500, 400, 1.0)
	var a := _pt(FINGER, 10, BEGIN, 50, 300, 1.1)
	_assert_types(a, ["diagnostic"])
	assert_eq(a[0].code, "finger_ui_guarded")
	_pt(FINGER, 10, END, 50, 300, 1.2)
	_pt(PENCIL, 1, END, 500, 400, 2.0)
	a = _pt(FINGER, 11, BEGIN, 50, 300, 2.2)
	assert_eq(a[0].code, "finger_ui_guarded", "within 0.3 s of Pencil end")
	_pt(FINGER, 11, END, 50, 300, 2.25)
	_assert_types(_pt(FINGER, 12, BEGIN, 50, 300, 2.31), ["ui_press"], "after the guard window")
	_pt(FINGER, 12, END, 50, 300, 2.4)
	assert_eq(r.state_name(), "IDLE")


func test_pencil_cancel_also_starts_guard_window() -> void:
	_pt(PENCIL, 1, BEGIN, 500, 400, 1.0)
	_pt(PENCIL, 1, CANCEL, 500, 400, 2.0)
	assert_eq(_pt(FINGER, 10, BEGIN, 50, 300, 2.1)[0].code, "finger_ui_guarded")


func test_palm_radius_finger_is_not_ui() -> void:
	var a := _pt(FINGER, 10, BEGIN, 50, 300, 1.0, 80.0)
	assert_eq(a[0].code, "finger_ui_palm")
	assert_true(str(a[0].message).contains("80.0 pt"), "message reports the measured radius")
	_assert_types(_pt(FINGER, 10, MOVE, 60, 300, 1.1, 80.0), [])
	_pt(FINGER, 10, END, 60, 300, 1.2)
	assert_eq(r.state_name(), "IDLE")
	# UIKit reports fingertips in ~5 pt steps up to ~45 pt; they must stay fingers.
	_assert_types(_pt(FINGER, 11, BEGIN, 50, 300, 2.0, 41.7), ["ui_press"], "fingertip radius is a finger")
	_pt(FINGER, 11, END, 50, 300, 2.1)
	_assert_types(_pt(FINGER, 12, BEGIN, 50, 300, 3.0), ["ui_press"], "unknown radius is a finger")


func test_pencil_begin_during_finger_ui_cancels_it_then_edits() -> void:
	_p(FINGER, 10, BEGIN, 50, 300)
	var a := _p(PENCIL, 1, BEGIN, 500, 400)
	_assert_types(a, ["ui_cancel", "tool_begin"])
	assert_eq(a[0].reason, "pencil_took_ownership")
	_assert_types(_p(FINGER, 10, MOVE, 60, 300), [], "finger is suppressed")
	_assert_types(_p(FINGER, 10, END, 60, 300), [])
	_assert_types(_p(PENCIL, 1, END, 500, 400), ["tool_end"])
	assert_eq(r.state_name(), "IDLE")
	_pt(FINGER, 11, BEGIN, 50, 300, 5.0)
	_assert_types(_pt(PENCIL, 2, BEGIN, 60, 300, 5.1), ["ui_cancel", "ui_press"], "Pencil on UI takes over")


func test_cancel_all_and_modal_close_finger_ui() -> void:
	_p(FINGER, 10, BEGIN, 50, 300)
	_assert_types(r.cancel_all("explicit"), ["ui_cancel"])
	_assert_types(_p(FINGER, 10, MOVE, 60, 300), [])
	_p(FINGER, 10, END, 60, 300)
	assert_eq(r.state_name(), "IDLE")
	_p(FINGER, 11, BEGIN, 50, 300)
	_assert_types(r.set_modal(true), [], "a modal opened by the press keeps it, like Pencil UI")
	_assert_types(_p(FINGER, 11, END, 50, 300), ["ui_release"])


func test_finger_ui_inert_when_camera_owns_input_and_world_finger_still_orbits() -> void:
	_p(FINGER, 12, BEGIN, 700, 400)
	_assert_types(_p(FINGER, 11, BEGIN, 50, 300), [], "UI finger during camera is inert")
	_assert_types(_p(FINGER, 12, MOVE, 720, 400), ["camera_orbit_begin"])
	_assert_types(_p(FINGER, 12, END, 720, 400), ["camera_end"])
	_p(FINGER, 11, END, 50, 300)
	assert_eq(r.state_name(), "IDLE", "inert UI finger does not hold WAIT_RELEASE")


func test_orbit_threshold_and_no_jump() -> void:
	_p(FINGER, 10, BEGIN, 700, 400)
	_assert_types(_p(FINGER, 10, MOVE, 703, 400), [], "below threshold")
	_assert_types(_p(FINGER, 10, MOVE, 705, 400), [], "exactly threshold is not beyond")
	var a := _p(FINGER, 10, MOVE, 710, 400)
	_assert_types(a, ["camera_orbit_begin"])
	assert_eq(a[0].pos, Vector2(710, 400))
	a = _p(FINGER, 10, MOVE, 714, 403)
	_assert_types(a, ["camera_orbit"])
	assert_eq(a[0].delta, Vector2(4, 3), "delta from crossing position, no jump")
	_assert_types(_p(FINGER, 10, MOVE, 714, 403), [], "zero delta skipped")
	a = _p(FINGER, 10, END, 714, 403)
	_assert_types(a, ["camera_end"])
	assert_eq(a[0].reason, "released")
	assert_eq(r.state_name(), "IDLE")


func test_second_finger_enters_pan_zoom_without_transition_motion() -> void:
	_p(FINGER, 10, BEGIN, 600, 400)
	_p(FINGER, 10, MOVE, 620, 400)
	var a := _p(FINGER, 11, BEGIN, 800, 400)
	_assert_types(a, ["camera_end", "camera_pan_zoom_begin"], "CA-02")
	assert_eq(a[0].reason, "second_finger")
	assert_eq(a[1].centroid, Vector2(710, 400))
	assert_near(a[1].span, 180.0, 1e-5)
	a = _p(FINGER, 11, MOVE, 820, 400)
	_assert_types(a, ["camera_pan_zoom"])
	assert_eq(a[0].centroid, Vector2(720, 400))
	assert_near(a[0].span, 200.0, 1e-5)


func test_second_finger_from_candidate_has_no_camera_end() -> void:
	_p(FINGER, 10, BEGIN, 600, 400)
	_assert_types(_p(FINGER, 11, BEGIN, 800, 400), ["camera_pan_zoom_begin"])
	assert_eq(r.state_name(), "PAN_ZOOM")


func test_two_to_one_finger_never_orbits() -> void:
	_p(FINGER, 10, BEGIN, 600, 400)
	_p(FINGER, 11, BEGIN, 800, 400)
	var a := _p(FINGER, 11, END, 800, 400)
	_assert_types(a, ["camera_end"], "IN-07")
	assert_eq(a[0].reason, "finger_lifted")
	assert_eq(r.state_name(), "WAIT_RELEASE")
	_assert_types(_p(FINGER, 10, MOVE, 700, 450), [], "remaining finger frozen")
	_assert_types(_p(FINGER, 10, MOVE, 800, 500), [])
	_assert_types(_p(FINGER, 10, END, 800, 500), [])
	assert_eq(r.state_name(), "IDLE")


func test_third_finger_freezes_until_all_released() -> void:
	_p(FINGER, 10, BEGIN, 600, 400)
	_p(FINGER, 11, BEGIN, 800, 400)
	var a := _p(FINGER, 12, BEGIN, 700, 600)
	_assert_types(a, ["camera_end"])
	assert_eq(a[0].reason, "third_finger")
	assert_eq(r.state_name(), "WAIT_RELEASE")
	for id in [10, 11, 12]:
		_assert_types(_p(FINGER, id, MOVE, 300, 300), [], "frozen")
	_p(FINGER, 10, END, 300, 300)
	_p(FINGER, 11, END, 300, 300)
	assert_eq(r.state_name(), "WAIT_RELEASE")
	_p(FINGER, 12, END, 300, 300)
	assert_eq(r.state_name(), "IDLE")


func test_finger_joining_pencil_stroke_is_suppressed() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	_assert_types(_p(FINGER, 10, BEGIN, 800, 500), [], "IN-05")
	_assert_types(_p(FINGER, 10, MOVE, 850, 520), [], "camera does not move")
	_assert_types(_p(PENCIL, 1, MOVE, 420, 400), ["tool_move"], "pencil keeps ownership")
	_assert_types(_p(FINGER, 11, BEGIN, 900, 500), [], "second finger too")
	_assert_types(_p(PENCIL, 1, END, 420, 400), ["tool_end"])
	assert_eq(r.state_name(), "WAIT_RELEASE")
	_assert_types(_p(FINGER, 10, MOVE, 950, 560), [], "fresh contact required")
	_p(FINGER, 10, END, 950, 560)
	_p(FINGER, 11, END, 950, 560)
	assert_eq(r.state_name(), "IDLE")


func test_finger_taps_and_long_presses_in_world_never_produce_tool_or_ui_actions() -> void:
	for pos: Vector2 in [Vector2(600, 400)]:
		var all: Array[Dictionary] = []
		all.append_array(_p(FINGER, 10, BEGIN, pos.x, pos.y))
		for i in 30:  # long press with sub-threshold jitter
			all.append_array(_p(FINGER, 10, MOVE, pos.x + (i % 3), pos.y))
		all.append_array(_p(FINGER, 10, END, pos.x, pos.y))
		_assert_types(all, [], "tap at %s" % pos)


func test_palm_resting_before_and_after_stroke() -> void:
	var all: Array[Dictionary] = []
	all.append_array(_p(FINGER, 20, BEGIN, 900, 600))  # palm down first
	all.append_array(_p(FINGER, 20, MOVE, 902, 601))
	all.append_array(_p(FINGER, 20, MOVE, 903, 603))
	all.append_array(_p(PENCIL, 1, BEGIN, 500, 300))
	all.append_array(_p(FINGER, 20, MOVE, 930, 640))  # palm slides during stroke
	all.append_array(_p(PENCIL, 1, MOVE, 520, 310))
	all.append_array(_p(PENCIL, 1, END, 520, 310))
	for i in 10:  # palm stays and drifts after Pencil-up
		all.append_array(_p(FINGER, 20, MOVE, 930 + i * 8, 640 + i * 4))
	all.append_array(_p(PENCIL, 2, BEGIN, 600, 300))  # second stroke with palm still down
	all.append_array(_p(PENCIL, 2, END, 600, 300))
	all.append_array(_p(FINGER, 20, END, 1010, 680))
	_assert_types(all, ["tool_begin", "tool_move", "tool_end", "tool_begin", "tool_end"], "CA-04")
	for a in all:
		assert_ne((a.sample as PointerSample).pointer_id, 20, "no tool action from the palm")
	assert_eq(r.state_name(), "IDLE")


# --- protocol errors -------------------------------------------------------------------------

func test_orphan_samples_are_diagnosed_without_state_change() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	for phase in [MOVE, END, CANCEL]:
		var a := _p(FINGER, 99, phase, 10, 10)
		_assert_types(a, ["diagnostic"])
		assert_eq(a[0].code, "orphan_sample")
		assert_eq(a[0].pointer_id, 99)
		assert_eq(r.state_name(), "PENCIL_TOOL")


func test_duplicate_begin_is_diagnosed_and_ignored() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	var a := _p(PENCIL, 1, BEGIN, 500, 500)
	_assert_types(a, ["diagnostic"])
	assert_eq(a[0].code, "duplicate_begin")
	_assert_types(_p(PENCIL, 1, MOVE, 410, 400), ["tool_move"])


# --- non-finite positions (NAN = no sample) --------------------------------------------------

func test_non_finite_begin_is_never_hit_tested_or_routed() -> void:
	var hit_tests := [0]
	r.ui_hit_test = func(_p2: Vector2) -> bool:
		hit_tests[0] += 1
		return true  # a NaN that reached Rect2.has_point() would count as over UI
	for pos: Vector2 in [Vector2(NAN, NAN), Vector2(INF, 10), Vector2(10, -INF)]:
		var a := r.process(_s(PENCIL, 1, BEGIN, pos))
		_assert_types(a, ["diagnostic"], "pencil %s" % pos)
		assert_eq(a[0].code, "invalid_position")
		assert_eq(r.state_name(), "IDLE")
		assert_true(r.contacts().is_empty(), "no contact tracked")
	_assert_types(r.process(_s(FINGER, 5, BEGIN, Vector2(NAN, 3))), ["diagnostic"], "finger")
	assert_eq(hit_tests[0], 0, "NaN never reaches the UI hit test")
	_assert_types(_p(PENCIL, 1, MOVE, 410, 400), ["diagnostic"], "later samples are orphans")


func test_non_finite_move_is_dropped_and_stroke_continues() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	var a := r.process(_s(PENCIL, 1, MOVE, Vector2(NAN, 400)))
	_assert_types(a, ["diagnostic"])
	assert_eq(a[0].code, "invalid_position")
	assert_eq(r.contacts()[1].last_pos, Vector2(400, 400), "last good position kept")
	_assert_types(_p(PENCIL, 1, MOVE, 410, 400), ["tool_move"])
	_assert_types(_p(PENCIL, 1, END, 410, 400), ["tool_end"])


func test_non_finite_end_cancels_instead_of_ending() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	var a := r.process(_s(PENCIL, 1, END, Vector2(NAN, NAN)))
	_assert_types(a, ["diagnostic", "tool_cancel"], "garbage end point is never applied")
	assert_eq(a[1].reason, "invalid_position")
	assert_eq(r.state_name(), "IDLE")
	assert_true(r.contacts().is_empty(), "contact still released")
	_p(PENCIL, 2, BEGIN, 50, 50)
	_assert_types(r.process(_s(PENCIL, 2, END, Vector2(INF, 50))), ["diagnostic", "ui_cancel"])


func test_non_finite_finger_never_reaches_camera() -> void:
	_p(FINGER, 10, BEGIN, 400, 400)
	_p(FINGER, 11, BEGIN, 600, 400)
	var a := r.process(_s(FINGER, 11, MOVE, Vector2(NAN, NAN)))
	_assert_types(a, ["diagnostic"], "no camera_pan_zoom with a NaN centroid")
	a = _p(FINGER, 11, MOVE, 620, 400)
	_assert_types(a, ["camera_pan_zoom"])
	assert_true(a[0].centroid.is_finite() and is_finite(a[0].span))
	a = r.process(_s(FINGER, 11, CANCEL, Vector2(NAN, NAN)))
	_assert_types(a, ["diagnostic", "camera_end"])
	assert_eq(a[1].reason, "invalid_position")
	assert_eq(r.state_name(), "WAIT_RELEASE")
	_p(FINGER, 10, END, 400, 400)
	assert_eq(r.state_name(), "IDLE")


# --- modal and cancel_all --------------------------------------------------------------------

func test_modal_cancels_tool_and_only_allows_pencil_on_ui() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	var a := r.set_modal(true)
	_assert_types(a, ["tool_cancel"])
	assert_eq(a[0].reason, "modal")
	_assert_types(_p(PENCIL, 1, MOVE, 420, 400), [])
	_assert_types(_p(PENCIL, 1, END, 420, 400), [])
	a = _p(PENCIL, 2, BEGIN, 500, 500)
	_assert_types(a, ["diagnostic"], "pencil on world blocked")
	assert_eq(a[0].code, "modal_active")
	_assert_types(_p(PENCIL, 2, MOVE, 520, 500), [])
	_assert_types(_p(PENCIL, 2, END, 520, 500), [])
	_assert_types(_p(FINGER, 10, BEGIN, 600, 400), [])
	_assert_types(_p(FINGER, 10, MOVE, 700, 400), [], "no camera while modal")
	_p(FINGER, 10, END, 700, 400)
	_assert_types(_p(PENCIL, 3, BEGIN, 50, 50), ["ui_press"], "pencil on UI works")
	_assert_types(_p(PENCIL, 3, END, 50, 50), ["ui_release"])
	_assert_types(r.set_modal(false), [])
	_assert_types(_p(PENCIL, 4, BEGIN, 400, 400), ["tool_begin"])


func test_modal_ends_camera_and_keeps_pencil_ui_press() -> void:
	_p(FINGER, 10, BEGIN, 600, 400)
	_p(FINGER, 10, MOVE, 700, 400)
	var a := r.set_modal(true)
	_assert_types(a, ["camera_end"])
	assert_eq(a[0].reason, "modal")
	_assert_types(_p(FINGER, 10, MOVE, 800, 400), [])
	r.set_modal(false)
	_p(FINGER, 10, END, 800, 400)
	_p(PENCIL, 1, BEGIN, 50, 50)
	_assert_types(r.set_modal(true), [], "the pressing control keeps its contact")
	_assert_types(_p(PENCIL, 1, END, 50, 50), ["ui_release"])


func test_cancel_all_every_reason_cancels_stroke_and_suppresses() -> void:
	for reason: String in InputRouter.CANCEL_REASONS:
		before_each()
		_p(PENCIL, 1, BEGIN, 400, 400)
		_p(FINGER, 10, BEGIN, 800, 400)
		var a := r.cancel_all(reason)
		_assert_types(a, ["tool_cancel"], reason)
		assert_eq(a[0].reason, reason)
		assert_eq(r.state_name(), "WAIT_RELEASE", reason)
		_assert_types(_p(PENCIL, 1, MOVE, 450, 400), [], "%s: suppressed until lifted" % reason)
		_assert_types(_p(PENCIL, 1, CANCEL, 450, 400, reason), [], "provider CANCEL is silent")
		_p(FINGER, 10, END, 800, 400)
		assert_eq(r.state_name(), "IDLE", reason)
		assert_true(r.contacts().is_empty(), reason)


func test_cancel_all_ends_ui_and_camera() -> void:
	_p(PENCIL, 1, BEGIN, 50, 50)
	var a := r.cancel_all("explicit")
	_assert_types(a, ["ui_cancel"])
	assert_eq(a[0].reason, "explicit")
	_p(PENCIL, 1, END, 50, 50)
	_p(FINGER, 10, BEGIN, 600, 400)
	_p(FINGER, 11, BEGIN, 800, 400)
	a = r.cancel_all("mapping_changed")
	_assert_types(a, ["camera_end"])
	assert_eq(a[0].reason, "mapping_changed")
	_assert_types(_p(FINGER, 10, MOVE, 500, 400), [])
	_assert_types(r.cancel_all("explicit"), [], "nothing active")


func test_cancel_all_when_idle_is_noop() -> void:
	_assert_types(r.cancel_all("app_deactivated"), [])
	assert_eq(r.state_name(), "IDLE")


func test_contacts_snapshot_for_diagnostics() -> void:
	_p(PENCIL, 1, BEGIN, 400, 400)
	_p(FINGER, 10, BEGIN, 800, 400)
	_p(PENCIL, 1, MOVE, 410, 405)
	var c := r.contacts()
	assert_eq(c.size(), 2)
	assert_eq(c[1].source, "PENCIL")
	assert_eq(c[1].role, InputRouter.ROLE_PENCIL_TOOL)
	assert_eq(c[1].suppressed, false)
	assert_eq(c[1].start_pos, Vector2(400, 400))
	assert_eq(c[1].last_pos, Vector2(410, 405))
	assert_eq(c[10].source, "FINGER")
	assert_eq(c[10].suppressed, true)


# --- invariants under a long random sequence ---------------------------------------------------

func test_random_sequences_keep_ownership_invariants() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260930
	var live: Dictionary = {}  # id -> source
	var sources := [PENCIL, FINGER, FINGER, FINGER, MOUSE, UNKNOWN]
	var open := {"tool": false, "ui": false, "camera": false}
	var opened := {"tool": 0, "ui": 0, "camera": 0}
	var next_id := 1
	for step in 4000:
		var roll := rng.randi_range(0, 99)
		var actions: Array[Dictionary] = []
		if live.is_empty() or (roll < 25 and live.size() < 3):
			var src: int = sources[rng.randi_range(0, sources.size() - 1)]
			live[next_id] = src
			actions = _p(src, next_id, BEGIN, rng.randf_range(0, 1180), rng.randf_range(0, 820))
			next_id += 1
		elif roll < 75:
			var id: int = live.keys()[rng.randi_range(0, live.size() - 1)]
			actions = _p(live[id], id, MOVE, rng.randf_range(0, 1180), rng.randf_range(0, 820))
		elif roll < 97:
			var id: int = live.keys()[rng.randi_range(0, live.size() - 1)]
			actions = _p(live[id], id, END if roll < 92 else CANCEL, 600, 400)
			live.erase(id)
		elif roll < 98:
			actions = r.cancel_all("explicit")
		else:
			actions = r.set_modal(not r.is_modal())
		if not _check_invariants(actions, live, open, step):
			return
		for a in actions:
			if a.type in ["tool_begin", "ui_press", "camera_orbit_begin", "camera_pan_zoom_begin"]:
				opened[str(a.type).get_slice("_", 0)] += 1
	r.set_modal(false)
	for id: int in live.keys():
		_check_invariants(_p(live[id], id, END, 600, 400), live, open, -1)
	assert_eq(r.state_name(), "IDLE", "all released")
	assert_eq(open, {"tool": false, "ui": false, "camera": false}, "every operation closed")
	for g: String in opened:
		assert_true(opened[g] >= 10, "sequence exercised %s (%d)" % [g, opened[g]])


func _check_invariants(actions: Array[Dictionary], live: Dictionary, open: Dictionary, step: int) -> bool:
	for a in actions:
		var t: String = a.type
		var group := t.get_slice("_", 0)
		if group == "diagnostic":
			continue
		var opening := t in ["tool_begin", "ui_press", "camera_orbit_begin", "camera_pan_zoom_begin"]
		var closing := t in ["tool_end", "tool_cancel", "ui_release", "ui_cancel", "camera_end"]
		if opening and not assert_false(open[group], "step %d: %s while %s open" % [step, t, group]):
			return false
		if not opening and not assert_true(open[group], "step %d: %s without begin" % [step, t]):
			return false
		if opening:
			open[group] = true
		elif closing:
			open[group] = false
		if a.has("sample"):
			var src: int = (a.sample as PointerSample).source
			if not assert_true(src == PENCIL or src == MOUSE, "step %d: %s from source %d" % [step, t, src]):
				return false
		if t == "ui_press":
			var psrc: int = live.get(a.pointer_id, UNKNOWN)
			if not assert_true(psrc == PENCIL or psrc == MOUSE or psrc == FINGER,
					"step %d: ui_press from %d" % [step, psrc]):
				return false
	return true
