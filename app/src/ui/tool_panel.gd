class_name ToolPanel
extends PanelContainer
## Context panel of the active tool (spec §9.3): brush settings or selected-object transform
## controls. Only Control signals are used. A slider drag is one undo action; ui_cancelled rolls
## it back and the synthetic release that follows is a no-op (drag_ended finds nothing open).

const WIDTH := 300.0
const BRUSH_MODES := {
	"paint": {"key": "material", "values": ["grass", "dirt"], "labels": ["Grass", "Dirt"]},
	"sculpt": {"key": "direction", "values": ["raise", "lower"], "labels": ["Raise ▲", "Lower ▼"]},
}

var _session: EditorSession
var _tools: ToolController
var _sections: Dictionary = {}  # tool id -> Control
var _brush: Dictionary = {}  # tool id -> {mode, radius, radius_label, strength, strength_label, pressure, note}
var _width_slider: HSlider
var _width_label: Label
var _snap_buttons: Array[Button] = []
var _controls: Array[Control] = []
var _hint: Label
var _selected_box: VBoxContainer
var _selection_title: Label
var _grounding: Button
var _obj: Dictionary = {}  # kind -> {slider, label, step}
var _drag: Dictionary = {}  # open brush slider drag: slider, tool, key, start


func setup(session: EditorSession) -> void:
	_session = session
	_tools = session.tools
	custom_minimum_size.x = WIDTH
	position = Vector2(140, 52)
	var root := VBoxContainer.new()
	add_child(root)
	_sections["place"] = _build_place()  # snap buttons: place first, then select (see refresh)
	_sections["select"] = _build_select()
	_sections["paint"] = _build_brush("paint")
	_sections["sculpt"] = _build_brush("sculpt")
	_sections["path"] = _build_path()
	for id: String in _sections:
		root.add_child(_sections[id])
	for signal_ref: Signal in [_tools.tool_changed, _tools.selection_changed, _tools.settings_changed,
			_tools.operation_finished, _tools.operation_cancelled, _session.world_replaced,
			_session.status_changed]:
		signal_ref.connect(_on_any_signal)
	refresh()


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


# --- builders ------------------------------------------------------------------------------

func _track(control: Control) -> Control:
	_controls.append(control)
	return control


func _note(text: String) -> Label:
	var l := UiKit.label(text, 15)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = WIDTH - 16
	return l


func _snap_button() -> Button:
	var b := UiKit.button("", func() -> void: _tools.set_snap_enabled(not _tools.snap_enabled()), true)
	_snap_buttons.append(b)
	return _track(b) as Button


func _build_place() -> Control:
	var box := VBoxContainer.new()
	box.add_child(_note("Choose an asset below, then touch the terrain with the Pencil. Drag to position, lift to place."))
	box.add_child(_snap_button())
	return box


func _build_path() -> Control:
	var box := VBoxContainer.new()
	box.add_child(UiKit.label("Dirt path preset", 19))
	_width_label = UiKit.label("")
	box.add_child(_width_label)
	var lo := float(_session.defaults.brush.path_width_min_m)
	var hi := float(_session.defaults.brush.path_width_max_m)
	_width_slider = _setting_slider("path", "width", lo, hi, 0.5)
	box.add_child(_width_slider)
	box.add_child(_note("Paints dirt only · pressure off · objects unchanged"))
	return box


func _setting_slider(tool_id: String, key: String, lo: float, hi: float, step: float) -> HSlider:
	var s := UiKit.slider(lo, hi, step)
	s.value_changed.connect(_on_setting_slider.bind(s, tool_id, key))
	s.drag_ended.connect(func(_changed: bool) -> void: _drag.clear())
	_track(s)
	return s


func _build_brush(tool_id: String) -> Control:
	var box := VBoxContainer.new()
	var mode: Dictionary = BRUSH_MODES[tool_id]
	var row := HBoxContainer.new()
	box.add_child(UiKit.label("Material" if tool_id == "paint" else "Direction"))
	box.add_child(row)
	var group := ButtonGroup.new()
	var buttons := {}
	for i in 2:
		var value: String = mode.values[i]
		var b := UiKit.button(mode.labels[i], _on_mode.bind(tool_id, value), true, 110)
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_track(b))
		buttons[value] = b
	var prefix := tool_id + "_radius_"
	var radius_label := UiKit.label("")
	var radius := _setting_slider(tool_id, "radius", float(_session.defaults.brush[prefix + "min_m"]),
			float(_session.defaults.brush[prefix + "max_m"]), 0.5)
	var strength_label := UiKit.label("")
	var strength := _setting_slider(tool_id, "strength", ToolController.STRENGTH_MIN, ToolController.STRENGTH_MAX, 0.05)
	var pressure := UiKit.button("", _on_pressure.bind(tool_id), true)
	var note := _note("Pressure unavailable — constant strength")
	for node: Control in [radius_label, radius, strength_label, strength, _track(pressure), note]:
		box.add_child(node)
	_brush[tool_id] = {"mode": buttons, "radius": radius, "radius_label": radius_label,
		"strength": strength, "strength_label": strength_label, "pressure": pressure, "note": note}
	return box


func _build_select() -> Control:
	var box := VBoxContainer.new()
	_hint = _note("Tap an object with the Pencil to select it. Drag the selected object to move it.")
	box.add_child(_hint)
	_selected_box = VBoxContainer.new()
	box.add_child(_selected_box)
	_selection_title = UiKit.label("", 17)
	_selected_box.add_child(_selection_title)
	_grounding = UiKit.button("", _on_grounding)
	_selected_box.add_child(_track(_grounding))
	var steps: Dictionary = _session.defaults.placement
	_add_object_row("yaw", "Yaw", -180.0, 180.0, 1.0, float(steps.yaw_step_deg))
	_add_object_row("scale", "Scale", 0.1, 10.0, 0.01, float(steps.scale_step))
	_add_object_row("height", "Height", -5.0, 5.0, 0.05, float(steps.height_step_m))
	_selected_box.add_child(_snap_button())
	var actions := HBoxContainer.new()
	var focus := UiKit.button("Focus", func() -> void: _post(_session.focus_selection()), false, 110)
	var delete := UiKit.button("Delete", func() -> void: _post(_tools.delete_selected()), false, 110)
	for b: Button in [focus, delete]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(_track(b))
	_selected_box.add_child(actions)
	return box


func _add_object_row(kind: String, title: String, lo: float, hi: float, step: float, nudge_step: float) -> void:
	var label := UiKit.label(title)
	var slider := UiKit.slider(lo, hi, step)
	slider.value_changed.connect(_on_object_slider.bind(kind))
	slider.drag_ended.connect(func(_changed: bool) -> void: _tools.end_object_edit())
	var row := HBoxContainer.new()
	var minus := UiKit.button("−", _nudge.bind(kind, -nudge_step), false, 48)
	var plus := UiKit.button("+", _nudge.bind(kind, nudge_step), false, 48)
	for c: Control in [minus, slider, plus]:
		row.add_child(_track(c))
	_selected_box.add_child(label)
	_selected_box.add_child(row)
	_obj[kind] = {"slider": slider, "label": label, "title": title}


# --- handlers ------------------------------------------------------------------------------

func _post(error: String) -> void:
	if error != "":
		_session.post_message(error, true)


func _on_mode(tool_id: String, value: String) -> void:
	_post(_tools.set_setting(tool_id, BRUSH_MODES[tool_id].key, value))
	refresh()


func _on_pressure(tool_id: String) -> void:
	_post(_tools.set_setting(tool_id, "pressure_enabled", not bool(_tools.settings(tool_id).pressure_enabled)))


func _on_setting_slider(value: float, slider: HSlider, tool_id: String, key: String) -> void:
	if _drag.is_empty():
		_drag = {"slider": slider, "tool": tool_id, "key": key, "start": float(slider.get_meta("last", value))}
	slider.set_meta("last", value)
	_post(_tools.set_setting(tool_id, key, value))


func _on_object_slider(value: float, kind: String) -> void:
	if not _tools.has_object_edit():
		var refused := _tools.begin_object_edit(kind)
		if refused != "":
			_post(refused)
			refresh()
			return
	_post(_tools.update_object_edit(value))
	_refresh_object_labels()


func _nudge(kind: String, delta: float) -> void:
	_post(_tools.nudge(kind, delta))
	refresh()


func _on_grounding() -> void:
	var rec := _tools.selected_record()
	if rec != null:
		var other := WorldConstants.GROUNDING_FIXED if rec.grounding == WorldConstants.GROUNDING_FOLLOW \
				else WorldConstants.GROUNDING_FOLLOW
		_post(_tools.set_grounding(other))
	refresh()


func on_ui_cancelled(_reason: String) -> void:
	if not _drag.is_empty():
		var slider: HSlider = _drag.slider
		var start: float = _drag.start
		var tool_id: String = _drag.tool
		var key: String = _drag.key
		_drag = {}
		_set_slider(slider, start)
		_tools.set_setting(tool_id, key, start)
	_tools.cancel_object_edit()
	refresh()


func mode_button(tool_id: String, value: String) -> Button:
	return (_brush[tool_id].mode as Dictionary)[value]


## key: radius | strength
func brush_slider(tool_id: String, key: String) -> HSlider:
	return _brush[tool_id][key]


## kind: yaw | scale | height
func object_slider(kind: String) -> HSlider:
	return _obj[kind].slider


# --- refresh -------------------------------------------------------------------------------

static func _set_slider(slider: HSlider, value: float) -> void:
	slider.set_value_no_signal(value)
	slider.set_meta("last", slider.value)


func refresh() -> void:
	if _session == null:
		return
	var active := _tools.active_tool()
	for id: String in _sections:
		(_sections[id] as Control).visible = id == active
	var selected := _tools.selected_id() != ""
	_hint.visible = not selected
	_selected_box.visible = selected
	var snap := "ON" if _tools.snap_enabled() else "OFF"
	var move_snap := float(_session.defaults.placement.move_snap_m)
	_snap_buttons[0].text = "Snap %.1f m: %s" % [move_snap, snap]
	_snap_buttons[1].text = "Snap: yaw %d° / move %.1f m: %s" % [
		roundi(float(_session.defaults.placement.yaw_snap_deg)), move_snap, snap]
	for b in _snap_buttons:
		b.set_pressed_no_signal(_tools.snap_enabled())
	for id: String in _brush:
		_refresh_brush(id)
	_refresh_path()
	_refresh_selection()
	var enabled := _session.input.editing_enabled()
	for c in _controls:
		if c is BaseButton:
			(c as BaseButton).disabled = not enabled
		elif c is Slider:
			(c as Slider).editable = enabled
	reset_size()


func _refresh_brush(tool_id: String) -> void:
	var w: Dictionary = _brush[tool_id]
	var s := _tools.settings(tool_id)
	var mode: Dictionary = BRUSH_MODES[tool_id]
	var chosen := str(s[mode.key])
	for i in 2:
		var b: Button = (w.mode as Dictionary)[mode.values[i]]
		b.set_pressed_no_signal(mode.values[i] == chosen)
		b.text = ("● " if mode.values[i] == chosen else "") + str(mode.labels[i])
	_set_slider(w.radius, float(s.radius))
	_set_slider(w.strength, float(s.strength))
	(w.radius_label as Label).text = "Radius %.1f m" % float(s.radius)
	(w.strength_label as Label).text = "Strength %d%%" % roundi(float(s.strength) * 100.0)
	var pressure_on := bool(s.pressure_enabled)
	(w.pressure as Button).text = "Pressure: " + ("ON" if pressure_on else "OFF")
	(w.pressure as Button).set_pressed_no_signal(pressure_on)
	(w.note as Label).visible = not _pressure_available()


func _pressure_available() -> bool:
	return bool(_session.input.active_provider().capabilities().get("pressure", false))


func _refresh_path() -> void:
	var width := float(_tools.settings("path").width)
	_set_slider(_width_slider, width)
	_width_label.text = "Width %.1f m" % width


func _refresh_selection() -> void:
	var rec := _tools.selected_record()
	if rec == null or _tools.has_object_edit():
		_refresh_object_labels()
		return
	var asset := _session.catalog.get_asset(rec.asset_id)
	_selection_title.text = "%s · %s" % [asset.display_name, rec.object_id.substr(0, 8)]
	_grounding.text = "Grounding: Follow terrain" if rec.grounding == WorldConstants.GROUNDING_FOLLOW \
			else "Grounding: World fixed"
	_set_range(_obj.scale.slider, asset.scale_min, asset.scale_max)
	_set_range(_obj.height.slider, asset.height_offset_min_m, asset.height_offset_max_m)
	_set_slider(_obj.yaw.slider, _record_value(rec, "yaw"))
	_set_slider(_obj.scale.slider, _record_value(rec, "scale"))
	_set_slider(_obj.height.slider, _record_value(rec, "height"))
	_refresh_object_labels()


static func _set_range(slider: HSlider, lo: float, hi: float) -> void:
	if slider.min_value != lo or slider.max_value != hi:
		slider.set_block_signals(true)
		slider.min_value = lo
		slider.max_value = hi
		slider.set_block_signals(false)


static func _record_value(rec: ObjectRecord, kind: String) -> float:
	match kind:
		"yaw":
			return wrapf(rad_to_deg(rec.get_yaw()), -180.0, 180.0)
		"scale":
			return rec.uniform_scale
	return rec.height_offset_m


func _refresh_object_labels() -> void:
	var rec := _tools.selected_record()
	if rec == null:
		return
	(_obj.yaw.label as Label).text = "Yaw %d°" % roundi(_record_value(rec, "yaw"))
	(_obj.scale.label as Label).text = "Scale %.2f" % _record_value(rec, "scale")
	(_obj.height.label as Label).text = "Height %+.2f m" % _record_value(rec, "height")
