class_name SetEditor
extends Control
## Full-screen scatter-set editor (docs/editor-v2.md §9): header (Cancel, name, Delete set, Save set),
## asset rows with weight scrubs, add chips, distribution scrubs, align switch and the top-down preview.
## Every edit changes a local draft; nothing reaches the store or the world until Save.

const HEADER_HEIGHT := 58.0
const PARAMS := [["density", "Density", 0.1, 5.0, 0.1, "%.1f"], ["spacing", "Min spacing", 0.2, 4.0, 0.1, "%.1f m"],
		["slope_min", "Slope from", 0.0, 90.0, 1.0, "%d°"], ["slope_max", "Slope to", 0.0, 90.0, 1.0, "%d°"]]

var _session: EditorSession
var _library: AssetLibrary
var _draft: Dictionary = {}
var _seed := 1
var _name := LineEdit.new()
var _cancel := UiKit.variant_button("Cancel", "BarButton", Callable())
var _delete := UiKit.variant_button("Delete set", "BarButton", Callable())
var _save := UiKit.variant_button("Save set", "AccentButton", Callable())
var _rows := VBoxContainer.new()
var _chips := HFlowContainer.new()
var _params: Dictionary = {}  # key -> ScrubField
var _weights: Array[ScrubField] = []
var _align := UiKit.switch_button("Align to terrain normal", Callable(), true)
var _preview := SetPreview.new()
var _count := UiKit.label("", 11)
var _reroll := UiKit.variant_button("Re-roll", "AccentLink", Callable())
var _removers: Array[Button] = []
var _adders: Dictionary = {}  # asset id -> Button


func setup(session: EditorSession, library: AssetLibrary) -> void:
	_session = session
	_library = library
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(12.0 / 255.0, 14.0 / 255.0, 16.0 / 255.0, 0.97)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_child(_build_header())
	column.add_child(UiKit.separator_h())
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(body)
	column.add_child(margin)
	body.add_child(_build_left())
	body.add_child(_build_right())
	_preview.setup(session.catalog)
	_preview.generated.connect(func(n: int) -> void: _count.text = "%d instances in preview" % n)
	session.tools.dismissed.connect(close)


func _build_header() -> Control:
	var head := HBoxContainer.new()
	head.custom_minimum_size.y = HEADER_HEIGHT
	head.add_theme_constant_override("separation", 10)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 14)
	pad.add_theme_constant_override("margin_right", 14)
	pad.add_child(head)
	_cancel.custom_minimum_size = Vector2(0, 38)
	_cancel.pressed.connect(close)
	_name.custom_minimum_size = Vector2(260, 36)
	_name.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name.add_theme_font_override("font", UiKit.bold_font())
	_name.add_theme_font_size_override("font_size", 15)
	_name.text_changed.connect(func(text: String) -> void: _draft["name"] = text)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.add_child(_name)
	_delete.custom_minimum_size = Vector2(0, 38)
	_delete.add_theme_color_override("font_color", UiKit.DANGER_TEXT)
	_delete.add_theme_color_override("font_hover_color", UiKit.DANGER_TEXT)
	_delete.pressed.connect(_on_delete)
	_save.custom_minimum_size = Vector2(0, 38)
	_save.pressed.connect(_on_save)
	for c: Control in [_cancel, centre, _delete, _save]:
		head.add_child(c)
	return pad


func _build_left() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	column.add_child(UiKit.bold_label("ASSETS IN SET · WEIGHT = SHARE OF PLACEMENTS", 10, UiKit.TEXT_MUTED))
	_rows.add_theme_constant_override("separation", 5)
	column.add_child(_rows)
	_chips.add_theme_constant_override("h_separation", 5)
	_chips.add_theme_constant_override("v_separation", 5)
	column.add_child(_chips)
	column.add_child(UiKit.bold_label("DISTRIBUTION & FILTERS", 10, UiKit.TEXT_MUTED))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for spec: Array in PARAMS:
		var f := _scrub(str(spec[1]), float(spec[2]), float(spec[3]), float(spec[4]), str(spec[5]))
		f.value_changed.connect(_on_param.bind(str(spec[0])))
		grid.add_child(f)
		_params[spec[0]] = f
	_align.custom_minimum_size.y = 38
	_align.toggled.connect(func(on: bool) -> void:
		_draft["align"] = on
		_changed())
	grid.add_child(_align)
	column.add_child(grid)
	return scroll


func _build_right() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.custom_minimum_size.x = SetPreview.SIZE.x
	var head := HBoxContainer.new()
	var title := UiKit.bold_label("PREVIEW · 50 × 35 M FLAT PATCH", 10, UiKit.TEXT_MUTED)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_reroll.custom_minimum_size.y = 36
	_reroll.pressed.connect(func() -> void:
		_seed += 1
		_changed())
	head.add_child(title)
	head.add_child(_reroll)
	column.add_child(head)
	column.add_child(_preview)
	_count.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	column.add_child(_count)
	return column


static func _scrub(caption: String, lo: float, hi: float, step: float, format: String) -> ScrubField:
	var f := ScrubField.new()
	f.custom_minimum_size.y = 38
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f.caption = caption
	f.min_value = lo
	f.max_value = hi
	f.step = step
	f.formatter = func(v: float) -> String: return format % v
	return f


# --- open / close --------------------------------------------------------------------------

## `set_data` is a store set or a prefilled draft; `is_new` hides Delete set.
func open_set(set_data: Dictionary, is_new: bool) -> void:
	_draft = set_data.duplicate(true)
	_delete.visible = not is_new and not _session.tools.set_store().get_set(str(_draft.id)).is_empty()
	_name.text = str(_draft.name)
	_seed = 1
	_rebuild_items()
	_sync_params()
	visible = true
	_changed()


func close() -> void:
	if visible:
		visible = false
		_name.release_focus()


func is_open() -> bool:
	return visible


func draft() -> Dictionary:
	return _draft.duplicate(true)


# --- editing -------------------------------------------------------------------------------

func _rebuild_items() -> void:
	for container: Control in [_rows, _chips]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
	_weights.clear()
	_removers.clear()
	_adders.clear()
	var items: Array = _draft.items
	for i in items.size():
		_rows.add_child(_build_row(i, items[i]))
	for id in _session.catalog.sorted_ids():
		var asset := _session.catalog.get_asset(id)
		if not asset.scatter_allowed:
			continue
		var present := items.any(func(item: Dictionary) -> bool: return item.asset_id == id)
		var chip := UiKit.variant_button("+ %s" % asset.display_name, "ChipButton", _add_item.bind(id))
		chip.custom_minimum_size.y = 34
		chip.disabled = present
		chip.modulate.a = 0.35 if present else 1.0
		_chips.add_child(chip)
		_adders[id] = chip


func _build_row(index: int, item: Dictionary) -> Control:
	var asset := _session.catalog.get_asset(str(item.asset_id))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(40, 40)
	cell.add_theme_stylebox_override("panel", UiKit.pill_box(Color(1, 1, 1, 0.06), 8, 4, false))
	cell.add_child(UiKit.texture_rect(load(asset.thumbnail) as Texture2D, Vector2(32, 32)))
	var label := UiKit.bold_label(asset.display_name, 12)
	label.custom_minimum_size.x = 104
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var square := ColorRect.new()
	square.color = AssetColors.of(asset.asset_id)
	square.custom_minimum_size = Vector2(10, 10)
	square.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var weight := _scrub("Weight", ScatterSetStore.WEIGHT_MIN, ScatterSetStore.WEIGHT_MAX, 0.5, "%.1f")
	weight.set_value_no_signal(float(item.weight))
	weight.value_changed.connect(_on_weight.bind(index))
	_weights.append(weight)
	var remove := UiKit.variant_button("", "SurfaceButton", _remove_item.bind(index))
	remove.custom_minimum_size = Vector2(44, 40)
	remove.icon = UiKit.icon("close")
	remove.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	remove.add_theme_constant_override("icon_max_width", 14)
	_removers.append(remove)
	for c: Control in [cell, label, square, weight, remove]:
		row.add_child(c)
	return row


func _add_item(asset_id: String) -> void:
	(_draft.items as Array).append({"asset_id": asset_id, "weight": 3.0})
	_rebuild_items()
	_changed()


func _remove_item(index: int) -> void:
	(_draft.items as Array).remove_at(index)
	_rebuild_items()
	_changed()


func _on_weight(value: float, index: int) -> void:
	_draft.items[index]["weight"] = value
	_changed()


func _on_param(value: float, key: String) -> void:
	_draft[key] = value
	if key == "slope_min":
		_draft["slope_max"] = maxf(float(_draft.slope_max), value)
	elif key == "slope_max":
		_draft["slope_min"] = minf(float(_draft.slope_min), value)
	_sync_params()
	_changed()


func _sync_params() -> void:
	for key: String in _params:
		(_params[key] as ScrubField).set_value_no_signal(float(_draft[key]))
	_align.set_pressed_no_signal(bool(_draft.align))
	UiKit.set_switch(_align, bool(_draft.align))


func _changed() -> void:
	_preview.set_data(_draft, _seed)


# --- save / delete -------------------------------------------------------------------------

func _on_save() -> void:
	if (_draft.items as Array).is_empty():
		_session.post_message("Add at least one asset", true)
		return
	var tools := _session.tools
	var err := tools.set_store().put_set(_draft)
	if err != "":
		_session.post_message(err, true)
		return
	tools.set_setting("scatter", "source", "set:" + str(_draft.id))
	tools.disarm()
	tools.set_tool("fill" if tools.active_tool() == "fill" else "scatter")
	_library.rebuild_sets()
	_library.show_tab("sets")
	_session.post_message("Saved set %s" % str(_draft.name).strip_edges())
	close()


func _on_delete() -> void:
	var tools := _session.tools
	var id := str(_draft.id)
	var err := tools.set_store().remove_set(id)
	if err != "":
		_session.post_message(err, true)
		return
	if str(tools.settings("scatter").source) == "set:" + id:
		var rest := tools.set_store().sets()
		tools.set_setting("scatter", "source", "set:" + str(rest[0].id) if not rest.is_empty() else "mix")
	_library.rebuild_sets()
	close()


# --- API -----------------------------------------------------------------------------------

func cancel_button() -> Button:
	return _cancel


func delete_button() -> Button:
	return _delete


func save_button() -> Button:
	return _save


func name_edit() -> LineEdit:
	return _name


func param(key: String) -> ScrubField:
	return _params[key]


func weight_scrub(index: int) -> ScrubField:
	return _weights[index]


func remove_button(index: int) -> Button:
	return _removers[index]


func add_chip(asset_id: String) -> Button:
	return _adders[asset_id]


func align_switch() -> Button:
	return _align


func reroll_button() -> Button:
	return _reroll


func preview() -> SetPreview:
	return _preview


func seed_value() -> int:
	return _seed


func count_text() -> String:
	return _count.text
