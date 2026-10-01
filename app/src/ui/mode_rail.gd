class_name ModeRail
extends PanelContainer
## Left rail of three 52 x 52 mode tiles (docs/editor-v2.md §9). Tapping the active mode toggles the
## tool popover; another mode switches to it and opens the popover.

const TILE := Vector2(52, 52)

var _session: EditorSession
var _popover: ToolPopover
var _tiles: Dictionary = {}  # mode -> Button


func setup(session: EditorSession, popover: ToolPopover) -> void:
	_session = session
	_popover = popover
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.PANEL_BG, 14, 4))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	add_child(column)
	for mode: String in ToolModel.MODES:
		var b := UiKit.variant_button(ToolTexts.MODE_LABELS[mode], "ModeTile", _pressed.bind(mode), true)
		b.custom_minimum_size = TILE
		b.icon = UiKit.tool_icon(ToolTexts.MODE_ICONS[mode])
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.add_theme_constant_override("h_separation", 3)
		column.add_child(b)
		_tiles[mode] = b
	refresh(session.status())


func tile(mode: String) -> Button:
	return _tiles[mode]


func _pressed(mode: String) -> void:
	if mode == _session.tools.mode():
		_popover.toggle()
	else:
		_session.tools.disarm()
		var err := _session.tools.set_mode(mode)
		if err != "":
			_session.post_message(err, true)
		else:
			_popover.set_open(true)
	refresh(_session.status())


func refresh(status: Dictionary) -> void:
	var enabled := bool(status.editing_enabled)
	for mode: String in _tiles:
		var b: Button = _tiles[mode]
		b.set_pressed_no_signal(mode == str(status.mode))
		b.disabled = not enabled
