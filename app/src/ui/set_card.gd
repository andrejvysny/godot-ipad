class_name SetCard
extends PanelContainer
## Scatter set card of the Library's Sets tab (docs/editor-v2.md §9): name, Edit, up to six thumbnails,
## weight bar and "density D · spacing S m · slope A–B°". A tap on the card picks the set.

signal picked()
signal edit_pressed()

const MAX_THUMBS := 6

var set_id := ""

var _name := UiKit.bold_label("", 12)
var _edit := UiKit.variant_button("Edit", "AccentLink", Callable())
var _thumbs := HBoxContainer.new()
var _bar := HBoxContainer.new()
var _meta := UiKit.label("", 9)
var _down := false
var _selected := false


func setup(set_data: Dictionary) -> void:
	set_id = str(set_data.id)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name.text = str(set_data.name)
	_name.clip_text = true
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit.custom_minimum_size = Vector2(52, 44)
	_edit.add_theme_font_size_override("font_size", 10)
	_edit.pressed.connect(func() -> void: edit_pressed.emit())
	head.add_child(_name)
	head.add_child(_edit)
	_thumbs.add_theme_constant_override("separation", 4)
	_thumbs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_theme_constant_override("separation", 1)
	_bar.custom_minimum_size.y = 5
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meta.text = "density %s · spacing %s m · slope %d–%d°" % [ToolTexts.format_density(float(set_data.density)),
			ToolTexts.format_density(float(set_data.spacing)), roundi(float(set_data.slope_min)), roundi(float(set_data.slope_max))]
	_meta.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Control in [head, _thumbs, _bar, _meta]:
		column.add_child(c)
	add_child(column)
	AssetColors.fill_bar(_bar, set_data.items)
	_apply_style()


func add_thumbnail(texture: Texture2D) -> void:
	if _thumbs.get_child_count() >= MAX_THUMBS:
		return
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(30, 30)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_theme_stylebox_override("panel", UiKit.pill_box(Color(1, 1, 1, 0.06), 6, 3, false))
	var rect := UiKit.texture_rect(texture, Vector2(24, 24))
	cell.add_child(rect)
	_thumbs.add_child(cell)


func name_text() -> String:
	return _name.text


func meta_text() -> String:
	return _meta.text


func thumb_count() -> int:
	return _thumbs.get_child_count()


func edit_button() -> Button:
	return _edit


func set_selected(on: bool) -> void:
	_selected = on
	_apply_style()


func _apply_style() -> void:
	var box := UiKit.pill_box(Color(1, 1, 1, 0.05), 10, 8, false)
	box.set_border_width_all(2)
	box.border_color = UiKit.ACCENT if _selected else Color(UiKit.ACCENT, 0.0)
	add_theme_stylebox_override("panel", box)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed:
			_down = true
		elif _down:
			_down = false
			if Rect2(Vector2.ZERO, size).has_point(button.position):
				picked.emit()
		accept_event()
