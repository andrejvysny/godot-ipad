class_name GestureHints
extends VBoxContainer
## Bottom-left gesture hints (docs/editor-v2.md §9): 10 pt white text with a shadow. Not interactive
## and not registered with UiHitTester, so a Pencil over them still edits the world.

const TOUCH: Array[String] = ["1 finger orbit · 2 fingers pan / zoom", "Pencil edits · Invert on the chip",
		"Library: drag to place"]
const MAC: Array[String] = ["Click edits · right-drag orbit · middle-drag pan · wheel zoom",
		"D inverts · [ ] brush size · Q/E rotate ghost", "Esc cancels"]

var _development := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 2)
	set_development(false, true)


func set_development(on: bool, force := false) -> void:
	if on == _development and not force:
		return
	_development = on
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for line in (MAC if on else TOUCH):
		var l := UiKit.label(line, 10)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_color_override("font_color", Color(1, 1, 1, 0.88))
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
		l.add_theme_constant_override("shadow_offset_y", 1)
		add_child(l)


func lines() -> PackedStringArray:
	var out := PackedStringArray()
	for child in get_children():
		if not child.is_queued_for_deletion():
			out.append((child as Label).text)
	return out
