class_name EditorUI
extends CanvasLayer
## Pencil-operated editor interface (spec §9): floating top bar (world menu, history, actions),
## tool dock, context bar, drag-and-drop Library and an inspector anchored to the selected object.
## Controls react to Godot GUI events only (on iOS the synthetic Pencil mouse events of
## InputSystem); nothing here reads raw input. Every interactive panel is registered with
## UiHitTester so the world never sees input over it; hints, toast, banner and drop hint are not,
## because a Pencil there still edits the world.

const M := 12.0
const GAP := 10.0
const TOP_H := 60.0
const HINTS_H := 36.0
const DOCK_TOP := M + TOP_H + M
const MESSAGE_SECONDS := 6.0
const TOAST_MAX_W := 560.0

var _session: EditorSession
var _root := Control.new()
var _dock := ToolDock.new()
var _context := ContextBar.new()
var _library := AssetLibrary.new()
var _inspector := ObjectInspector.new()
var _world := WorldMenu.new()
var _history := HistoryBar.new()
var _actions := UiKit.pill()
var _reset_view: Button
var _export: Button
var _hints := UiKit.pill(Color(UiKit.PANEL_BG, 0.72), 12, 4)
var _hints_row := HBoxContainer.new()
var _badge := UiKit.label("", 12)
var _hints_dev := -1
var _toast := UiKit.pill(UiKit.PANEL_BG_STRONG, 12, 10)
var _toast_label := UiKit.bold_label("", 14)
var _banner := UiKit.pill(UiKit.PANEL_BG_STRONG.blend(UiKit.DANGER_BG), 12, 10)
var _banner_label := UiKit.bold_label("", 14, UiKit.DANGER_TEXT)
var _drop_hint := UiKit.pill(UiKit.PANEL_BG_STRONG, 10, 6)
var _drop_label := UiKit.bold_label("", 13)
var _diagnostics := DiagnosticsOverlay.new()
var _confirm := ConfirmDialog.new()
var _message_timer := Timer.new()
var _left := false
var _registered: Array[Control] = []


func setup(session: EditorSession) -> void:
	_session = session
	layer = 10
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UiKit.make_theme()
	add_child(_root)
	_build_panels()
	_build_floaters()
	for c: Control in [_world.menu_panel(), _diagnostics, _confirm]:
		_root.add_child(c)
	_confirm.setup(session)
	_diagnostics.setup(session)
	_world.setup(session, _confirm, _diagnostics, set_left_handed)
	for c: Control in [_world, _history, _actions, _dock, _context, _library, _library.strip(), _inspector,
			_world.menu_panel(), _diagnostics]:
		_register(c)
	_connect_signals()
	_message_timer.one_shot = true
	_message_timer.timeout.connect(func() -> void: _toast.visible = false)
	add_child(_message_timer)
	get_viewport().size_changed.connect(layout)
	_library.open_changed.connect(func(_open: bool) -> void: layout())
	if session.last_message != "":
		_show_message(session.last_message, session.last_message_is_error)
	refresh()
	_arm_screenshot()


func _register(c: Control) -> void:
	_registered.append(c)
	_session.input.ui_hits.register(c)


func _build_panels() -> void:
	var list: Array[Control] = [_dock, _context, _library, _library.strip(), _inspector, _world, _history, _actions]
	for c in list:
		_root.add_child(c)
	_dock.setup(_session)
	_context.setup(_session)
	_library.setup(_session, _on_drop_hint)
	_inspector.setup(_session)
	_inspector.visible = false
	_history.setup(_session)
	_reset_view = UiKit.button("Reset view", _session.reset_camera, false, 110)
	_export = UiKit.variant_button("Export", "AccentButton", _session.export_world, false, 96)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_reset_view)
	row.add_child(_export)
	_actions.add_child(row)


func _build_floaters() -> void:
	_hints_row.add_theme_constant_override("separation", 0)
	_hints.add_child(_hints_row)
	_hints.custom_minimum_size.y = HINTS_H
	_toast.add_child(_toast_label)
	_banner.add_child(_banner_label)
	_drop_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drop_hint.add_child(_drop_label)
	for c: Control in [_hints, _toast, _banner, _drop_hint]:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(c)
	for l: Label in [_toast_label, _banner_label]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_banner.visible = false
	_drop_hint.visible = false


func _connect_signals() -> void:
	var tools := _session.tools
	for signal_ref: Signal in [_session.status_changed, _session.world_replaced, tools.tool_changed,
			tools.selection_changed, tools.settings_changed, tools.operation_started,
			tools.operation_finished, tools.operation_cancelled]:
		signal_ref.connect(_on_any_signal)
	_session.message_posted.connect(_show_message)


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


## Controls whose screen rect blocks world input (hidden ones never do).
func registered_panels() -> Array[Control]:
	return _registered.duplicate()


func dock() -> ToolDock:
	return _dock


func context_bar() -> ContextBar:
	return _context


func inspector() -> ObjectInspector:
	return _inspector


func library() -> AssetLibrary:
	return _library


func world_menu() -> WorldMenu:
	return _world


func history_bar() -> HistoryBar:
	return _history


func reset_view_button() -> Button:
	return _reset_view


func export_button() -> Button:
	return _export


func toast_label() -> Label:
	return _toast_label


func banner_label() -> Label:
	return _banner_label


func hints_panel() -> Control:
	return _hints


func drop_hint() -> Control:
	return _drop_hint


func confirm_dialog() -> ConfirmDialog:
	return _confirm


func diagnostics_overlay() -> DiagnosticsOverlay:
	return _diagnostics


func is_left_handed() -> bool:
	return _left


func set_left_handed(on: bool) -> void:
	_left = on
	_library.set_side_left(on)
	_world.sync_left_handed(on)
	layout()


func on_ui_cancelled(reason: String) -> void:
	_context.on_ui_cancelled(reason)
	_inspector.on_ui_cancelled(reason)
	_library.on_ui_cancelled(reason)
	refresh()


# --- messages ------------------------------------------------------------------------------

func _show_message(text: String, is_error: bool) -> void:
	_toast_label.text = text
	_toast_label.tooltip_text = text
	_toast_label.add_theme_color_override("font_color", UiKit.DANGER_TEXT if is_error else UiKit.TEXT)
	var width := UiKit.bold_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	_toast_label.custom_minimum_size.x = minf(ceilf(width) + 2.0, TOAST_MAX_W)
	_toast.visible = true
	_toast.reset_size()
	_message_timer.start(MESSAGE_SECONDS)
	layout()


func _on_drop_hint(text: String, pos: Vector2, valid: bool) -> void:
	_drop_hint.visible = text != ""
	if text == "":
		return
	_drop_label.text = text
	_drop_label.add_theme_color_override("font_color", UiKit.ACCENT if valid else UiKit.DANGER_TEXT)
	_drop_hint.reset_size()
	_drop_hint.position = pos + Vector2(24, -50)


# --- refresh -------------------------------------------------------------------------------

func refresh() -> void:
	if _session == null or _session.document == null:
		return
	var s := _session.status()
	_dock.refresh(s)
	_refresh_banner(str(s.banner))
	_refresh_hints(bool(s.development_input), str(s.provider_label))
	_inspector.visible = _inspector_wanted()
	_diagnostics.refresh()
	layout()


func _refresh_banner(text: String) -> void:
	_banner.visible = text != ""
	_banner_label.text = "Editing disabled: " + text
	var width := UiKit.bold_font().get_string_size(_banner_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	_banner_label.custom_minimum_size.x = minf(ceilf(width) + 2.0, TOAST_MAX_W)


func _inspector_wanted() -> bool:
	var tools := _session.tools
	if tools.active_tool() != ToolController.TOOL_SELECT or tools.selected_id() == "":
		return false
	return not (tools.has_active_operation() and not tools.has_object_edit())


func _refresh_hints(development: bool, provider: String) -> void:
	_badge.text = provider
	_badge.add_theme_color_override("font_color", UiKit.ACCENT if development else UiKit.TEXT_MUTED)
	if int(development) == _hints_dev:
		return
	_hints_dev = int(development)
	for child in _hints_row.get_children():
		_hints_row.remove_child(child)
		if child != _badge:
			child.queue_free()
	var runs: Array = [["Click", "k"], [" edits  ·  ", "p"], ["right-drag", "k"], [" orbit  ·  ", "p"],
			["middle-drag", "k"], [" pan  ·  ", "p"], ["wheel", "k"], [" zoom  ·  ", "p"], ["Esc", "k"], [" cancels", "p"]] \
			if development else [["1 finger", "k"], [" orbit  ·  ", "p"], ["2 fingers", "k"], [" pan  ·  ", "p"],
			["pinch", "k"], [" zoom  ·  ", "p"], ["Pencil", "a"], [" edits & taps", "p"]]
	for run: Array in runs:
		_hints_row.add_child(_hint_run(run[0], run[1]))
	_hints_row.add_child(_hint_run("  ·  ", "p"))
	_hints_row.add_child(_badge)
	_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_badge.add_theme_font_override("font", UiKit.bold_font())


static func _hint_run(text: String, style: String) -> Label:
	var l := UiKit.label(text, 12)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match style:
		"k":
			l.add_theme_font_override("font", UiKit.bold_font())
			l.add_theme_color_override("font_color", Color.WHITE)
		"a":
			l.add_theme_font_override("font", UiKit.bold_font())
			l.add_theme_color_override("font_color", UiKit.ACCENT)
		_:
			l.add_theme_color_override("font_color", UiKit.TEXT_SECONDARY)
	return l


# --- layout --------------------------------------------------------------------------------

static func _fit(c: Control) -> void:
	c.reset_size()


func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


## Explicit positions of every panel; idempotent, so it may run on any change.
func layout() -> void:
	if _session == null:
		return
	var vp := _viewport_size()
	_layout_top(vp)
	var lib_w := AssetLibrary.WIDTH if _library.is_open() else AssetLibrary.STRIP_WIDTH
	var side: Control = _library if _library.is_open() else _library.strip()
	_fit(_dock)
	_fit(_library.strip())
	if _library.is_open():
		_library.size = Vector2(lib_w, vp.y - DOCK_TOP - M)
	var side_x := M if _left else vp.x - M - lib_w
	side.position = Vector2(side_x, DOCK_TOP)
	_dock.position = Vector2(vp.x - M - _dock.size.x if _left else M, DOCK_TOP)
	_layout_context(side_x, lib_w)
	_fit(_hints)
	_hints.position = Vector2(_dock_side_x(_hints.size.x), vp.y - M - HINTS_H)
	_world.menu_panel().position = Vector2(M, DOCK_TOP)
	_world.menu_panel().reset_size()
	_layout_floaters()


func _dock_side_x(width: float) -> float:
	return _dock.position.x - GAP - width if _left else _dock.position.x + _dock.size.x + GAP


func _layout_top(vp: Vector2) -> void:
	for c: Control in [_world, _history, _actions]:
		_fit(c)
	_world.position = Vector2(M, M)
	_actions.position = Vector2(vp.x - M - _actions.size.x, M)
	var w := _history.base_width()
	var lo := _world.position.x + _world.size.x + GAP
	var hi := _actions.position.x - GAP - w
	_history.position = Vector2(maxf(lo, minf(vp.x * 0.5 - w * 0.5, hi)), M)


func _layout_context(side_x: float, side_w: float) -> void:
	var dock_left := _dock.position.x
	var dock_right := dock_left + _dock.size.x
	if _left:
		var limit := side_x + side_w + GAP
		_context.fit_width(minf(560.0, dock_left - GAP - limit))
		_context.position = Vector2(dock_left - GAP - _context.size.x, DOCK_TOP)
	else:
		var start := dock_right + GAP
		_context.fit_width(minf(560.0, side_x - GAP - start))
		_context.position = Vector2(start, DOCK_TOP)


## Elements whose height depends on wrapped text; also run every frame.
func _layout_floaters() -> void:
	var vp := _viewport_size()
	var lib_w := AssetLibrary.WIDTH if _library.is_open() else AssetLibrary.STRIP_WIDTH
	var region_lo := M + lib_w + GAP if _left else _dock.position.x + _dock.size.x + GAP
	var region_hi := _dock.position.x - GAP if _left else vp.x - M - lib_w - GAP
	var bottom := _hints.position.y - GAP
	for c: Control in [_banner, _toast]:
		if not c.visible:
			continue
		c.size = c.get_combined_minimum_size()
		c.position = Vector2((region_lo + region_hi - c.size.x) * 0.5, bottom - c.size.y)
		bottom = c.position.y - GAP
	_diagnostics.position = Vector2(M if _left else vp.x - M - _diagnostics.size.x, DOCK_TOP)


func _process(_delta: float) -> void:
	if _session == null:
		return
	_layout_floaters()
	if _inspector.visible and _session.input.router.state() != InputRouter.State.PENCIL_UI:
		_place_inspector()


func _place_inspector() -> void:
	var vp := _viewport_size()
	var lib_w := AssetLibrary.WIDTH if _library.is_open() else AssetLibrary.STRIP_WIDTH
	var x0 := M + lib_w + GAP if _left else _dock.position.x + _dock.size.x + GAP
	var x1 := _dock.position.x - GAP if _left else vp.x - M - lib_w - GAP
	var y0 := maxf(DOCK_TOP, _context.position.y + _context.size.y + GAP)
	var free := Rect2(x0, y0, x1 - x0, _hints.position.y - GAP - y0)
	var anchor := _object_anchor()
	if anchor.position == Vector2.INF:
		_inspector.position = free.position
		return
	_inspector.place(anchor, free, not _left)


## Screen rect of the selected object's world bounds, or a rect at INF when it is not visible.
func _object_anchor() -> Rect2:
	var camera := _session.rig.get_camera()
	var bounds := _session.presenter.world_bounds(_session.tools.selected_id())
	var rect := Rect2()
	for i in 8:
		var corner := bounds.get_endpoint(i)
		if camera == null or camera.is_position_behind(corner):
			return Rect2(Vector2.INF, Vector2.ZERO)
		var p := camera.unproject_position(corner)
		rect = Rect2(p, Vector2.ZERO) if i == 0 else rect.expand(p)
	return rect


# --- screenshot hook -----------------------------------------------------------------------

## Visual verification aid: `--ui-screenshot=<abs.png>` saves the window after 2 s and quits.
func _arm_screenshot() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-screenshot="):
			var path := arg.trim_prefix("--ui-screenshot=")
			get_tree().create_timer(2.0).timeout.connect(func() -> void:
				get_viewport().get_texture().get_image().save_png(path)
				get_tree().quit())
