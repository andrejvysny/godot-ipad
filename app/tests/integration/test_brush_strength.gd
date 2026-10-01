extends TestCase
## Sculpt strength with default settings and Pencil pressure, plus the stroke probe (ctx.last_stroke).

const X := 40.0
const Z := 40.0
const PRESSURE := 0.25

var h: ToolHarness


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness setup")
	h.ctrl.set_active_tool(ToolController.TOOL_SCULPT)


func after_each() -> void:
	h.teardown()


func _pressed(x: float, t: float) -> PointerSample:
	var s := h.at(x, Z, t)
	s.pressure_valid = true
	s.pressure = PRESSURE
	return s


func _centre_height() -> float:
	return h.doc.get_height_at_sample(roundi(X * 2.0), roundi(Z * 2.0))


## Holds (x1 == x0) or drags from x0 to x1 over exactly 1 s of 60 Hz frames; returns the rise at the hold centre.
func _stroke(x0: float, x1: float) -> float:
	var before := h.doc.get_height_at_sample(roundi(x0 * 2.0), roundi(Z * 2.0))
	var t0 := 1.0
	h.act("tool_begin", _pressed(x0, t0))
	var frames := 60
	for i in range(1, frames + 1):
		var t := t0 + float(i) / float(frames)
		h.act("tool_move", _pressed(lerpf(x0, x1, float(i) / float(frames)), t))
		h.ctrl.advance(t)
	h.act("tool_end", _pressed(x1, t0 + 1.0))
	return h.doc.get_height_at_sample(roundi(x0 * 2.0), roundi(Z * 2.0)) - before


func _expected_rise() -> float:
	var brush: Dictionary = h.ctx.defaults.brush
	var pf := BrushMath.pressure_factor(true, PRESSURE, true, float(brush.pressure_min_factor),
			float(brush.get("pressure_gamma", 1.0)))
	return float(brush.sculpt_speed_m_per_s) * float(h.ctrl.settings("sculpt").strength) * pf * 1.0


func test_stationary_hold_rises_by_speed_strength_pressure() -> void:
	var rise := _stroke(X, X)
	var expected := _expected_rise()
	assert_true(expected > 0.0)
	assert_near(rise, expected, expected * 0.05, "centre rise %f vs %f" % [rise, expected])
	var st := h.ctx.last_stroke
	assert_eq(st.result, "committed")
	assert_true(st.peak_dh_m > 0.0, "peak_dh_m")
	assert_true(st.steps > 0, "steps")
	assert_near(st.pressure_avg, PRESSURE, 1e-6)


func test_moving_stroke_deposits_less_than_hold() -> void:
	var hold := _stroke(X, X)
	var hold_peak: float = h.ctx.last_stroke.peak_dh_m
	h.teardown()
	before_each()
	var moved := _stroke(X - 10.0, X + 10.0)
	assert_true(moved < hold, "moving centre rise %f < hold %f" % [moved, hold])
	assert_true(h.ctx.last_stroke.peak_dh_m < hold_peak, "moving peak below hold peak")


func test_cancelled_stroke_reports_cancelled() -> void:
	h.act("tool_begin", _pressed(X, 1.0))
	h.ctrl.advance(1.2)
	h.ctrl.handle_tool_action({"type": "tool_cancel", "reason": "explicit"})
	assert_eq(h.ctx.last_stroke.result, "cancelled")
	assert_near(h.ctx.last_stroke.peak_dh_m, 0.0, 0.0)
