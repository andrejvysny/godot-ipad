class_name AssetLibrary
extends PanelContainer
## Library of placeable assets (spec §9.4): category chips and a tile grid; tiles are dragged onto
## the terrain or tapped to arm the Place tool. Collapses to a narrow strip (a second panel that
## EditorUI places and registers). Exactly one of the two is visible.

signal open_changed(open: bool)

const WIDTH := 300.0
const STRIP_WIDTH := 56.0

var _session: EditorSession
var _tiles: Dictionary = {}  # asset id -> LibraryTile
var _chips: Dictionary = {}  # category (or "all") -> Button
var _grid := GridContainer.new()
var _collapse: Button
var _strip := PanelContainer.new()
var _strip_chevron := UiKit.icon_rect("chevron_left", Vector2(16, 16))
var _open := true
var _category := "all"


func setup(session: EditorSession, report: Callable) -> void:
	_session = session
	custom_minimum_size.x = WIDTH
	var box := StyleBoxFlat.new()
	box.bg_color = Color(UiKit.PANEL_BG, 0.88)
	box.set_corner_radius_all(20)
	box.set_content_margin_all(14)
	box.set_border_width_all(1)
	box.border_color = UiKit.PANEL_BORDER
	add_theme_stylebox_override("panel", box)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)
	column.add_child(_build_header())
	column.add_child(_build_chips())
	column.add_child(_build_grid(report))
	column.add_child(_build_footer())
	_build_strip()
	for signal_ref: Signal in [session.tools.tool_changed, session.tools.settings_changed,
			session.status_changed, session.world_replaced]:
		signal_ref.connect(_on_any_signal)
	set_side_left(false)
	refresh()


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


# --- builders ------------------------------------------------------------------------------

func _build_header() -> Control:
	var row := HBoxContainer.new()
	var title := UiKit.bold_label("Library", 17)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(title)
	_collapse = UiKit.variant_button("", "SurfaceButton", func() -> void: set_open(false), false, 44)
	_collapse.custom_minimum_size = Vector2(44, 44)
	_collapse.add_theme_constant_override("icon_max_width", 16)
	_collapse.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_collapse.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_collapse)
	return row


func _build_chips() -> Control:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	var group := ButtonGroup.new()
	var categories: Array[String] = ["all"]
	for id in _session.catalog.sorted_ids():
		var category := _session.catalog.get_asset(id).category
		if not categories.has(category):
			categories.append(category)
	for category in categories:
		var chip := UiKit.variant_button(category.capitalize(), "ChipButton", _choose_category.bind(category), true)
		chip.custom_minimum_size.y = 44
		chip.button_group = group
		flow.add_child(chip)
		_chips[category] = chip
	(_chips["all"] as Button).set_pressed_no_signal(true)
	return flow


func _build_grid(report: Callable) -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	for id in _session.catalog.sorted_ids():
		var tile := LibraryTile.new()
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(tile)
		tile.setup(_session, _session.catalog.get_asset(id), report)
		_tiles[id] = tile
	return scroll


func _build_footer() -> Control:
	var column := VBoxContainer.new()
	column.add_child(UiKit.separator_h())
	var hint := UiKit.label("Drag a tile onto the terrain with the Pencil, or tap a tile and then touch the terrain.", 12)
	hint.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	return column


func _build_strip() -> void:
	_strip.custom_minimum_size.x = STRIP_WIDTH
	_strip.visible = false
	var thumbs := VBoxContainer.new()
	thumbs.add_theme_constant_override("separation", 8)
	thumbs.alignment = BoxContainer.ALIGNMENT_CENTER
	thumbs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.add_child(thumbs)
	for id in _session.catalog.sorted_ids():
		var thumb := TextureRect.new()
		thumb.texture = load(_session.catalog.get_asset(id).thumbnail) as Texture2D
		thumb.custom_minimum_size = Vector2(32, 32)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumbs.add_child(thumb)
	thumbs.add_child(_strip_chevron)
	var overlay := Button.new()
	overlay.focus_mode = Control.FOCUS_NONE
	overlay.flat = true
	for key in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		overlay.add_theme_stylebox_override(key, StyleBoxEmpty.new())
	overlay.pressed.connect(func() -> void: set_open(true))
	_strip.add_child(overlay)


func _choose_category(category: String) -> void:
	_category = category
	refresh()


# --- API -----------------------------------------------------------------------------------

func tile(asset_id: String) -> LibraryTile:
	return _tiles[asset_id]


## category: "all" or an AssetDefinition.category
func chip(category: String) -> Button:
	return _chips[category]


func collapse_button() -> Button:
	return _collapse


func strip() -> Control:
	return _strip


func is_open() -> bool:
	return _open


func set_open(on: bool) -> void:
	if on == _open:
		return
	_open = on
	_apply_open()
	open_changed.emit(on)


func _apply_open() -> void:
	visible = _open
	_strip.visible = not _open


## The Library sits on the left edge for left-handed layouts; chevrons point toward the edge.
func set_side_left(on: bool) -> void:
	_collapse.icon = UiKit.icon("chevron_left" if on else "chevron_right")
	_strip_chevron.texture = UiKit.icon("chevron_right" if on else "chevron_left")


func on_ui_cancelled(_reason: String) -> void:
	for id: String in _tiles:
		(_tiles[id] as LibraryTile).cancel_contact()


func refresh() -> void:
	if _session == null:
		return
	var place_id := str(_session.tools.settings("place").get("asset_id", ""))
	var armed := _session.tools.active_tool() == "place"
	var enabled := _session.input.editing_enabled()
	for id: String in _tiles:
		var t: LibraryTile = _tiles[id]
		t.visible = _category == "all" or _session.catalog.get_asset(id).category == _category
		t.set_selected(armed and id == place_id)
		t.set_enabled(enabled)
