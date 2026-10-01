class_name WorldMenu
extends PanelContainer
## Dropdown of the world pill (docs/editor-v2.md §9): save status, open template (with confirmation),
## save checkpoint, reset camera, and the Diagnostics and Left-handed switches. EditorUI places and
## registers it.

const WORLD_NAMES := {"flat": "Flat", "gentle_hills": "Gentle Hills", "stress_100": "Stress 100"}
const NEW_WORLD_ITEMS := {"new_km1_flat": "flat", "new_km1_hills": "hills"}  # menu id -> SessionWorldOps kind
const WIDTH := 240.0
const ROW_HEIGHT := 40.0

var _session: EditorSession
var _confirm: ConfirmDialog
var _diagnostics: DiagnosticsOverlay
var _on_left_handed := Callable()
var _save_label := UiKit.label("", 10)
var _items: Dictionary = {}  # id -> Button


func setup(session: EditorSession, confirm: ConfirmDialog, diagnostics: DiagnosticsOverlay,
		on_left_handed: Callable) -> void:
	_session = session
	_confirm = confirm
	_diagnostics = diagnostics
	_on_left_handed = on_left_handed
	var box := UiKit.pill_box(Color(UiKit.PANEL_BG, 0.96), 12, 6)
	box.shadow_size = 12
	box.shadow_color = Color(0, 0, 0, 0.35)
	add_theme_stylebox_override("panel", box)
	custom_minimum_size.x = WIDTH
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	add_child(column)
	_save_label.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_save_label.clip_text = true
	_save_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_save_label)
	for id: String in SessionWorldOps.FIXTURES:
		_items[id] = _row(column, "Open template: %s" % WORLD_NAMES.get(id, id), _ask_open.bind(id))
	for id: String in NEW_WORLD_ITEMS:
		_items[id] = _row(column, "New 1 km world (%s)" % NEW_WORLD_ITEMS[id], _ask_new.bind(NEW_WORLD_ITEMS[id]))
	_items["save"] = _row(column, "Save checkpoint now", _save)
	_items["reset_camera"] = _row(column, "Reset camera", _reset_camera)
	_items["diagnostics"] = _switch_row(column, "Diagnostics", _toggle_diagnostics)
	_items["left_handed"] = _switch_row(column, "Left-handed layout", _toggle_left_handed)
	visible = false
	session.tools.operation_started.connect(func(_tool: String) -> void: close())
	refresh(session.status())


static func _row(parent: Control, text: String, on_pressed: Callable) -> Button:
	var b := UiKit.variant_button(text, "MenuRow", on_pressed)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size.y = ROW_HEIGHT
	b.add_theme_font_size_override("font_size", 13)
	parent.add_child(b)
	return b


## Full-width row whose switch icon sits at the right edge.
static func _switch_row(parent: Control, text: String, on_toggled: Callable) -> Button:
	var b := _row(parent, text, Callable())
	b.toggle_mode = true
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
	return b


func _ask_open(id: String) -> void:
	close()
	var caption: String = WORLD_NAMES.get(id, id)
	_confirm.ask("Open %s?" % caption,
			"The current world is saved first, then replaced by a new working copy. Undo history is cleared.",
			"Open", func() -> void:
				_session.open_fixture(id))


func _ask_new(kind: String) -> void:
	close()
	_confirm.ask("Create a new 1 km world (%s)?" % kind,
			"The current world is saved first, then replaced by a new 1 km world. Undo history is cleared.",
			"Create", func() -> void:
				_session.open_new_world(kind))


func _save() -> void:
	close()
	_session.save_now()


func _reset_camera() -> void:
	close()
	_session.reset_camera()
	_session.post_message("Camera reset")


func _toggle_diagnostics(on: bool) -> void:
	_diagnostics.visible = on
	_diagnostics.refresh(true)


func _toggle_left_handed(on: bool) -> void:
	if _on_left_handed.is_valid():
		_on_left_handed.call(on)


# --- API -----------------------------------------------------------------------------------

## id: a fixture id, "new_km1_flat", "new_km1_hills", "save", "reset_camera", "diagnostics" or "left_handed"
func item(id: String) -> Button:
	return _items[id]


func save_label() -> Label:
	return _save_label


func close() -> void:
	visible = false


func toggle_open(on: bool) -> void:
	visible = on


## Keeps the handedness switch in step when the layout is changed from code.
func sync_left_handed(on: bool) -> void:
	var b: Button = _items["left_handed"]
	if b.button_pressed != on:
		b.set_pressed_no_signal(on)
		(b.get_child(0) as TextureRect).texture = UiKit.icon("switch_on" if on else "switch_off")


static func world_name(source_label: String) -> String:
	if source_label.begins_with("fixture:"):
		return WORLD_NAMES.get(source_label.trim_prefix("fixture:"), "World")
	if source_label.begins_with("new:km1-"):
		return "1 km world"
	return "Recovered world" if source_label == "recovered" else "World"


## Storage text "Saved revision N" shown as "Saved · revision N" (docs/editor-v2.md §9); the rest is as is.
static func save_caption(storage_text: String) -> String:
	return "Saved · revision " + storage_text.trim_prefix("Saved revision ") if storage_text.begins_with("Saved revision ") \
			else storage_text


func refresh(status: Dictionary) -> void:
	if _session == null or _session.document == null:
		return
	var text := save_caption(str(status.save_text))
	_save_label.text = text
	_save_label.tooltip_text = text
	var editing := _session.input.editing_enabled()
	var busy := _session.tools.has_active_operation()
	for id: String in ["save"] + Array(SessionWorldOps.FIXTURES) + NEW_WORLD_ITEMS.keys():
		(_items[id] as Button).disabled = not editing or busy
