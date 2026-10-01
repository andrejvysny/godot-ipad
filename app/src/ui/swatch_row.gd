class_name SwatchRow
extends VBoxContainer
## Titled row of colour swatches (texture layers, tints) of the tool popover. Exactly one is selected.

const SWATCH_HEIGHT := 30.0

var _buttons: Array[Button] = []
var _names: Array[Label] = []


func setup(title: String, names: Array[String], colors: Array[Color], on_pick: Callable) -> void:
	add_theme_constant_override("separation", 5)
	add_child(UiKit.bold_label(title, 10, UiKit.TEXT_MUTED))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	add_child(row)
	for i in names.size():
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 3)
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, SWATCH_HEIGHT)
		b.tooltip_text = names[i]
		_style(b, colors[i])
		b.pressed.connect(on_pick.bind(i))
		var label := UiKit.bold_label(names[i], 10, UiKit.TEXT_MUTED)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(b)
		column.add_child(label)
		row.add_child(column)
		_buttons.append(b)
		_names.append(label)


static func _style(b: Button, color: Color) -> void:
	var plain := StyleBoxFlat.new()
	plain.bg_color = color
	plain.set_corner_radius_all(7)
	var ringed := plain.duplicate() as StyleBoxFlat
	ringed.set_border_width_all(2)
	ringed.border_color = UiKit.ACCENT
	for key in ["normal", "hover", "disabled"]:
		b.add_theme_stylebox_override(key, plain)
	for key in ["pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(key, ringed)


func count() -> int:
	return _buttons.size()


func swatch(index: int) -> Button:
	return _buttons[index]


func set_selected(index: int) -> void:
	for i in _buttons.size():
		_buttons[i].set_pressed_no_signal(i == index)
		_names[i].add_theme_color_override("font_color", Color.WHITE if i == index else UiKit.TEXT_MUTED)


func selected() -> int:
	for i in _buttons.size():
		if _buttons[i].button_pressed:
			return i
	return -1
