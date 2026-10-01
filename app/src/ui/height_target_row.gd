class_name HeightTargetRow
extends HBoxContainer
## Flatten target height cell with its Pick button (docs/editor-v2.md §9). NAN shows "stroke start".

signal pick_pressed()

var _value := UiKit.label("", 12)
var _pick := UiKit.variant_button("Pick", "SegmentButton", Callable(), true)


func _init() -> void:
	add_theme_constant_override("separation", 5)
	var cell := PanelContainer.new()
	cell.add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.SURFACE, 8, 10, false))
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.custom_minimum_size.y = ScrubField.HEIGHT
	var row := HBoxContainer.new()
	var caption := UiKit.bold_label("Target height", 11, UiKit.TEXT_SECONDARY)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_value.add_theme_font_override("font", UiKit.mono_font())
	row.add_child(caption)
	row.add_child(_value)
	cell.add_child(row)
	add_child(cell)
	_pick.custom_minimum_size = Vector2(56, ScrubField.HEIGHT)
	_pick.pressed.connect(func() -> void: pick_pressed.emit())
	add_child(_pick)


func set_target(target: float, picking: bool) -> void:
	_value.text = "stroke start" if is_nan(target) else "%.1f m" % target
	_pick.set_pressed_no_signal(picking)


func value_text() -> String:
	return _value.text


func pick_button() -> Button:
	return _pick
