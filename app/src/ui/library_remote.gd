class_name LibraryRemote
extends VBoxContainer
## The remote half of the Library's Objects page (IP-SPEC §4): the source chips (Bundled plus one per granted
## AssetStudio library), the text and category filter, connectivity and update text, and the grid of RemoteTiles
## with a "Load more" button. The bundled grid stays AssetLibrary's own; this control only shows its remote part
## while a library is selected and hides entirely while no server is configured.

signal source_changed(remote_selected: bool)
signal update_requested(binding_id: String)

const CHIP_CHARS := 14
const MAX_CATEGORY_CHIPS := 8

var _session: EditorSession
var _remote: RemoteLibrary
var _sources := HFlowContainer.new()
var _source_buttons: Dictionary = {}  # library key ("" = bundled) -> Button
var _source_sig: Array = []
var _bar := VBoxContainer.new()
var _filter := LineEdit.new()
var _status := UiKit.label("", 10)
var _categories := HFlowContainer.new()
var _category_sig: Array = []
var _category := ""
var _grid := GridContainer.new()
var _scroll := ScrollContainer.new()
var _more := UiKit.variant_button("Load more", "SurfaceButton", Callable())
var _tiles: Dictionary = {}  # asset_key -> RemoteTile
var _tile_keys: Array = []


func setup(session: EditorSession, width: float) -> void:
	_session = session
	_remote = session.assets().remote
	add_theme_constant_override("separation", 6)
	_sources.add_theme_constant_override("h_separation", 4)
	_sources.add_theme_constant_override("v_separation", 4)
	add_child(_sources)
	_build_bar(width)
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid)
	add_child(_scroll)
	_more.custom_minimum_size.y = 32
	_more.pressed.connect(func() -> void: _remote.browse(_remote.selected(), true))
	add_child(_more)
	_remote.changed.connect(refresh)
	_remote.thumbnail_ready.connect(func(_key: String) -> void: _refresh_tiles())
	refresh()


func _build_bar(width: float) -> void:
	_bar.add_theme_constant_override("separation", 4)
	_filter.placeholder_text = "Search this library"
	_filter.custom_minimum_size = Vector2(width - 24.0, 34)
	_filter.add_theme_font_size_override("font_size", 11)
	_filter.text_submitted.connect(func(_t: String) -> void: _apply_filter())
	_filter.focus_exited.connect(_apply_filter)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = width - 24.0
	_status.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_categories.add_theme_constant_override("h_separation", 4)
	_categories.add_theme_constant_override("v_separation", 4)
	for c: Control in [_filter, _categories, _status]:
		_bar.add_child(c)
	add_child(_bar)


## A UI cancel (palm, backgrounding, native cancel) ends every tile contact in place.
func cancel_contacts() -> void:
	for t: RemoteTile in _tiles.values():
		t.cancel_contact()


func is_remote() -> bool:
	return _remote != null and _remote.selected() != ""


func filter_edit() -> LineEdit:
	return _filter


func source_button(key: String) -> Button:
	return _source_buttons.get(key)


func tile(asset_key: String) -> RemoteTile:
	return _tiles.get(asset_key)


func tile_keys() -> Array:
	return _tile_keys.duplicate()


func status_text() -> String:
	return _status.text


func more_button() -> Button:
	return _more


func category_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c in _categories.get_children():
		out.append(c as Button)
	return out


func _apply_filter() -> void:
	if _filter.text.strip_edges() != str(_remote.query.q):
		_remote.set_query(_filter.text, _category)


func _select_source(key: String) -> void:
	_remote.select(key)
	_category = ""
	refresh()
	source_changed.emit(key != "")


func _select_category(id: String) -> void:
	_category = id
	_remote.set_query(_filter.text, id)
	_rebuild_categories()


func refresh() -> void:
	if _remote == null:
		return
	visible = _remote.has_servers()
	_rebuild_sources()
	var remote_on := is_remote()
	size_flags_vertical = Control.SIZE_EXPAND_FILL if remote_on else Control.SIZE_SHRINK_BEGIN
	_bar.visible = remote_on
	_scroll.visible = remote_on
	_more.visible = remote_on and _remote.has_more(_remote.selected())
	if not remote_on:
		return
	_rebuild_categories()
	_rebuild_tiles()
	_status.text = _status_lines()
	_status.visible = _status.text != ""


func _rebuild_sources() -> void:
	var libs := _remote.libraries()
	var sig: Array = [_remote.selected()]
	for l: Dictionary in libs:
		sig.append([l.key, l.name, l.available])
	if sig == _source_sig:
		return
	_source_sig = sig
	for b: Button in _source_buttons.values():
		_sources.remove_child(b)
		b.queue_free()
	_source_buttons.clear()
	_add_source("", "Bundled")
	for l: Dictionary in libs:
		_add_source(str(l.key), str(l.name) if bool(l.available) else "%s (offline)" % l.name)
	for key: String in _source_buttons:
		(_source_buttons[key] as Button).set_pressed_no_signal(key == _remote.selected())


func _add_source(key: String, text: String) -> void:
	var b := UiKit.variant_button(text.left(CHIP_CHARS), "BarButton", _select_source.bind(key), true)
	b.custom_minimum_size.y = 30
	b.add_theme_font_size_override("font_size", 10)
	_sources.add_child(b)
	_source_buttons[key] = b


func _rebuild_categories() -> void:
	var ids := _remote.categories(_remote.selected())
	var sig: Array = [_category, ids]
	if sig == _category_sig:
		return
	_category_sig = sig
	for c in _categories.get_children():
		_categories.remove_child(c)
		c.queue_free()
	if ids.is_empty() and _category == "":
		return
	_add_category("", "All")
	for id in ids.slice(0, MAX_CATEGORY_CHIPS):
		_add_category(id, id)


func _add_category(id: String, text: String) -> void:
	var b := UiKit.variant_button(text.left(CHIP_CHARS), "ChipButton", _select_category.bind(id), true)
	b.set_pressed_no_signal(id == _category)
	b.custom_minimum_size.y = 28
	b.add_theme_font_size_override("font_size", 10)
	_categories.add_child(b)


func _rebuild_tiles() -> void:
	var items := _remote.items(_remote.selected())
	var keys: Array = items.map(func(it: Dictionary) -> String: return str(it.asset_key))
	if keys == _tile_keys:
		_refresh_tiles()
		return
	for t: RemoteTile in _tiles.values():
		_grid.remove_child(t)
		t.queue_free()
	_tiles.clear()
	_tile_keys = keys
	for it: Dictionary in items:
		var t := RemoteTile.new()
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(t)
		t.setup_remote(_session, it)
		t.update_requested.connect(update_requested.emit)
		_tiles[str(it.asset_key)] = t
	_refresh_tiles()


func _refresh_tiles() -> void:
	var armed := _session.tools.armed_asset()
	var enabled := _session.input.editing_enabled()
	for t: RemoteTile in _tiles.values():
		t.refresh_state()
		t.set_enabled(enabled)
		t.set_selected(armed != "" and armed == str(t.readiness().binding_id))


func _status_lines() -> String:
	var key := _remote.selected()
	var lines := PackedStringArray()
	var conn := _remote.connectivity()
	if conn.state != "online":
		lines.append(str(conn.text))
	if _remote.library_error(key) != "":
		lines.append("Could not load: %s" % _remote.library_error(key))
	elif _remote.is_loading(key):
		lines.append("Loading…")
	elif _remote.items(key).is_empty():
		lines.append("No assets match.")
	if _remote.updates.count() > 0:
		lines.append("%d update(s) available for this world." % _remote.updates.count())
	return "\n".join(lines)
