class_name ContextBar
extends PanelContainer
## Settings of the active tool as a floating flow (spec §9.3): brush modes, scrub fields,
## pressure, snap and a hint line. Only Control signals are used. A scrub drag is one undo
## action; ui_cancelled rolls it back and the synthetic release that follows is a no-op.

const BRUSH_MODES := {
	"paint": {"key": "material", "values": ["grass", "dirt"], "labels": ["Grass", "Dirt"]},
	"sculpt": {"key": "direction", "values": ["raise", "lower"], "labels": ["Raise", "Lower"]},
}
const SWATCHES := {"grass": Color("56aa3e"), "dirt": Color("a8744c")}
const SEPARATION := 10.0

var _session: EditorSession
var _tools: ToolController
var _flow := HFlowContainer.new()
var _items: Dictionary = {}  # tool id -> Array[Control] shown for that tool
var _modes: Dictionary = {}  # tool id -> {value -> Button}
var _scrubs: Dictionary = {}  # "tool.key" -> ScrubField
var _pressure: Dictionary = {}  # tool id -> Button
var _snap: Button
var _chip := UiKit.variant_panel("SubPanel")
var _chip_thumb := TextureRect.new()
var _chip_name := UiKit.bold_label("", 14)
var _hint := UiKit.label("", 12)
var _controls: Array[Control] = []
var _drag: Dictionary = {}  # open scrub drag: field, tool, key, start
var _pressure_available := true


func setup(session: EditorSession) -> void:
	_session = session
	_tools = session.tools
	_flow.add_theme_constant_override("h_separation", int(SEPARATION))
	_flow.add_theme_constant_override("v_separation", int(SEPARATION))
	add_child(_flow)
	_build_brush("paint")
	_build_brush("sculpt")
	_build_path()
	_build_place_chip()
	_snap = UiKit.switch_button("", func(on: bool) -> void: _tools.set_snap_enabled(on))
	_controls.append(_snap)
	_add("place", _snap)
	_add("select", _snap)
	_hint.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = 210
	_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_flow.add_child(_hint)
	for signal_ref: Signal in [_tools.tool_changed, _tools.settings_changed, _tools.operation_finished,
			_tools.operation_cancelled, _tools.operation_started, _session.world_replaced,
			_session.status_changed]:
		signal_ref.connect(_on_any_signal)
	refresh(_session.status())


func _on_any_signal(_a: Variant = null) -> void:
	refresh(_session.status())


func _process(_delta: float) -> void:
	if _session != null and _tools.has_active_operation():
		_update_hint()


# --- builders ------------------------------------------------------------------------------

func _add(tool_id: String, control: Control) -> void:
	if not _items.has(tool_id):
		_items[tool_id] = []
	(_items[tool_id] as Array).append(control)
	if control.get_parent() == null:
		_flow.add_child(control)


func _scrub(tool_id: String, key: String, caption: String, lo: float, hi: float, step: float,
		format: Callable) -> ScrubField:
	var f := ScrubField.new()
	f.caption = caption
	f.min_value = lo
	f.max_value = hi
	f.step = step
	f.formatter = format
	f.value_changed.connect(_on_scrub.bind(f, tool_id, key))
	f.drag_ended.connect(func(_changed: bool) -> void: _drag.clear())
	_scrubs[tool_id + "." + key] = f
	_controls.append(f)
	return f


func _build_brush(tool_id: String) -> void:
	var mode: Dictionary = BRUSH_MODES[tool_id]
	var box := UiKit.variant_panel("SubPanel")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	box.add_child(row)
	var group := ButtonGroup.new()
	var buttons := {}
	for i in 2:
		var value: String = mode.values[i]
		var b := UiKit.variant_button(mode.labels[i], "SegmentButton", _on_mode.bind(tool_id, value), true, 92)
		b.button_group = group
		if SWATCHES.has(value):
			b.icon = _swatch(SWATCHES[value])
		row.add_child(b)
		buttons[value] = b
		_controls.append(b)
	_modes[tool_id] = buttons
	_add(tool_id, box)
	var prefix := tool_id + "_radius_"
	_add(tool_id, _scrub(tool_id, "radius", "Size", float(_session.defaults.brush[prefix + "min_m"]),
			float(_session.defaults.brush[prefix + "max_m"]), 0.5, func(v: float) -> String: return "%.1f m" % v))
	_add(tool_id, _scrub(tool_id, "strength", "Strength", ToolController.STRENGTH_MIN,
			ToolController.STRENGTH_MAX, 0.05, func(v: float) -> String: return "%d%%" % roundi(v * 100.0)))
	var pressure := UiKit.switch_button("Pressure", func(on: bool) -> void: _post(
			_tools.set_setting(tool_id, "pressure_enabled", on)))
	_pressure[tool_id] = pressure
	_controls.append(pressure)
	_add(tool_id, pressure)


func _build_path() -> void:
	var lo := float(_session.defaults.brush.path_width_min_m)
	var hi := float(_session.defaults.brush.path_width_max_m)
	_add("path", _scrub("path", "width", "Width", lo, hi, 0.5, func(v: float) -> String: return "%.1f m" % v))


func _build_place_chip() -> void:
	_chip.custom_minimum_size.y = UiKit.MIN_HEIGHT
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_chip.add_child(row)
	_chip_thumb.custom_minimum_size = Vector2(36, 36)
	_chip_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_chip_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_chip_thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_chip_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_chip_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_chip_thumb)
	row.add_child(_chip_name)
	_add("place", _chip)


static func _swatch(color: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	for y in 14:
		for x in 14:
			var inside := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(7, 7)) <= 6.5
			img.set_pixel(x, y, color if inside else Color(color, 0.0))
	return ImageTexture.create_from_image(img)


# --- handlers ------------------------------------------------------------------------------

func _post(error: String) -> void:
	if error != "":
		_session.post_message(error, true)


func _on_mode(tool_id: String, value: String) -> void:
	_post(_tools.set_setting(tool_id, BRUSH_MODES[tool_id].key, value))
	refresh(_session.status())


func _on_scrub(value: float, field: ScrubField, tool_id: String, key: String) -> void:
	if _drag.is_empty():
		_drag = {"field": field, "tool": tool_id, "key": key, "start": float(field.get_meta("last", value))}
	field.set_meta("last", value)
	_post(_tools.set_setting(tool_id, key, value))


func on_ui_cancelled(_reason: String) -> void:
	if _drag.is_empty():
		return
	var field: ScrubField = _drag.field
	var start: float = _drag.start
	var tool_id: String = _drag.tool
	var key: String = _drag.key
	_drag = {}
	_set_field(field, start)
	_tools.set_setting(tool_id, key, start)
	refresh(_session.status())


# --- API -----------------------------------------------------------------------------------

## value: grass | dirt | raise | lower
func mode_button(tool_id: String, value: String) -> Button:
	return (_modes[tool_id] as Dictionary)[value]


## key: radius | strength (paint, sculpt) or width (path)
func scrub(tool_id: String, key: String) -> ScrubField:
	return _scrubs[tool_id + "." + key]


func pressure_switch(tool_id: String) -> Button:
	return _pressure[tool_id]


func snap_switch() -> Button:
	return _snap


func hint_label() -> Label:
	return _hint


func natural_width() -> float:
	var total := 0.0
	var count := 0
	for child in _flow.get_children():
		var c := child as Control
		if c.visible:
			total += c.get_combined_minimum_size().x
			count += 1
	var margins := get_theme_stylebox("panel").get_minimum_size().x
	return total + SEPARATION * maxi(count - 1, 0) + margins


## Narrows the panel to its content so the flow wraps instead of stretching to max_w.
func fit_width(max_w: float) -> void:
	custom_minimum_size.x = minf(natural_width(), maxf(max_w, 0.0))
	reset_size()


# --- refresh -------------------------------------------------------------------------------

static func _set_field(field: ScrubField, value: float) -> void:
	field.set_value_no_signal(value)
	field.set_meta("last", field.value)


func refresh(status: Dictionary) -> void:
	if _session == null:
		return
	var active := _tools.active_tool()
	_pressure_available = bool(status.pressure_available)
	for id: String in _items:
		for c: Control in _items[id]:
			c.visible = false
	for c: Control in _items.get(active, []):
		c.visible = true
	for id: String in BRUSH_MODES:
		_refresh_brush(id)
	_set_field(scrub("path", "width"), float(_tools.settings("path").width))
	_refresh_place()
	_snap.text = "Snap %d° · %.1f m" % [roundi(float(_session.defaults.placement.yaw_snap_deg)),
			float(_session.defaults.placement.move_snap_m)]
	UiKit.set_switch(_snap, _tools.snap_enabled())
	var enabled := bool(status.editing_enabled)
	for c in _controls:
		if c is BaseButton:
			(c as BaseButton).disabled = not enabled
		elif c is ScrubField:
			(c as ScrubField).editable = enabled
	_update_hint()
	reset_size()


func _refresh_brush(tool_id: String) -> void:
	var s := _tools.settings(tool_id)
	var mode: Dictionary = BRUSH_MODES[tool_id]
	for value: String in mode.values:
		mode_button(tool_id, value).set_pressed_no_signal(value == str(s[mode.key]))
	_set_field(scrub(tool_id, "radius"), float(s.radius))
	_set_field(scrub(tool_id, "strength"), float(s.strength))
	UiKit.set_switch(pressure_switch(tool_id), bool(s.pressure_enabled))


func _refresh_place() -> void:
	var asset := _session.catalog.get_asset(str(_tools.settings("place").get("asset_id", "")))
	_chip_thumb.texture = load(asset.thumbnail) as Texture2D if asset != null else null
	_chip_thumb.visible = asset != null
	_chip_name.text = asset.display_name if asset != null else "No asset"


func _update_hint() -> void:
	if _session == null:
		return
	if _tools.has_active_operation():
		_hint.text = _tools.stroke_state() + "…"
		_hint.add_theme_color_override("font_color", UiKit.TEXT)
		return
	_hint.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	var text := ""
	match _tools.active_tool():
		"select":
			text = "Tap an object to select. Drag it to move."
		"place":
			text = "Touch terrain, drag to position, lift to place." if _chip_thumb.visible \
					else "Drag a tile from the Library onto the terrain."
		"paint", "sculpt":
			text = "Draw on terrain. Lifting ends one undo step."
			if not _pressure_available:
				text += " Pressure unavailable – constant strength."
		"path":
			text = "Paints dirt only · pressure off · objects unchanged."
	_hint.text = text
