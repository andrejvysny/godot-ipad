class_name HistoryTiles
extends PanelContainer
## Top-centre pill (docs/editor-v2.md §9): Undo and Redo tiles (52 x 38, icon and caption, 40 % opacity
## when unavailable) and, only while a world operation is open, an explicit Cancel (spec §16.2). The
## toast after undo/redo comes from EditorSession.undo()/redo() ("Undid <label>", "Nothing to undo").

const TILE := Vector2(52, 38)

var _session: EditorSession
var _undo: Button
var _redo: Button
var _cancel: Button
var _row := HBoxContainer.new()


func setup(session: EditorSession) -> void:
	_session = session
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.PANEL_BG, 12, 3))
	_row.add_theme_constant_override("separation", 2)
	add_child(_row)
	_undo = _tile("Undo", "undo", session.undo)
	_redo = _tile("Redo", "redo", session.redo)
	_cancel = _tile("Cancel", "close", session.cancel_active)
	_cancel.visible = false
	refresh(session.status())


func _tile(caption: String, icon_name: String, on_pressed: Callable) -> Button:
	var b := UiKit.variant_button("", "HistoryTile", on_pressed)
	b.custom_minimum_size = TILE
	b.set_meta("caption", caption)
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 0)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := UiKit.bold_label(caption, 9, UiKit.TEXT_SECONDARY)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(UiKit.icon_rect(icon_name, Vector2(16, 16)))
	column.add_child(label)
	b.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_row.add_child(b)
	return b


func undo_button() -> Button:
	return _undo


func redo_button() -> Button:
	return _redo


func cancel_button() -> Button:
	return _cancel


## Pill width without the Cancel tile, so the pill's left edge does not move when Cancel appears.
func base_width() -> float:
	var w := get_combined_minimum_size().x
	if _cancel.visible:
		w -= TILE.x + float(_row.get_theme_constant("separation"))
	return w


func refresh(status: Dictionary) -> void:
	if _session == null:
		return
	var editing := bool(status.editing_enabled)
	var busy := _session.tools.has_active_operation()
	_set_action(_undo, str(status.undo_label), editing and bool(status.can_undo) and not busy, editing, "Nothing to undo")
	_set_action(_redo, str(status.redo_label), editing and bool(status.can_redo) and not busy, editing, "Nothing to redo")
	_cancel.visible = busy
	_cancel.disabled = not editing
	reset_size()


static func _set_action(b: Button, label: String, available: bool, editing: bool, none_text: String) -> void:
	b.tooltip_text = ("%s %s" % [b.get_meta("caption"), label]) if label != "" else none_text
	b.disabled = not editing
	b.modulate.a = 1.0 if available else 0.4
