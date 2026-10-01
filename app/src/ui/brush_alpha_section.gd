class_name BrushAlphaSection
extends VBoxContainer
## Brush alpha of the tool popover (docs/editor-v2.md §3, §9): six shape tiles with alpha previews,
## the Circle / Stamp / Pattern segmented control and the mode hint. Writes the shared `brush` settings.

const PREVIEW_PX := 48

var _session: EditorSession
var _tiles: Dictionary = {}  # shape -> Button
var _modes: Dictionary = {}  # alpha mode -> Button
var _hint := UiKit.label("", 10)


func setup(session: EditorSession) -> void:
	_session = session
	add_theme_constant_override("separation", 6)
	add_child(UiKit.bold_label("Brush alpha · shared by all tools", 10, UiKit.TEXT_MUTED))
	var grid := GridContainer.new()
	grid.columns = BrushAlpha.SHAPES.size()
	grid.add_theme_constant_override("h_separation", 4)
	add_child(grid)
	for shape in BrushAlpha.SHAPES:
		var b := UiKit.variant_button("", "AlphaTile", _choose.bind("shape", shape), true)
		b.custom_minimum_size = Vector2(36, 38)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.icon = ImageTexture.create_from_image(BrushAlpha.preview_image(shape, "circle", PREVIEW_PX))
		b.expand_icon = false
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", 30)
		b.tooltip_text = BrushAlpha.SHAPE_LABELS[shape]
		grid.add_child(b)
		_tiles[shape] = b
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.SURFACE, 8, 2, false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	box.add_child(row)
	for mode in BrushAlpha.MODES:
		var b := UiKit.variant_button(BrushAlpha.MODE_LABELS[mode], "SegmentButton", _choose.bind("alpha_mode", mode), true)
		b.custom_minimum_size.y = 30
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 11)
		row.add_child(b)
		_modes[mode] = b
	add_child(box)
	_hint.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_hint)


func _choose(key: String, value: String) -> void:
	var err := _session.tools.set_setting("brush", key, value)
	if err != "":
		_session.post_message(err, true)
	refresh()


func tile(shape: String) -> Button:
	return _tiles[shape]


func mode_button(mode: String) -> Button:
	return _modes[mode]


func hint_text() -> String:
	return _hint.text


func refresh() -> void:
	var brush := _session.tools.settings("brush")
	for shape: String in _tiles:
		(_tiles[shape] as Button).set_pressed_no_signal(shape == brush.shape)
	for mode: String in _modes:
		(_modes[mode] as Button).set_pressed_no_signal(mode == brush.alpha_mode)
	_hint.text = str(ToolTexts.ALPHA_HINTS[brush.alpha_mode])
