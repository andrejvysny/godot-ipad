class_name ObjectInspector
extends PanelContainer
## v2 object inspector (docs/editor-v2.md §8, §9), anchored next to the selected object by EditorUI:
## header (asset name, first 8 characters of the id), Yaw and Scale rows (minus / value / plus) and
## Duplicate and Delete. Every button is one history action through ToolController.

const GAP := 24.0
const AVOID_MARGIN := 24.0
const STEP_SIZE := Vector2(40, 40)
const VALUE_SIZE := Vector2(92, 40)

var _session: EditorSession
var _tools: ToolController
var _title := UiKit.bold_label("", 11)
var _id := UiKit.label("", 10)
var _rows: Dictionary = {}  # kind -> {minus, plus, value}
var _duplicate: Button
var _delete: Button
var _controls: Array[Control] = []
var _last_choice := -1


func setup(session: EditorSession) -> void:
	_session = session
	_tools = session.tools
	add_theme_stylebox_override("panel", UiKit.pill_box(Color(UiKit.PANEL_BG, 0.94), 12, 6))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
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
	_add_row(column, "yaw", "Yaw", float(steps.yaw_step_deg))
	_add_row(column, "scale", "Scale", float(steps.scale_step))
	column.add_child(_build_actions())
	for signal_ref: Signal in [_tools.tool_changed, _tools.selection_changed, _tools.settings_changed,
			_tools.operation_finished, _tools.operation_cancelled, _session.world_replaced]:
		signal_ref.connect(_on_any_signal)
	refresh()


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


# --- builders ------------------------------------------------------------------------------

func _add_row(parent: Control, kind: String, caption: String, nudge_step: float) -> void:
	var minus := _step_button("minus", _nudge.bind(kind, -nudge_step))
	var plus := _step_button("plus", _nudge.bind(kind, nudge_step))
	var cell := PanelContainer.new()
	cell.add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.VALUE_CELL, 8, 0, false))
	cell.custom_minimum_size = VALUE_SIZE
	var texts := VBoxContainer.new()
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 0)
	var cap := UiKit.bold_label(caption, 10, UiKit.TEXT_MUTED)
	var value := UiKit.label("", 12)
	value.add_theme_font_override("font", UiKit.mono_font())
	for l: Label in [cap, value]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texts.add_child(l)
	cell.add_child(texts)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	for c: Control in [minus, cell, plus]:
		row.add_child(c)
	parent.add_child(row)
	_rows[kind] = {"minus": minus, "plus": plus, "value": value}


func _step_button(icon_name: String, on_pressed: Callable) -> Button:
	var b := UiKit.variant_button("", "StepButton", on_pressed)
	b.custom_minimum_size = STEP_SIZE
	b.icon = UiKit.icon(icon_name)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", 16)
	_controls.append(b)
	return b


func _build_actions() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	_duplicate = UiKit.variant_button("Duplicate", "SurfaceButton", func() -> void: _post(_tools.duplicate_selected()))
	_delete = UiKit.variant_button("Delete", "DangerButton", func() -> void: _post(_tools.delete_selected()))
	for b: Button in [_duplicate, _delete]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 36
		b.add_theme_font_size_override("font_size", 11)
		row.add_child(b)
		_controls.append(b)
	return row


# --- handlers ------------------------------------------------------------------------------

func _post(error: String) -> void:
	if error != "":
		_session.post_message(error, true)


func _nudge(kind: String, delta: float) -> void:
	_post(_tools.nudge(kind, delta))
	refresh()


func on_ui_cancelled(_reason: String) -> void:
	_tools.cancel_object_edit()
	refresh()


# --- API -----------------------------------------------------------------------------------

## kind: yaw | scale
func stepper(kind: String, sign: int) -> Button:
	return _rows[kind].plus if sign > 0 else _rows[kind].minus


func value_text(kind: String) -> String:
	return (_rows[kind].value as Label).text


func title_text() -> String:
	return _title.text


func id_text() -> String:
	return _id.text


func duplicate_button() -> Button:
	return _duplicate


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

func refresh() -> void:
	if _session == null:
		return
	var enabled := _session.input.editing_enabled()
	for c in _controls:
		(c as BaseButton).disabled = not enabled
	var rec := _tools.selected_record()
	if rec == null or _tools.has_object_edit():
		return
	_title.text = _session.catalog.get_asset(rec.asset_id).display_name
	_id.text = rec.object_id.substr(0, 8)
	(_rows.yaw.value as Label).text = "%d°" % roundi(wrapf(rad_to_deg(rec.get_yaw()), -180.0, 180.0))
	(_rows.scale.value as Label).text = "%.1f×" % rec.uniform_scale
	reset_size()
