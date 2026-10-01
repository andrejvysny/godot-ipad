class_name AssetLibrary
extends PanelContainer
## Library v2 (docs/editor-v2.md §9): segmented tabs Objects / Scatter sets. Objects: two-column tiles
## (drag = drop, tap = arm, tick = quick-mix member) and the "Scatter N as quick mix" bar. Sets: cards of
## the ScatterSetStore. Shown or hidden only by the Library toggle of the top bar.

signal open_changed(open: bool)
signal edit_set_requested(set_id: String)  # "" = a new set
signal quick_mix_used()

const WIDTH := 240.0
const TABS := {"objects": "Objects", "sets": "Scatter sets"}
const OBJECTS_HINT := "Drag one item onto the terrain to place it. Tick several to scatter them as a quick mix."
const SETS_HINT := "Tap a set to scatter with it."

var _session: EditorSession
var _tiles: Dictionary = {}  # asset id -> LibraryTile
var _tabs: Dictionary = {}  # tab -> Button
var _pages: Dictionary = {}  # tab -> Control
var _cards: Dictionary = {}  # set id -> SetCard
var _grid := GridContainer.new()
var _cards_box := VBoxContainer.new()
var _mix_bar := HBoxContainer.new()
var _mix := UiKit.variant_button("", "AccentButton", Callable())
var _clear := UiKit.variant_button("", "SurfaceButton", Callable())
var _new_set := UiKit.variant_button("+ New set", "SurfaceButton", Callable())
var _open := true
var _tab := "objects"
var _ticked: Array[String] = []


func setup(session: EditorSession) -> void:
	_session = session
	custom_minimum_size.x = WIDTH
	add_theme_stylebox_override("panel", UiKit.pill_box(Color(UiKit.PANEL_BG, 0.9), 14, 8))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	column.add_child(_build_tabs())
	_pages["objects"] = _build_objects()
	_pages["sets"] = _build_sets()
	for tab: String in _pages:
		(_pages[tab] as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
		column.add_child(_pages[tab])
	rebuild_sets()
	for signal_ref: Signal in [session.tools.tool_changed, session.tools.settings_changed,
			session.status_changed, session.world_replaced]:
		signal_ref.connect(_on_any_signal)
	show_tab("objects")
	refresh()


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


# --- builders ------------------------------------------------------------------------------

func _build_tabs() -> Control:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.SURFACE, 9, 2, false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	box.add_child(row)
	for tab: String in TABS:
		var b := UiKit.variant_button(TABS[tab], "BarButton", show_tab.bind(tab), true)
		b.custom_minimum_size.y = 30
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 11)
		row.add_child(b)
		_tabs[tab] = b
	return box


func _scroll(content: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return scroll


func _hint(text: String) -> Label:
	var hint := UiKit.label(text, 10)
	hint.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = WIDTH - 24.0
	return hint


func _build_objects() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	for id in _session.catalog.sorted_ids():
		var tile := LibraryTile.new()
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(tile)
		tile.setup(_session, _session.catalog.get_asset(id))
		tile.tick_toggled.connect(_on_tick)
		_tiles[id] = tile
	page.add_child(_scroll(_grid))
	_mix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mix.custom_minimum_size.y = 36
	_mix.add_theme_font_size_override("font_size", 11)
	_mix.pressed.connect(_use_quick_mix)
	_clear.custom_minimum_size = Vector2(36, 36)
	_clear.icon = UiKit.icon("close")
	_clear.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clear.add_theme_constant_override("icon_max_width", 14)
	_clear.pressed.connect(clear_ticks)
	_mix_bar.add_theme_constant_override("separation", 4)
	_mix_bar.add_child(_mix)
	_mix_bar.add_child(_clear)
	page.add_child(_mix_bar)
	page.add_child(_hint(OBJECTS_HINT))
	return page


func _build_sets() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	_cards_box.add_theme_constant_override("separation", 6)
	page.add_child(_scroll(_cards_box))
	page.add_child(_hint(SETS_HINT))
	_new_set.custom_minimum_size.y = 36
	_new_set.add_theme_font_size_override("font_size", 11)
	_new_set.pressed.connect(func() -> void: edit_set_requested.emit(""))
	return page


## Rebuilds the cards from the store; call after the store changed.
func rebuild_sets() -> void:
	for child in _cards_box.get_children():
		_cards_box.remove_child(child)
		if child != _new_set:
			child.queue_free()
	_cards.clear()
	for set_data in _session.tools.set_store().sets():
		var card := SetCard.new()
		_cards_box.add_child(card)
		card.setup(set_data)
		for item: Dictionary in set_data.items:
			var asset := _session.catalog.get_asset(str(item.asset_id))
			if asset != null:
				card.add_thumbnail(load(asset.thumbnail) as Texture2D)
		card.picked.connect(_pick_set.bind(card.set_id))
		card.edit_pressed.connect(func() -> void: edit_set_requested.emit(card.set_id))
		_cards[card.set_id] = card
	_cards_box.add_child(_new_set)
	refresh()


# --- handlers ------------------------------------------------------------------------------

func _on_tick(asset_id: String, on: bool) -> void:
	_ticked.erase(asset_id)
	if on:
		_ticked.append(asset_id)
	refresh()


func _use_quick_mix() -> void:
	var tools := _session.tools
	var err := tools.set_quick_mix(PackedStringArray(_ticked))
	if err == "":
		err = tools.set_setting("scatter", "source", "mix")
	if err == "":
		tools.disarm()
		err = tools.set_tool("scatter")
	if err != "":
		_session.post_message(err, true)
		return
	quick_mix_used.emit()


func _pick_set(set_id: String) -> void:
	var tools := _session.tools
	var err := tools.set_setting("scatter", "source", "set:" + set_id)
	if err == "":
		tools.disarm()
		err = tools.set_tool("fill" if tools.active_tool() == "fill" else "scatter")
	tools.set_inverted(false)
	if err != "":
		_session.post_message(err, true)


# --- API -----------------------------------------------------------------------------------

func tile(asset_id: String) -> LibraryTile:
	return _tiles[asset_id]


func tab() -> String:
	return _tab


func tab_button(tab_id: String) -> Button:
	return _tabs[tab_id]


func show_tab(tab_id: String) -> void:
	_tab = tab_id
	for id: String in _pages:
		(_pages[id] as Control).visible = id == tab_id
		(_tabs[id] as Button).set_pressed_no_signal(id == tab_id)


func ticked() -> PackedStringArray:
	return PackedStringArray(_ticked)


func clear_ticks() -> void:
	_ticked.clear()
	for id: String in _tiles:
		(_tiles[id] as LibraryTile).set_ticked(false)
	refresh()


func quick_mix_button() -> Button:
	return _mix


func clear_button() -> Button:
	return _clear


func new_set_button() -> Button:
	return _new_set


func set_card(set_id: String) -> SetCard:
	return _cards[set_id]


func set_card_ids() -> PackedStringArray:
	return PackedStringArray(_cards.keys())


func is_open() -> bool:
	return _open


func set_open(on: bool) -> void:
	if on == _open:
		return
	_open = on
	visible = on
	open_changed.emit(on)


func on_ui_cancelled(_reason: String) -> void:
	for id: String in _tiles:
		(_tiles[id] as LibraryTile).cancel_contact()


func refresh() -> void:
	if _session == null:
		return
	var armed := _session.tools.armed_asset()
	var enabled := _session.input.editing_enabled()
	for id: String in _tiles:
		var t: LibraryTile = _tiles[id]
		t.set_selected(id == armed)
		t.set_enabled(enabled)
	_mix_bar.visible = not _ticked.is_empty()
	_mix.text = "Scatter %d as quick mix" % _ticked.size()
	var source := str(_session.tools.settings("scatter").source)
	for id: String in _cards:
		(_cards[id] as SetCard).set_selected(source == "set:" + id)
