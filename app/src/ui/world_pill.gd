class_name WorldPill
extends PanelContainer
## Top-left pill (docs/editor-v2.md §9): save dot, world name and a chevron. Pressing it toggles the
## world menu, which EditorUI places and registers.

signal toggled(open: bool)

const HEIGHT := 38.0
const PADDING := 10.0

var _session: EditorSession
var _button := UiKit.variant_button("", "PillButton", Callable(), true)
var _row := HBoxContainer.new()
var _dot := UiKit.icon_rect("dot", Vector2(7, 7))
var _label := UiKit.bold_label("", 13)


func setup(session: EditorSession) -> void:
	_session = session
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.PANEL_BG, 12, 3))
	_row.add_theme_constant_override("separation", 7)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Control in [_dot, _label, UiKit.icon_rect("chevron_down", Vector2(9, 9))]:
		_row.add_child(c)
	_button.add_child(_row)
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_row.offset_left = PADDING
	_row.offset_right = -PADDING
	_button.toggled.connect(func(on: bool) -> void: toggled.emit(on))
	add_child(_button)
	refresh(session.status())


func world_button() -> Button:
	return _button


func name_text() -> String:
	return _label.text


## Keeps the pressed state in step with the menu, which can also close itself.
func set_open(on: bool) -> void:
	_button.set_pressed_no_signal(on)


func dot_color() -> Color:
	return _dot.modulate


func refresh(status: Dictionary) -> void:
	if _session == null or _session.document == null:
		return
	_label.text = WorldMenu.world_name(_session.document.source_label)
	_dot.modulate = _dot_color(str(status.save_state.state), str(status.save_text))
	UiKit.fit_content_button(_button, _row, PADDING, HEIGHT)
	reset_size()


## The job state alone says "saved" after later edits too; the text knows the current revision.
static func _dot_color(state: String, text: String) -> Color:
	match state:
		WorldStorage.STATE_SAVING:
			return UiKit.ACCENT
		WorldStorage.STATE_FAILED:
			return UiKit.FAILED_DOT
	return UiKit.SAVED_DOT if text.begins_with("Saved") else UiKit.TEXT_MUTED
