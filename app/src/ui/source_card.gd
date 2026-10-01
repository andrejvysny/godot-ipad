class_name SourceCard
extends PanelContainer
## Scatter source card of the tool popover: kicker, "<name> · density D", weight bar, Change and
## Edit set / Save as set (docs/editor-v2.md §9).

signal change_requested()
signal edit_requested()

var _kicker := UiKit.bold_label("", 10, UiKit.TEXT_MUTED)
var _name := UiKit.bold_label("", 13)
var _bar := HBoxContainer.new()
var _change := UiKit.variant_button("Change", "SurfaceButton", Callable())
var _edit := UiKit.variant_button("Edit set", "SurfaceButton", Callable())


func _init() -> void:
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.SURFACE, 10, 8, false))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)
	_bar.add_theme_constant_override("separation", 1)
	_bar.custom_minimum_size.y = 5
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	for b: Button in [_change, _edit]:
		b.custom_minimum_size.y = 30
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 11)
		row.add_child(b)
	_change.pressed.connect(func() -> void: change_requested.emit())
	_edit.pressed.connect(func() -> void: edit_requested.emit())
	for c: Control in [_kicker, _name, _bar, row]:
		column.add_child(c)


## source: "set:<id>" or "mix"; config: ToolController.scatter_config().
func set_config(source: String, config: Dictionary) -> void:
	var items: Array = config.items
	_kicker.text = "SCATTER SET" if source.begins_with("set:") else "QUICK MIX · %d ASSETS" % items.size()
	_name.text = "%s · density %s" % [str(config.name), ToolTexts.format_density(float(config.density))]
	_edit.text = "Edit set" if source.begins_with("set:") else "Save as set"
	AssetColors.fill_bar(_bar, items)


func kicker_text() -> String:
	return _kicker.text


func name_text() -> String:
	return _name.text


func segment_count() -> int:
	return _bar.get_child_count()


func change_button() -> Button:
	return _change


func edit_button() -> Button:
	return _edit
