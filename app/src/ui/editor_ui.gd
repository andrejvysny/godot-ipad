class_name EditorUI
extends CanvasLayer
## Pencil-operated editor interface (spec §9): status row, tool rail, context tool panel, asset
## strip, open-fixture menu with confirmation, diagnostics overlay. Controls react to Godot GUI
## events only (on iOS the synthetic Pencil mouse events of InputSystem); nothing here reads raw
## input. Every panel is registered with UiHitTester so the world never sees input over it.

const FIXTURE_NAMES := {"flat": "Flat", "gentle_hills": "Gentle Hills", "stress_100": "Stress 100 (100 objects)"}
const TOOL_CAPTIONS := {"select": "Select", "place": "Place", "paint": "Paint", "sculpt": "Sculpt", "path": "Path"}
const MESSAGE_SECONDS := 6.0
const ERROR_COLOR := Color(1.0, 0.45, 0.4)

var _session: EditorSession
var _root := Control.new()
var _tool_label := _status_label(4.0)
var _revision_label := _status_label(3.0)
var _message_label := _status_label(3.0)
var _input_label := _status_label(3.0)
var _diag_button: Button
var _status_row := UiKit.panel()
var _rail := UiKit.panel()
var _tool_buttons: Dictionary = {}
var _actions: Dictionary = {}  # caption -> Button
var _tool_panel := ToolPanel.new()
var _asset_strip := AssetStrip.new()
var _diagnostics := DiagnosticsOverlay.new()
var _open_menu := UiKit.panel()
var _confirm := ConfirmDialog.new()
var _message_timer := Timer.new()


func setup(session: EditorSession) -> void:
	_session = session
	layer = 10
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UiKit.make_theme()
	add_child(_root)
	_build_status_row()
	_build_rail()
	_build_open_menu()
	for panel: Control in [_tool_panel, _asset_strip, _diagnostics]:
		_root.add_child(panel)
		session.input.ui_hits.register(panel)
	_tool_panel.setup(session)
	_asset_strip.setup(session)
	_diagnostics.setup(session)
	_root.add_child(_confirm)
	_confirm.setup(session)
	_connect_signals()
	_message_timer.one_shot = true
	_message_timer.timeout.connect(func() -> void: _message_label.text = "")
	add_child(_message_timer)
	if session.last_message != "":
		_show_message(session.last_message, session.last_message_is_error)
	refresh()
	_arm_screenshot()


static func _status_label(ratio: float) -> Label:
	var l := UiKit.label("", 15)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_stretch_ratio = ratio
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


## Controls whose screen rect blocks world input; the open menu and dialog only while visible.
func registered_panels() -> Array[Control]:
	var out: Array[Control] = [_status_row, _rail, _tool_panel, _asset_strip, _diagnostics, _open_menu]
	return out


func asset_strip() -> AssetStrip:
	return _asset_strip


func confirm_dialog() -> ConfirmDialog:
	return _confirm


func tool_panel() -> ToolPanel:
	return _tool_panel


func diagnostics_overlay() -> DiagnosticsOverlay:
	return _diagnostics


func diag_button() -> Button:
	return _diag_button


func action_button(caption: String) -> Button:
	return _actions[caption]


func tool_button(tool_id: String) -> Button:
	return _tool_buttons[tool_id]


func tool_label() -> Label:
	return _tool_label


func revision_label() -> Label:
	return _revision_label


func open_menu_button(caption: String) -> Button:
	return _open_menu.get_meta("buttons")[caption]


# --- construction --------------------------------------------------------------------------

func _build_status_row() -> void:
	_root.add_child(_status_row)
	_session.input.ui_hits.register(_status_row)
	_status_row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_status_row.offset_bottom = 44
	_status_row.add_theme_stylebox_override("panel", _row_style())
	var row := HBoxContainer.new()
	_status_row.add_child(row)
	for l: Label in [_tool_label, _revision_label, _message_label, _input_label]:
		row.add_child(l)
	_diag_button = UiKit.button("Diag", Callable(), true, 72)
	_diag_button.custom_minimum_size.y = 34
	_diag_button.toggled.connect(func(on: bool) -> void:
		_diagnostics.visible = on
		_diagnostics.refresh(true))
	row.add_child(_diag_button)


static func _row_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = UiKit.PANEL_BG
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


func _build_rail() -> void:
	_root.add_child(_rail)
	_session.input.ui_hits.register(_rail)
	_rail.position = Vector2(0, 52)
	_rail.custom_minimum_size.x = 132
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	_rail.add_child(column)
	var group := ButtonGroup.new()
	for id in ToolController.TOOLS:
		var b := UiKit.button(TOOL_CAPTIONS[id], _choose_tool.bind(id), true, 116)
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		column.add_child(b)
		_tool_buttons[id] = b
	column.add_child(HSeparator.new())
	var entries := [["Undo", _session.undo], ["Redo", _session.redo], ["Cancel", _session.cancel_active],
		["Save", _session.save_now], ["Export", _session.export_world], ["Open…", _toggle_open_menu],
		["Reset view", _session.reset_camera], ["Focus", _session.focus_selection]]
	for entry: Array in entries:
		var b := UiKit.button(entry[0], entry[1], false, 116)
		column.add_child(b)
		_actions[entry[0]] = b


func _build_open_menu() -> void:
	_root.add_child(_open_menu)
	_session.input.ui_hits.register(_open_menu)
	_open_menu.visible = false
	var column := VBoxContainer.new()
	_open_menu.add_child(column)
	var buttons := {}
	for id: String in SessionWorldOps.FIXTURES:
		var caption: String = FIXTURE_NAMES.get(id, id)
		var b := UiKit.button(caption, _ask_open.bind(id), false, 240)
		column.add_child(b)
		buttons[id] = b
	var close := UiKit.button("Close", func() -> void: _open_menu.hide(), false, 240)
	column.add_child(close)
	buttons["close"] = close
	_open_menu.set_meta("buttons", buttons)


func _connect_signals() -> void:
	var tools := _session.tools
	for signal_ref: Signal in [_session.status_changed, _session.world_replaced, tools.tool_changed,
			tools.selection_changed, tools.settings_changed, tools.operation_started,
			tools.operation_finished, tools.operation_cancelled]:
		signal_ref.connect(_on_any_signal)
	_session.message_posted.connect(_show_message)


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


# --- actions -------------------------------------------------------------------------------

func _choose_tool(id: String) -> void:
	var error := _session.tools.set_active_tool(id)
	if error != "":
		_session.post_message(error, true)
	refresh()


func _toggle_open_menu() -> void:
	_open_menu.visible = not _open_menu.visible
	if _open_menu.visible:
		var anchor := _actions["Open…"] as Button
		_open_menu.position = Vector2(140, anchor.global_position.y)
		_open_menu.reset_size()
		# Stay inside the smallest supported screen height (768) even when it overlaps the tool panel.
		_open_menu.position.y = clampf(_open_menu.position.y, 52.0, 760.0 - _open_menu.size.y)


func _ask_open(id: String) -> void:
	_open_menu.hide()
	var caption: String = FIXTURE_NAMES.get(id, id)
	_confirm.ask("Open %s?" % caption,
			"The current world is saved first, then replaced by a new working copy. Undo history is cleared.",
			"Open", func() -> void: _session.open_fixture(id))


func on_ui_cancelled(reason: String) -> void:
	_tool_panel.on_ui_cancelled(reason)
	refresh()


func _show_message(text: String, is_error: bool) -> void:
	_message_label.text = ("⚠ " if is_error else "") + text
	_message_label.tooltip_text = _message_label.text
	_message_label.add_theme_color_override("font_color", ERROR_COLOR if is_error else Color.WHITE)
	_message_timer.start(MESSAGE_SECONDS)


# --- refresh -------------------------------------------------------------------------------

func refresh() -> void:
	if _session == null or _session.document == null:
		return
	var s := _session.status()
	var editing := bool(s.editing_enabled)
	var busy := _session.tools.has_active_operation()
	_tool_label.text = _tool_text(s)
	_revision_label.text = "Revision %d · %s" % [s.revision, s.save_text]
	_revision_label.tooltip_text = _revision_label.text
	var banner := str(s.banner)
	_input_label.text = str(s.provider_label) + (" · " + banner if banner != "" else "")
	_input_label.tooltip_text = _input_label.text
	for id: String in _tool_buttons:
		var b: Button = _tool_buttons[id]
		b.set_pressed_no_signal(id == s.tool)
		b.text = ("▶ " if id == s.tool else "") + TOOL_CAPTIONS[id]
		b.disabled = not editing
	_set_action_states(s, editing, busy)
	_diagnostics.refresh()


func _set_action_states(s: Dictionary, editing: bool, busy: bool) -> void:
	for caption: String in _actions:
		(_actions[caption] as Button).disabled = not editing
	(_actions["Undo"] as Button).disabled = not (editing and s.can_undo and not busy)
	(_actions["Redo"] as Button).disabled = not (editing and s.can_redo and not busy)
	for caption in ["Save", "Export", "Open…"]:
		(_actions[caption] as Button).disabled = not editing or busy
	(_actions["Open…"] as Button).set_pressed_no_signal(_open_menu.visible)
	(_actions["Undo"] as Button).tooltip_text = str(s.undo_label)
	(_actions["Redo"] as Button).tooltip_text = str(s.redo_label)


func _tool_text(s: Dictionary) -> String:
	var tools := _session.tools
	var text := "%s · %s" % [str(s.tool).to_upper(), s.stroke_state]
	var settings := tools.settings(str(s.tool))
	match s.tool:
		"paint":
			text += " · %s · r %.1f m · %d%%" % [str(settings.material).capitalize(),
				float(settings.radius), roundi(float(settings.strength) * 100.0)]
		"sculpt":
			text += " · %s · r %.1f m" % ["Raise ▲" if settings.direction == "raise" else "Lower ▼",
				float(settings.radius)]
		"path":
			text += " · width %.1f m" % float(settings.width)
		"place":
			var asset := _session.catalog.get_asset(str(settings.asset_id))
			text += " · " + (asset.display_name if asset != null else "choose asset")
	return text


# --- screenshot hook -----------------------------------------------------------------------

## Visual verification aid: `--ui-screenshot=<abs.png>` saves the window after 2 s and quits.
func _arm_screenshot() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-screenshot="):
			var path := arg.trim_prefix("--ui-screenshot=")
			get_tree().create_timer(2.0).timeout.connect(func() -> void:
				get_viewport().get_texture().get_image().save_png(path)
				get_tree().quit())
