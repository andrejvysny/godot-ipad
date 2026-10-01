class_name HistoryBar
extends PanelContainer
## Top-centre pill: Undo, Redo and, only while a world operation is open, an explicit Cancel
## (spec §16.2). Undo/Redo captions show what the action would undo or redo.

const CAPTION_WIDTH := 92.0
const BUTTON_WIDTH := 140.0

var _session: EditorSession
var _undo := Button.new()
var _redo := Button.new()
var _cancel := UiKit.variant_button("Cancel", "SurfaceButton", Callable(), false, 88)
var _undo_caption := UiKit.label("Nothing", 11)
var _redo_caption := UiKit.label("Nothing", 11)
var _row := HBoxContainer.new()


func setup(session: EditorSession) -> void:
	_session = session
	_row.add_theme_constant_override("separation", 4)
	add_child(_row)
	_build_button(_undo, "Undo", "undo", _undo_caption, false, session.undo)
	_row.add_child(_undo)
	_row.add_child(UiKit.separator_v())
	_build_button(_redo, "Redo", "redo", _redo_caption, true, session.redo)
	_row.add_child(_redo)
	_cancel.pressed.connect(session.cancel_active)
	_cancel.visible = false
	_row.add_child(_cancel)
	for signal_ref: Signal in [session.status_changed, session.world_replaced, session.tools.operation_started,
			session.tools.operation_finished, session.tools.operation_cancelled]:
		signal_ref.connect(_on_any_signal)
	refresh(session.status())


func _on_any_signal(_a: Variant = null) -> void:
	refresh(_session.status())


static func _build_button(b: Button, title: String, icon_name: String, caption: Label, mirrored: bool,
		on_pressed: Callable) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(BUTTON_WIDTH, UiKit.MIN_HEIGHT)
	b.pressed.connect(on_pressed)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	row.offset_right = -12
	var icon := UiKit.icon_rect(icon_name, Vector2(20, 20))
	var labels := VBoxContainer.new()
	labels.add_theme_constant_override("separation", 0)
	labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	labels.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := UiKit.bold_label(title, 14)
	caption.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	caption.clip_text = true
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.custom_minimum_size.x = CAPTION_WIDTH
	var alignment := HORIZONTAL_ALIGNMENT_RIGHT if mirrored else HORIZONTAL_ALIGNMENT_LEFT
	for l: Label in [head, caption]:
		l.horizontal_alignment = alignment
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(l)
	if mirrored:
		row.add_child(labels)
		row.add_child(icon)
	else:
		row.add_child(icon)
		row.add_child(labels)
	b.add_child(row)


func undo_button() -> Button:
	return _undo


func redo_button() -> Button:
	return _redo


func cancel_button() -> Button:
	return _cancel


func undo_caption() -> Label:
	return _undo_caption


func redo_caption() -> Label:
	return _redo_caption


## Pill width without the Cancel button, so the pill's left edge does not move when Cancel appears.
func base_width() -> float:
	var w := get_combined_minimum_size().x
	if _cancel.visible:
		w -= _cancel.get_combined_minimum_size().x + float(_row.get_theme_constant("separation"))
	return w


func refresh(status: Dictionary) -> void:
	if _session == null:
		return
	var editing := bool(status.editing_enabled)
	var busy := _session.tools.has_active_operation()
	_set_action(_undo, _undo_caption, str(status.undo_label), editing and bool(status.can_undo) and not busy)
	_set_action(_redo, _redo_caption, str(status.redo_label), editing and bool(status.can_redo) and not busy)
	_cancel.visible = busy
	_cancel.disabled = not editing
	reset_size()


static func _set_action(b: Button, caption: Label, label: String, enabled: bool) -> void:
	caption.text = label if label != "" else "Nothing"
	b.tooltip_text = label
	b.disabled = not enabled
	b.modulate.a = 1.0 if enabled else 0.4
