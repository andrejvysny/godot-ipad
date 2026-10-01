class_name AssetStrip
extends PanelContainer
## Collapsible asset palette (spec §9.4). Choosing a tile selects the placement asset and
## switches to the Place tool; the tool controller owns the setting.

var _session: EditorSession
var _toggle: Button
var _tiles := HBoxContainer.new()
var _buttons: Dictionary = {}


func setup(session: EditorSession) -> void:
	_session = session
	var column := VBoxContainer.new()
	add_child(column)
	_toggle = UiKit.button("Assets ▾", _toggle_tiles, false, 120)
	_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(_toggle)
	column.add_child(_tiles)
	for id in session.catalog.sorted_ids():
		_add_tile(id)
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = 140
	offset_right = 140
	offset_top = -8  # zero-size box that grows upward to its minimum size
	offset_bottom = -8
	refresh()


func _add_tile(id: String) -> void:
	var asset := _session.catalog.get_asset(id)
	var tile := UiKit.button(asset.display_name, _choose.bind(id), true, 112)
	tile.custom_minimum_size.y = 96
	tile.icon = load(asset.thumbnail) as Texture2D
	tile.expand_icon = true
	tile.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tile.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	tile.add_theme_constant_override("icon_max_width", 64)
	_tiles.add_child(tile)
	_buttons[id] = tile


func _toggle_tiles() -> void:
	_tiles.visible = not _tiles.visible
	_toggle.text = "Assets ▾" if _tiles.visible else "Assets ▸"
	reset_size()


func _choose(id: String) -> void:
	var error := _session.tools.set_setting("place", "asset_id", id)
	if error == "":
		error = _session.tools.set_active_tool("place")
	if error != "":
		_session.post_message(error, true)
	refresh()


func tile_button(id: String) -> Button:
	return _buttons[id]


func refresh() -> void:
	var chosen := str(_session.tools.settings("place").get("asset_id", ""))
	var enabled := _session.input.editing_enabled()
	for id: String in _buttons:
		var tile: Button = _buttons[id]
		var label := _session.catalog.get_asset(id).display_name
		tile.set_pressed_no_signal(id == chosen)
		tile.text = ("✓ " if id == chosen else "") + label
		tile.disabled = not enabled
