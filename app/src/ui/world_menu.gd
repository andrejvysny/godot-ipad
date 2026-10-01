class_name WorldMenu
extends PanelContainer
## Top-left pill: world name with a dropdown (open template, save checkpoint, diagnostics,
## handedness) and the save-status indicator. The dropdown panel is a separate Control that
## EditorUI places and registers (menu_panel()).

const WORLD_NAMES := {"flat": "Flat", "gentle_hills": "Gentle Hills", "stress_100": "Stress 100"}
const NOTES := {"flat": "Level ground", "gentle_hills": "Rolling terrain", "stress_100": "100 objects"}
const MENU_WIDTH := 280.0
const SAVE_TEXT_MAX := 260.0

var _session: EditorSession
var _confirm: ConfirmDialog
var _diagnostics: DiagnosticsOverlay
var _on_left_handed := Callable()
var _world := UiKit.button("", Callable(), true)
var _dot := UiKit.icon_rect("dot", Vector2(8, 8))
var _save_label := UiKit.label("", 13)
var _menu := UiKit.variant_panel("StrongPanel")
var _items: Dictionary = {}  # id -> Button


func setup(session: EditorSession, confirm: ConfirmDialog, diagnostics: DiagnosticsOverlay,
		on_left_handed: Callable) -> void:
	_session = session
	_confirm = confirm
	_diagnostics = diagnostics
	_on_left_handed = on_left_handed
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	_build_world_button()
	row.add_child(_world)
	row.add_child(UiKit.separator_v())
	row.add_child(_build_save_group())
	_build_menu()
	_menu.visible = false
	session.tools.operation_started.connect(func(_tool: String) -> void: close())
	for signal_ref: Signal in [session.status_changed, session.world_replaced]:
		signal_ref.connect(func() -> void: refresh(session.status()))
	refresh(session.status())


func _build_world_button() -> void:
	_world.theme_type_variation = "SurfaceButton"
	_world.add_theme_font_override("font", UiKit.bold_font())
	_world.add_theme_font_size_override("font_size", 16)
	_world.icon = UiKit.icon("chevron_down")
	_world.add_theme_constant_override("icon_max_width", 16)
	_world.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_world.add_theme_constant_override("h_separation", 10)
	_world.toggled.connect(func(on: bool) -> void: _menu.visible = on)


func _build_save_group() -> Control:
	var group := HBoxContainer.new()
	group.add_theme_constant_override("separation", 8)
	group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_save_label.add_theme_color_override("font_color", UiKit.TEXT_SECONDARY)
	_save_label.clip_text = true
	_save_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_save_label.mouse_filter = Control.MOUSE_FILTER_STOP
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_child(_save_label)
	group.add_child(_dot)
	group.add_child(margin)
	return group


func _build_menu() -> void:
	_menu.custom_minimum_size.x = MENU_WIDTH
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	_menu.add_child(column)
	var header := UiKit.bold_label("OPEN TEMPLATE", 11, UiKit.TEXT_MUTED)
	column.add_child(header)
	for id: String in SessionWorldOps.FIXTURES:
		var b := UiKit.variant_button(WORLD_NAMES.get(id, id), "MenuRow", _ask_open.bind(id))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_add_note(b, NOTES.get(id, ""))
		column.add_child(b)
		_items[id] = b
	column.add_child(UiKit.separator_h())
	var save := UiKit.variant_button("Save checkpoint now", "MenuRow", _save)
	save.alignment = HORIZONTAL_ALIGNMENT_LEFT
	column.add_child(save)
	_items["save"] = save
	_items["diagnostics"] = _switch_row(column, "Diagnostics", _toggle_diagnostics)
	_items["left_handed"] = _switch_row(column, "Left-handed layout", _toggle_left_handed)
	var note := UiKit.label("Opening a template saves this world first, then clears undo history.", 12)
	note.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = MENU_WIDTH - 24.0
	column.add_child(note)


static func _add_note(b: Button, text: String) -> void:
	var note := UiKit.label(text, 12)
	note.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	note.offset_right = -12
	b.add_child(note)


## Full-width row whose switch icon sits at the right edge.
static func _switch_row(parent: Control, text: String, on_toggled: Callable) -> Button:
	var b := UiKit.variant_button(text, "MenuRow", Callable(), true)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var hover := StyleBoxFlat.new()
	hover.bg_color = UiKit.SURFACE_HOVER
	hover.set_corner_radius_all(10)
	hover.content_margin_left = 12
	hover.content_margin_right = 12
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("hover_pressed", hover)
	b.add_theme_color_override("font_pressed_color", UiKit.TEXT)
	b.add_theme_color_override("font_hover_pressed_color", UiKit.TEXT)
	var knob := UiKit.icon_rect("switch_off", Vector2(30, 18))
	knob.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	knob.offset_left = -42
	knob.offset_right = -12
	knob.offset_top = -9
	knob.offset_bottom = 9
	b.add_child(knob)
	b.toggled.connect(func(on: bool) -> void:
		knob.texture = UiKit.icon("switch_on" if on else "switch_off")
		on_toggled.call(on))
	parent.add_child(b)
	return b


func _ask_open(id: String) -> void:
	close()
	var caption: String = WORLD_NAMES.get(id, id)
	_confirm.ask("Open %s?" % caption,
			"The current world is saved first, then replaced by a new working copy. Undo history is cleared.",
			"Open", func() -> void:
				_session.open_fixture(id))


func _save() -> void:
	close()
	_session.save_now()


func _toggle_diagnostics(on: bool) -> void:
	_diagnostics.visible = on
	_diagnostics.refresh(true)


func _toggle_left_handed(on: bool) -> void:
	if _on_left_handed.is_valid():
		_on_left_handed.call(on)


# --- API -----------------------------------------------------------------------------------

func world_button() -> Button:
	return _world


## id: a fixture id, "save", "diagnostics" or "left_handed"
func item(id: String) -> Button:
	return _items[id]


func menu_panel() -> Control:
	return _menu


func save_label() -> Label:
	return _save_label


func close() -> void:
	_menu.visible = false
	_world.set_pressed_no_signal(false)


## Keeps the handedness switch in step when the layout is changed from code.
func sync_left_handed(on: bool) -> void:
	var b: Button = _items["left_handed"]
	if b.button_pressed != on:
		b.set_pressed_no_signal(on)
		(b.get_child(0) as TextureRect).texture = UiKit.icon("switch_on" if on else "switch_off")


static func world_name(source_label: String) -> String:
	if source_label.begins_with("fixture:"):
		return WORLD_NAMES.get(source_label.trim_prefix("fixture:"), "World")
	return "Recovered world" if source_label == "recovered" else "World"


func refresh(status: Dictionary) -> void:
	if _session == null or _session.document == null:
		return
	_world.text = world_name(_session.document.source_label)
	var text := str(status.save_text)
	_save_label.text = text
	_save_label.tooltip_text = text
	var font := _save_label.get_theme_font("font")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	_save_label.custom_minimum_size.x = minf(ceilf(width), SAVE_TEXT_MAX)
	_dot.modulate = _dot_color(str(status.save_state.state), text)
	var editing := bool(status.editing_enabled)
	var busy := _session.tools.has_active_operation()
	for id: String in ["save"] + Array(SessionWorldOps.FIXTURES):
		(_items[id] as Button).disabled = not editing or busy


## The job state alone says "saved" after later edits too; the text knows the current revision.
static func _dot_color(state: String, text: String) -> Color:
	match state:
		WorldStorage.STATE_SAVING:
			return UiKit.ACCENT
		WorldStorage.STATE_FAILED:
			return UiKit.FAILED_DOT
	return UiKit.SAVED_DOT if text.begins_with("Saved") else UiKit.TEXT_MUTED
