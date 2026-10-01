class_name ToolPopover
extends PanelContainer
## Tool popover of the mode rail (docs/editor-v2.md §9): tool grid plus the sections of the active tool
## (swatches, flatten target, scatter source, scrubs, brush alpha, switches, actions, auto-paint rules,
## hint). Closes when a world operation starts. Controls react to Godot GUI events only; a scrub drag
## is one run of setting changes and ui_cancelled restores its start value.

signal opened_changed(open: bool)
signal change_requested(source: String)
signal edit_set_requested(source: String)

const WIDTH := 272.0
const MAX_HEIGHT := 700.0
const PADDING := 10.0

var _session: EditorSession
var _tools: ToolController
var _scroll := ScrollContainer.new()
var _column := VBoxContainer.new()
var _title := UiKit.bold_label("", 10, UiKit.TEXT_MUTED)
var _grid := GridContainer.new()
var _tiles: Dictionary = {}  # tool id -> Button
var _sections: Dictionary = {}  # section id -> Control
var _scrubs: Dictionary = {}  # size | strength | width -> ScrubField
var _hint := UiKit.label("", 10)
var _controls: Array[Control] = []
var _max_height := MAX_HEIGHT
var _open := false
var _drag: Dictionary = {}  # open scrub drag: field, ns, key, start
var _awaiting_pick := false
var _reopen_after_op := false


func setup(session: EditorSession) -> void:
	_session = session
	_tools = session.tools
	var box := UiKit.pill_box(UiKit.PANEL_BG_POPOVER, 14, int(PADDING))
	box.shadow_size = 12
	box.shadow_color = Color(0, 0, 0, 0.35)
	add_theme_stylebox_override("panel", box)
	custom_minimum_size.x = WIDTH
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_column.add_theme_constant_override("separation", 10)
	_scroll.add_child(_column)
	add_child(_scroll)
	_column.add_child(_build_header())
	_build_grid()
	_build_sections()
	_hint.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = WIDTH - PADDING * 2.0 - 12.0
	_column.add_child(_hint)
	_connect_signals()
	visible = false
	refresh()


func _connect_signals() -> void:
	for signal_ref: Signal in [_tools.tool_changed, _tools.settings_changed, _tools.selection_changed,
			_tools.path_selection_changed, _session.world_replaced, _session.status_changed]:
		signal_ref.connect(_on_any_signal)
	_tools.operation_started.connect(_on_operation_started)
	for signal_ref: Signal in [_tools.operation_finished, _tools.operation_cancelled]:
		signal_ref.connect(_on_operation_ended)
	_tools.dismissed.connect(func() -> void: set_open(false))
	_tools.tool_changed.connect(func(_id: String) -> void: _awaiting_pick = false)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_title)
	row.add_child(UiKit.bold_label("closes when you draw", 10, UiKit.TEXT_FAINT))
	return row


func _build_grid() -> void:
	_grid.columns = 5
	_grid.add_theme_constant_override("h_separation", 3)
	_grid.add_theme_constant_override("v_separation", 3)
	for mode: String in ToolModel.MODES:
		for id: String in ToolModel.TOOLS_BY_MODE[mode]:
			var b := UiKit.variant_button(ToolTexts.tool_label(id), "PopTile", _pick_tool.bind(id), true)
			b.custom_minimum_size = Vector2(0, 50)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.icon = UiKit.tool_icon(ToolTexts.TOOL_ICONS[id])
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
			b.add_theme_constant_override("h_separation", 3)
			_grid.add_child(b)
			_tiles[id] = b
			_controls.append(b)
	_column.add_child(_grid)


func _build_sections() -> void:
	var layers := SwatchRow.new()
	layers.setup("Texture layer", ToolTexts.LAYER_NAMES, ToolTexts.LAYER_COLORS, _pick_swatch.bind("layer"))
	var tints := SwatchRow.new()
	tints.setup("Tint colour", ToolTexts.TINT_NAMES, ToolTexts.TINT_COLORS, _pick_swatch.bind("tint"))
	var height := HeightTargetRow.new()
	height.pick_pressed.connect(_on_pick_height)
	var source := SourceCard.new()
	source.change_requested.connect(func() -> void: change_requested.emit(_source()))
	source.edit_requested.connect(func() -> void: edit_set_requested.emit(_source()))
	var alpha := BrushAlphaSection.new()
	alpha.setup(_session)
	var rules := RulesSection.new()
	rules.setup(_session)
	var pressure := UiKit.switch_button("", func(on: bool) -> void: _post(_tools.set_setting("brush", "pressure_enabled", on)), true)
	var avoid := UiKit.switch_button("Keep clear of placed objects", func(on: bool) -> void:
			_post(_tools.set_setting("scatter", "avoid_objects", on)), true)
	var snap := UiKit.switch_button("Snap move to %s m" % ToolTexts.format_density(
			float(_session.defaults.placement.move_snap_m)), func(on: bool) -> void: _tools.set_snap_enabled(on), true)
	var delete_path := UiKit.variant_button("Delete selected path", "SurfaceButton", func() -> void:
			_post(_tools.delete_selected_path()))
	delete_path.add_theme_color_override("font_color", UiKit.DANGER_TEXT)
	delete_path.add_theme_color_override("font_hover_color", UiKit.DANGER_TEXT)
	var by_id := {"swatches": layers, "tints": tints, "height": height, "source": source, "size": _make_scrub("size"),
			"strength": _make_scrub("strength"), "width": _make_scrub("width"), "alpha": alpha, "pressure": pressure,
			"avoid": avoid, "snap": snap, "delete_path": delete_path, "rules": rules}
	for id: String in ToolTexts.ALL_SECTIONS:
		var c: Control = by_id[id]
		if c is Button:
			c.custom_minimum_size.y = ScrubField.HEIGHT
			_controls.append(c)
		_sections[id] = c
		_column.add_child(c)
	for id: String in ["swatches", "tints"]:
		for i in (_sections[id] as SwatchRow).count():
			_controls.append((_sections[id] as SwatchRow).swatch(i))


func _make_scrub(kind: String) -> ScrubField:
	var f := ScrubField.new()
	f.value_changed.connect(_on_scrub.bind(f, kind))
	f.drag_ended.connect(func(_changed: bool) -> void: _drag.clear())
	_scrubs[kind] = f
	return f


# --- handlers ------------------------------------------------------------------------------

func _post(error: String) -> void:
	if error != "":
		_session.post_message(error, true)


func _pick_tool(tool_id: String) -> void:
	_tools.disarm()
	_post(_tools.set_tool(tool_id))
	refresh()


func _pick_swatch(index: int, key: String) -> void:
	_post(_tools.set_setting("paint", key, index))
	refresh()


func _on_pick_height() -> void:
	var err := _tools.begin_height_pick()
	if err != "":
		_post(err)
		refresh()
		return
	_awaiting_pick = true
	set_open(false)
	_session.post_message("Tap the terrain to sample its height")


func _source() -> String:
	return str(_tools.settings("scatter").source)


## ns/key a scrub kind writes in the current mode: Size and Strength use the mode namespace.
func _target(kind: String) -> Array[String]:
	var out: Array[String] = ["path", "width"]
	if kind != "width":
		out = [_tools.mode(), "radius" if kind == "size" else "strength"]
	return out


func _on_scrub(value: float, field: ScrubField, kind: String) -> void:
	var target := _target(kind)
	if _drag.is_empty():
		_drag = {"field": field, "ns": target[0], "key": target[1],
				"start": float(field.get_meta("last", value))}
	field.set_meta("last", value)
	_post(_tools.set_setting(target[0], target[1], value))


func on_ui_cancelled(_reason: String = "") -> void:
	(_sections.rules as RulesSection).on_ui_cancelled()
	if _drag.is_empty():
		return
	var field: ScrubField = _drag.field
	var start: float = _drag.start
	var ns: String = _drag.ns
	var key: String = _drag.key
	_drag = {}
	_set_field(field, start)
	_tools.set_setting(ns, key, start)
	refresh()


func _on_any_signal(arg: Variant = null) -> void:
	if _awaiting_pick and not _tools.is_picking_height() and typeof(arg) == TYPE_STRING and arg == ToolModel.TOOL_FLATTEN:
		_awaiting_pick = false
		set_open(true)
	refresh()


func _on_operation_started(tool_id: String) -> void:
	_reopen_after_op = tool_id == "pick"
	set_open(false)


func _on_operation_ended(_arg: Variant = null) -> void:
	if _reopen_after_op:
		_reopen_after_op = false
		set_open(true)


# --- open state and API --------------------------------------------------------------------

func is_open() -> bool:
	return _open


func set_open(on: bool) -> void:
	if on == _open:
		return
	_open = on
	visible = on
	if on:
		refresh()
	opened_changed.emit(on)


func toggle() -> void:
	set_open(not _open)


func set_max_height(h: float) -> void:
	_max_height = minf(h, MAX_HEIGHT)
	_fit_height()


func tool_tile(tool_id: String) -> Button:
	return _tiles[tool_id]


func title_text() -> String:
	return _title.text


func hint_text() -> String:
	return _hint.text


## Section ids: swatches, tints, height, source, size, strength, width, alpha, pressure, avoid, snap,
## delete_path, rules.
func section(id: String) -> Control:
	return _sections[id]


func shown_sections() -> Array[String]:
	var out: Array[String] = []
	for id: String in ToolTexts.ALL_SECTIONS:
		if (_sections[id] as Control).visible:
			out.append(id)
	return out


## kind: size | strength | width
func scrub(kind: String) -> ScrubField:
	return _scrubs[kind]


func visible_tool_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in _tiles:
		if (_tiles[id] as Button).visible:
			out.append(id)
	return out


# --- refresh -------------------------------------------------------------------------------

static func _set_field(field: ScrubField, value: float) -> void:
	field.set_value_no_signal(value)
	field.set_meta("last", field.value)


static func _set_range(field: ScrubField, lo: float, hi: float, step: float) -> void:
	if field.min_value != lo or field.max_value != hi or field.step != step:
		field.set_block_signals(true)
		field.min_value = lo
		field.max_value = hi
		field.step = step
		field.set_block_signals(false)


func refresh() -> void:
	if _session == null or _session.document == null:
		return
	var tool_id := _tools.active_tool()
	_title.text = "%s TOOLS" % str(ToolTexts.MODE_LABELS[_tools.mode()]).to_upper()
	for id: String in _tiles:
		var b: Button = _tiles[id]
		b.visible = id in (ToolModel.TOOLS_BY_MODE[_tools.mode()] as Array)
		b.set_pressed_no_signal(id == tool_id)
	var shown: Array = ToolTexts.SECTIONS[tool_id]
	for id: String in ToolTexts.ALL_SECTIONS:
		var on := id in shown
		if id == "delete_path":
			on = on and _tools.selected_path_id() != ""
		(_sections[id] as Control).visible = on
	_refresh_values()
	var editing := _session.input.editing_enabled()
	for c in _controls:
		(c as BaseButton).disabled = not editing
	_hint.text = _hint_text(tool_id)
	if _open:
		_fit_height()
		_fit_height.call_deferred()  # wrapped text settles after the layout pass


func _hint_text(tool_id: String) -> String:
	var text: String = ToolTexts.HINTS[tool_id]
	if "pressure" in (ToolTexts.SECTIONS[tool_id] as Array) and not bool(_session.input.active_provider().capabilities().get("pressure", false)):
		text += " Pressure unavailable: constant strength."
	return text


func _refresh_values() -> void:
	var paint := _tools.settings("paint")
	(_sections.swatches as SwatchRow).set_selected(int(paint.layer))
	(_sections.tints as SwatchRow).set_selected(int(paint.tint))
	(_sections.height as HeightTargetRow).set_target(float(_tools.settings("flatten").target), _tools.is_picking_height())
	(_sections.source as SourceCard).set_config(_source(), _tools.scatter_config())
	_refresh_scrubs()
	UiKit.set_switch(_sections.pressure, bool(_tools.settings("brush").pressure_enabled))
	(_sections.pressure as Button).text = "Pressure to flow" if _tools.mode() == "place" else "Pressure to strength"
	UiKit.set_switch(_sections.avoid, bool(_tools.settings("scatter").avoid_objects))
	UiKit.set_switch(_sections.snap, _tools.snap_enabled())
	(_sections.alpha as BrushAlphaSection).refresh()
	(_sections.rules as RulesSection).refresh()


func _refresh_scrubs() -> void:
	var mode := _tools.mode()
	var s := _tools.settings(mode)
	var radius := Vector2(ToolSettings.PLACE_RADIUS_MIN, ToolSettings.PLACE_RADIUS_MAX)
	if mode != "place":
		radius = Vector2(float(_session.defaults.brush[mode + "_radius_min_m"]), float(_session.defaults.brush[mode + "_radius_max_m"]))
	var size_field := scrub("size")
	_config(size_field, "Size", radius.x, radius.y, 0.5, func(v: float) -> String: return "%.1f m" % v)
	_config(scrub("strength"), "Flow" if mode == "place" else "Strength", ToolSettings.STRENGTH_MIN,
			ToolSettings.STRENGTH_MAX, 0.05, func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	var width := ToolSettings.width_limits(_session.defaults.brush)
	_config(scrub("width"), "Width", width.x, width.y, 0.1,
			func(v: float) -> String: return "%.1f m" % v)
	_set_field(size_field, float(s.radius))
	_set_field(scrub("strength"), float(s.strength))
	_set_field(scrub("width"), float(_tools.settings("path").width))


static func _config(field: ScrubField, caption: String, lo: float, hi: float, step: float, format: Callable) -> void:
	field.caption = caption
	field.formatter = format
	_set_range(field, lo, hi, step)


func _fit_height() -> void:
	var wanted := minf(_column.get_combined_minimum_size().y, _max_height - PADDING * 2.0 - 2.0)
	if absf(wanted - _scroll.custom_minimum_size.y) < 0.5:
		return
	_scroll.custom_minimum_size.y = wanted
	reset_size()
