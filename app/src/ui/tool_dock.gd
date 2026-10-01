class_name ToolDock
extends PanelContainer
## Floating column of the five tools (spec §9.3). The tool controller owns the active tool.

const ORDER: Array[String] = ["select", "place", "sculpt", "paint", "path"]
const CAPTIONS := {"select": "Select", "place": "Place", "sculpt": "Sculpt", "paint": "Paint", "path": "Path"}
const TILE := Vector2(68, 64)

var _session: EditorSession
## Dock id -> tool id; "place" arms the last Library asset instead of switching tool.
const TOOL_OF := {"select": "select", "sculpt": "raise", "paint": "paint", "path": "path"}

var _buttons: Dictionary = {}  # dock id -> Button
var _asset := ""  # asset the Place button arms: the last one armed, else the first catalog asset


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
		if status.armed_asset != "":
			_asset = status.armed_asset
		b.set_pressed_no_signal(_pressed_id(status) == id)
		b.disabled = not editing


func _pressed_id(status: Dictionary) -> String:
	if status.armed_asset != "":
		return "place"
	for id: String in TOOL_OF:
		if TOOL_OF[id] == status.tool:
			return id
	return ""


func _choose(id: String) -> void:
	var error := ""
	if id == "place":
		error = _arm()
	else:
		_session.tools.disarm()
		error = _session.tools.set_tool(TOOL_OF[id])
	if error != "":
		_session.post_message(error, true)
	refresh(_session.status())


func _arm() -> String:
	if _session.tools.armed_asset() != "":
		_session.tools.disarm()
		return ""
	if _asset == "":
		_asset = _session.catalog.sorted_ids()[0]
	return _session.tools.arm_asset(_asset)
