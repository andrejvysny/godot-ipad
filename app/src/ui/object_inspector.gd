class_name ObjectInspector
extends PanelContainer
## Transform controls of the selected object, anchored next to it by EditorUI (spec §9.3). A scrub
## drag is one undo action; ui_cancelled rolls it back and the synthetic release that follows is a
## no-op (drag_ended finds nothing open).

const WIDTH := 268.0
const GAP := 24.0

var _session: EditorSession
var _tools: ToolController
var _title := UiKit.bold_label("", 16)
var _id := UiKit.label("", 11)
var _rows: Dictionary = {}  # kind -> {field, minus, plus}
var _grounding: Dictionary = {}  # mode -> Button
var _focus: Button
var _delete: Button
var _controls: Array[Control] = []


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


## Anchored beside the object rect on the preferred side, else the other, kept inside `free`.
func place(anchor: Rect2, free: Rect2, prefer_right: bool) -> void:
	var panel := get_combined_minimum_size()
	if free.size.x < panel.x or free.size.y < panel.y:
		position = free.position
		return
	var right_x := anchor.end.x + GAP
	var left_x := anchor.position.x - GAP - panel.x
	var x := right_x if prefer_right else left_x
	var other := left_x if prefer_right else right_x
	if x < free.position.x or x + panel.x > free.end.x:
		if other >= free.position.x and other + panel.x <= free.end.x:
			x = other
	x = clampf(x, free.position.x, free.end.x - panel.x)
	var y := clampf(anchor.get_center().y - panel.y * 0.5, free.position.y, free.end.y - panel.y)
	position = Vector2(x, y)


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
