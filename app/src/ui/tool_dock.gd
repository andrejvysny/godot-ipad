class_name ToolDock
extends PanelContainer
## Floating column of the five tools (spec §9.3). The tool controller owns the active tool.

const ORDER: Array[String] = ["select", "place", "sculpt", "paint", "path"]
const CAPTIONS := {"select": "Select", "place": "Place", "sculpt": "Sculpt", "paint": "Paint", "path": "Path"}
const TILE := Vector2(68, 64)

var _session: EditorSession
var _buttons: Dictionary = {}  # tool id -> Button


func setup(session: EditorSession) -> void:
	_session = session
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	add_child(column)
	var group := ButtonGroup.new()
	for id in ORDER:
		var b := UiKit.button(CAPTIONS[id], _choose.bind(id), true)
		b.theme_type_variation = "ToolTile"
		b.custom_minimum_size = TILE
		b.button_group = group
		b.icon = UiKit.icon("tool_" + id)
		b.expand_icon = false
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.add_theme_font_override("font", UiKit.bold_font())
		b.add_theme_color_override("icon_normal_color", UiKit.TOOL_TEXT)
		b.add_theme_color_override("icon_hover_color", UiKit.TOOL_TEXT)
		b.add_theme_color_override("icon_pressed_color", UiKit.ACCENT)
		b.add_theme_color_override("icon_hover_pressed_color", UiKit.ACCENT)
		column.add_child(b)
		_buttons[id] = b


func tool_button(id: String) -> Button:
	return _buttons[id]


func refresh(status: Dictionary) -> void:
	var editing := bool(status.editing_enabled)
	for id: String in _buttons:
		var b: Button = _buttons[id]
		b.set_pressed_no_signal(id == status.tool)
		b.disabled = not editing


func _choose(id: String) -> void:
	var error := _session.tools.set_active_tool(id)
	if error != "":
		_session.post_message(error, true)
	refresh(_session.status())
