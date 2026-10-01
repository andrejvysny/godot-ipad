class_name ObjectInspector
extends PanelContainer
## Transform controls of the selected object, anchored next to it by EditorUI (spec §9.3). A scrub
## drag is one undo action; ui_cancelled rolls it back and the synthetic release that follows is a
## no-op (drag_ended finds nothing open).

const WIDTH := 268.0
const GAP := 24.0
const AVOID_MARGIN := 24.0

var _session: EditorSession
var _tools: ToolController
var _title := UiKit.bold_label("", 16)
var _id := UiKit.label("", 11)
var _rows: Dictionary = {}  # kind -> {field, minus, plus}
var _grounding: Dictionary = {}  # mode -> Button
var _focus: Button
var _delete: Button
var _controls: Array[Control] = []
var _last_choice := -1


func setup(session: EditorSession) -> void:
	_session = session
	_tools = session.tools
	theme_type_variation = "StrongPanel"
	custom_minimum_size.x = WIDTH
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	var head := HBoxContainer.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_id.add_theme_font_override("font", UiKit.mono_font())
	_id.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	head.add_child(_title)
	head.add_child(_id)
	column.add_child(head)
	var steps: Dictionary = session.defaults.placement
	_add_row(column, "yaw", "Yaw", -180.0, 180.0, 1.0, float(steps.yaw_step_deg),
			func(v: float) -> String: return "%d°" % roundi(v))
	_add_row(column, "scale", "Scale", 0.1, 10.0, 0.01, float(steps.scale_step),
			func(v: float) -> String: return "%.2f×" % v)
	_add_row(column, "height", "Height", -5.0, 5.0, 0.05, float(steps.height_step_m),
			func(v: float) -> String: return "%+.2f m" % v)
	column.add_child(_build_grounding())
	column.add_child(_build_actions())
	for signal_ref: Signal in [_tools.tool_changed, _tools.selection_changed, _tools.settings_changed,
			_tools.operation_finished, _tools.operation_cancelled, _session.world_replaced,
			_session.status_changed]:
		signal_ref.connect(_on_any_signal)
	refresh()


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


# --- builders ------------------------------------------------------------------------------

func _add_row(parent: Control, kind: String, caption: String, lo: float, hi: float, step: float,
		nudge_step: float, format: Callable) -> void:
	var field := ScrubField.new()
	field.stacked = true
	field.caption = caption
	field.min_value = lo
	field.max_value = hi
	field.step = step
	field.formatter = format
	field.value_changed.connect(_on_scrub.bind(kind))
	field.drag_ended.connect(func(_changed: bool) -> void: _tools.end_object_edit())
	var minus := _stepper_button("–", _nudge.bind(kind, -nudge_step))
	var plus := _stepper_button("+", _nudge.bind(kind, nudge_step))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for c: Control in [minus, field, plus]:
		row.add_child(c)
		_controls.append(c)
	parent.add_child(row)
	_rows[kind] = {"field": field, "minus": minus, "plus": plus}


static func _stepper_button(text: String, on_pressed: Callable) -> Button:
	var b := UiKit.variant_button(text, "SurfaceButton", on_pressed, false, 48)
	b.add_theme_font_size_override("font_size", 20)
	return b


func _build_grounding() -> Control:
	var box := UiKit.variant_panel("SubPanel")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	box.add_child(row)
	var group := ButtonGroup.new()
	var entries := [[WorldConstants.GROUNDING_FOLLOW, "Follow terrain"], [WorldConstants.GROUNDING_FIXED, "World fixed"]]
	for entry: Array in entries:
		var b := UiKit.variant_button(entry[1], "SegmentButton", _on_grounding.bind(entry[0]), true)
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		_controls.append(b)
		_grounding[entry[0]] = b
	return box


func _build_actions() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_focus = UiKit.variant_button("Focus", "SurfaceButton", func() -> void: _post(_session.focus_selection()))
	_delete = UiKit.variant_button("Delete", "DangerButton", func() -> void: _post(_tools.delete_selected()))
	for b: Button in [_focus, _delete]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		_controls.append(b)
	return row


# --- handlers ------------------------------------------------------------------------------

func _post(error: String) -> void:
	if error != "":
		_session.post_message(error, true)


func _on_scrub(value: float, kind: String) -> void:
	if not _tools.has_object_edit():
		var refused := _tools.begin_object_edit(kind)
		if refused != "":
			_post(refused)
			refresh()
			return
	_post(_tools.update_object_edit(value))
	var rec := _tools.selected_record()
	if rec != null:
		scrub(kind).display_value = _record_value(rec, kind)


func _nudge(kind: String, delta: float) -> void:
	_post(_tools.nudge(kind, delta))
	refresh()


func _on_grounding(mode: String) -> void:
	var rec := _tools.selected_record()
	if rec != null and rec.grounding != mode:
		_post(_tools.set_grounding(mode))
	refresh()


func on_ui_cancelled(_reason: String) -> void:
	_tools.cancel_object_edit()
	refresh()


# --- API -----------------------------------------------------------------------------------

## kind: yaw | scale | height
func scrub(kind: String) -> ScrubField:
	return _rows[kind].field


func stepper(kind: String, sign: int) -> Button:
	return _rows[kind].plus if sign > 0 else _rows[kind].minus


## mode: WorldConstants.GROUNDING_FOLLOW | GROUNDING_FIXED
func grounding_button(mode: String) -> Button:
	return _grounding[mode]


func focus_button() -> Button:
	return _focus


func delete_button() -> Button:
	return _delete


## Anchored beside/below/above the object rect, kept inside `free`; avoids the anchor itself and the
## `avoid` screen points (other objects) when a clear spot exists.
func place(anchor: Rect2, free: Rect2, prefer_right: bool, avoid: PackedVector2Array = PackedVector2Array()) -> void:
	var result := choose_position(anchor, free, get_combined_minimum_size(), prefer_right, avoid, _last_choice)
	position = result[0]
	_last_choice = result[1]


## Candidates: 0 preferred side, 1 other side, 2 below, 3 above, 4/5 the preferred/other side pushed
## past any avoid point the plain side would cover. Returns [position, choice]; choice -1 when `free`
## cannot hold the panel. `last_choice` wins ties so the panel does not flicker.
static func choose_position(anchor: Rect2, free: Rect2, panel: Vector2, prefer_right: bool,
		avoid: PackedVector2Array, last_choice: int) -> Array:
	if free.size.x < panel.x or free.size.y < panel.y:
		return [free.position, -1]
	var right_x := anchor.end.x + GAP
	var left_x := anchor.position.x - GAP - panel.x
	var side_y := anchor.get_center().y - panel.y * 0.5
	var mid_x := anchor.get_center().x - panel.x * 0.5
	var raw: Array[Vector2] = [
		Vector2(right_x if prefer_right else left_x, side_y),
		Vector2(left_x if prefer_right else right_x, side_y),
		Vector2(mid_x, anchor.end.y + GAP),
		Vector2(mid_x, anchor.position.y - GAP - panel.y),
	]
	raw.append(Vector2(_clear_side_x(raw[0].x, prefer_right, panel, side_y, avoid), side_y))
	raw.append(Vector2(_clear_side_x(raw[1].x, not prefer_right, panel, side_y, avoid), side_y))
	var keep_out := anchor.grow(GAP * 0.5)
	var positions: Array[Vector2] = []
	var scores: Array[int] = []
	var best := 1 << 30
	for p in raw:
		var pos := Vector2(clampf(p.x, free.position.x, free.end.x - panel.x),
				clampf(p.y, free.position.y, free.end.y - panel.y))
		var rect := Rect2(pos, panel)
		var score := 1000 if rect.intersects(keep_out) else 0
		var padded := rect.grow(AVOID_MARGIN)
		for point in avoid:
			if padded.has_point(point):
				score += 1
		positions.append(pos)
		scores.append(score)
		best = mini(best, score)
	var choice := last_choice if last_choice >= 0 and last_choice < scores.size() and scores[last_choice] == best \
			else scores.find(best)
	return [positions[choice], choice]


## Moves a side candidate outward until the panel (plus margin) no longer covers avoid points.
static func _clear_side_x(x: float, right: bool, panel: Vector2, y: float, avoid: PackedVector2Array) -> float:
	var padded := Rect2(Vector2(x, y), panel).grow(AVOID_MARGIN)
	var out := x
	for p in avoid:
		if not padded.has_point(p):
			continue
		out = maxf(out, p.x + AVOID_MARGIN + 1.0) if right else minf(out, p.x - AVOID_MARGIN - panel.x - 1.0)
	return out


# --- refresh -------------------------------------------------------------------------------

static func _set_field(field: ScrubField, value: float) -> void:
	field.set_value_no_signal(value)
	field.set_meta("last", field.value)


static func _set_range(field: ScrubField, lo: float, hi: float) -> void:
	if field.min_value != lo or field.max_value != hi:
		field.set_block_signals(true)
		field.min_value = lo
		field.max_value = hi
		field.set_block_signals(false)


static func _record_value(rec: ObjectRecord, kind: String) -> float:
	match kind:
		"yaw":
			return wrapf(rad_to_deg(rec.get_yaw()), -180.0, 180.0)
		"scale":
			return rec.uniform_scale
	return rec.height_offset_m


func refresh() -> void:
	if _session == null:
		return
	var enabled := _session.input.editing_enabled()
	for c in _controls:
		if c is BaseButton:
			(c as BaseButton).disabled = not enabled
		elif c is ScrubField:
			(c as ScrubField).editable = enabled
	var rec := _tools.selected_record()
	if rec == null or _tools.has_object_edit():
		return
	var asset := _session.catalog.get_asset(rec.asset_id)
	_title.text = asset.display_name
	_id.text = rec.object_id.substr(0, 8)
	for mode: String in _grounding:
		(_grounding[mode] as Button).set_pressed_no_signal(rec.grounding == mode)
	_set_range(scrub("scale"), asset.scale_min, asset.scale_max)
	_set_range(scrub("height"), asset.height_offset_min_m, asset.height_offset_max_m)
	for kind: String in _rows:
		_set_field(scrub(kind), _record_value(rec, kind))
		scrub(kind).display_value = NAN
	reset_size()
