class_name ToolChip
extends PanelContainer
## Active-tool chip at the bottom centre (docs/editor-v2.md §9): icon, label (accent, danger colour when
## inverted) and sub text. Tapping it toggles the popover; invertible tools add an Invert button. While
## a Library asset is armed it names the asset instead.

signal tapped()

const HEIGHT := 36.0
const PADDING := 10.0

var _session: EditorSession
var _tools: ToolController
var _main := UiKit.variant_button("", "PillButton", Callable())
var _row := HBoxContainer.new()
var _icon := UiKit.texture_rect(null, Vector2(16, 16))
var _label := UiKit.bold_label("", 12, UiKit.ACCENT)
var _sub := UiKit.label("", 11)
var _invert := UiKit.variant_button("", "InvertButton", Callable(), true)
var _sub_natural := 0.0


func setup(session: EditorSession) -> void:
	_session = session
	_tools = session.tools
	add_theme_stylebox_override("panel", UiKit.pill_box(Color(UiKit.PANEL_BG, 0.88), 12, 3))
	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 2)
	add_child(outer)
	_row.add_theme_constant_override("separation", 8)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sub.add_theme_color_override("font_color", UiKit.TEXT_SECONDARY)
	_sub.clip_text = true
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	for c: Control in [_icon, _label, _sub]:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(c)
	_main.add_child(_row)
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_row.offset_left = PADDING
	_row.offset_right = -PADDING
	_main.pressed.connect(func() -> void: tapped.emit())
	outer.add_child(_main)
	_invert.custom_minimum_size.y = HEIGHT
	_invert.add_theme_font_size_override("font_size", 11)
	_invert.icon = UiKit.icon("swap")
	_invert.add_theme_constant_override("icon_max_width", 14)
	_invert.add_theme_constant_override("h_separation", 6)
	_invert.tooltip_text = "Pencil double-tap (D key on Mac)"
	_invert.pressed.connect(func() -> void: _tools.set_inverted(not _tools.inverted()))
	outer.add_child(_invert)
	refresh(session.status())


func main_button() -> Button:
	return _main


func invert_button() -> Button:
	return _invert


func label_text() -> String:
	return _label.text


func sub_text() -> String:
	return _sub.text


func label_color() -> Color:
	return _label.get_theme_color("font_color")


func refresh(status: Dictionary) -> void:
	if _tools == null:
		return
	var asset := _session.catalog.get_asset(_tools.armed_asset())
	var tool_id := _tools.active_tool()
	var invertible := asset == null and tool_id in ToolModel.INVERT_LABELS
	if asset != null:
		_label.text = asset.display_name
		_sub.text = "tap terrain to place"
		_icon.texture = UiKit.tool_icon("multimesh")
	else:
		_label.text = ToolTexts.chip_label(_tools)
		_sub.text = ToolTexts.chip_sub(_tools)
		_icon.texture = UiKit.tool_icon(ToolTexts.TOOL_ICONS[tool_id])
	_label.add_theme_color_override("font_color", UiKit.DANGER_TEXT if _tools.inverted() else UiKit.ACCENT)
	_invert.visible = invertible
	if invertible:
		_invert.text = str(ToolModel.INVERT_LABELS[tool_id])
		_invert.set_pressed_no_signal(_tools.inverted())
		_invert.disabled = not bool(status.editing_enabled)
	_sub_natural = ceilf(ThemeDB.fallback_font.get_string_size(_sub.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x)
	_apply_width(0.0)


## Shrinks the sub text (ellipsis) so the chip is at most max_w wide.
func fit_width(max_w: float) -> void:
	_apply_width(max_w)


func _apply_width(max_w: float) -> void:
	_sub.custom_minimum_size.x = _sub_natural
	UiKit.fit_content_button(_main, _row, PADDING, HEIGHT)
	reset_size()
	var over := size.x - max_w
	if max_w > 0.0 and over > 0.0:
		_sub.custom_minimum_size.x = maxf(0.0, _sub_natural - over)
		UiKit.fit_content_button(_main, _row, PADDING, HEIGHT)
		reset_size()
