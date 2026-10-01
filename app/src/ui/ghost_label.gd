class_name GhostLabel
extends PanelContainer
## Label beside the placement ghost (docs/editor-v2.md §8): "Lift to place <Name>" (accent), "Too close to
## <Name>" or "Over a panel · lift to cancel", plus "Slope 12° · yaw 30°". Driven by
## ToolController.place_preview(); not registered with UiHitTester.

var _title := UiKit.bold_label("", 11)
var _sub := UiKit.label("", 11)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.TOAST_BG, 8, 5, false))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sub.add_theme_color_override("font_color", UiKit.TEXT_SECONDARY)
	for l: Label in [_title, _sub]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(l)
	add_child(column)
	visible = false


## Hides itself when no placement is open; true while shown.
func show_preview(preview: Dictionary) -> bool:
	visible = bool(preview.active)
	if not visible:
		return false
	var color := UiKit.ACCENT
	if bool(preview.over_ui):
		_title.text = "Over a panel · lift to cancel"
		color = UiKit.DANGER_TEXT
	elif not bool(preview.valid):
		_title.text = "No terrain here · lift to cancel"
		color = UiKit.DANGER_TEXT
	elif str(preview.conflict) != "":
		_title.text = "Too close to %s" % str(preview.conflict)
		color = UiKit.WARN_TEXT
	else:
		_title.text = "Lift to place %s" % str(preview.asset_name)
	_title.add_theme_color_override("font_color", color)
	_sub.text = "Slope %d° · yaw %d°" % [roundi(float(preview.slope_deg)), roundi(float(preview.yaw_deg))]
	reset_size()
	return true


func title_text() -> String:
	return _title.text


func sub_text() -> String:
	return _sub.text


func title_color() -> Color:
	return _title.get_theme_color("font_color")
