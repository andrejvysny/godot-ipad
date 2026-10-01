class_name EditorUI
extends CanvasLayer
## Pencil-operated Editor v2 interface (docs/editor-v2.md §9): top bar (world pill and menu, history tiles,
## actions), mode rail with the tool popover, active-tool chip, gesture hints, toasts, object inspector
## and placement ghost label, plus the Library. Controls react to Godot GUI events only (on iOS the
## synthetic Pencil mouse events of InputSystem); nothing here reads raw input. Every interactive panel is
## registered with UiHitTester so the world never sees input over it; hints, toast, banner and the ghost
## label are not, because a Pencil there still edits the world.

const M := 10.0
const GAP := 10.0
const TOP_Y := 62.0
const RAIL_GAP := 6.0
const BANNER_MAX_W := 560.0
const GHOST_LABEL_OFFSET := Vector2(22, -58)

## Tests: lay the panels out as if the viewport had this size (zero = the real one).
var layout_override := Vector2.ZERO
## Called with the scatter source ("set:<id>" or "mix") when the popover asks to edit or save a set.
var edit_set_hook := Callable()

var _session: EditorSession
var _root := Control.new()
var _pill := WorldPill.new()
var _menu := WorldMenu.new()
var _history := HistoryTiles.new()
var _actions := ActionPill.new()
var _rail := ModeRail.new()
var _popover := ToolPopover.new()
var _chip := ToolChip.new()
var _hints := GestureHints.new()
var _toast := Toast.new()
var _ghost_label := GhostLabel.new()
var _library := AssetLibrary.new()
var _set_editor := SetEditor.new()
var _inspector := ObjectInspector.new()
var _banner := UiKit.pill(UiKit.PANEL_BG_STRONG.blend(UiKit.DANGER_BG), 12, 10)
var _banner_label := UiKit.bold_label("", 14, UiKit.DANGER_TEXT)
var _diagnostics := DiagnosticsOverlay.new()
var _confirm := ConfirmDialog.new()
var _left := false
var _registered: Array[Control] = []
var _region := Vector2(M, 1000.0)  # horizontal span free of the rail, popover and Library


func setup(session: EditorSession) -> void:
	_session = session
	layer = 10
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UiKit.make_theme()
	add_child(_root)
	_banner.add_child(_banner_label)
	_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Control in [_library, _rail, _popover, _inspector, _chip, _hints, _ghost_label, _toast, _banner, _pill,
			_history, _actions, _menu, _diagnostics, _set_editor, _confirm]:
		_root.add_child(c)
	_setup_components(session)
	_banner.visible = false
	for c: Control in [_pill, _menu, _history, _actions, _rail, _popover, _chip, _library, _inspector, _diagnostics, _set_editor]:
		_registered.append(c)
		session.input.ui_hits.register(c)
	_connect_signals()
	get_viewport().size_changed.connect(layout)
	if session.last_message != "":
		_toast.show_message(session.last_message, session.last_message_is_error)
	refresh()
	UiScreenshot.arm(self, session)


func _setup_components(session: EditorSession) -> void:
	_confirm.setup(session)
	_diagnostics.setup(session)
	_library.setup(session)
	_set_editor.setup(session, _library)
	_inspector.setup(session)
	_inspector.visible = false
	_popover.setup(session)
	_rail.setup(session, _popover)
	_chip.setup(session)
	_history.setup(session)
	_actions.setup(session, _library)
	_pill.setup(session)
	_menu.setup(session, _confirm, _diagnostics, set_left_handed)


func _connect_signals() -> void:
	var tools := _session.tools
	for signal_ref: Signal in [_session.status_changed, _session.world_replaced, tools.tool_changed,
			tools.selection_changed, tools.settings_changed, tools.operation_started,
			tools.operation_finished, tools.operation_cancelled]:
		signal_ref.connect(_on_any_signal)
	_session.message_posted.connect(_toast.show_message)
	tools.dismissed.connect(_menu.close)
	_pill.toggled.connect(_menu.toggle_open)
	_menu.visibility_changed.connect(func() -> void: _pill.set_open(_menu.visible))
	_chip.tapped.connect(_popover.toggle)
	_popover.change_requested.connect(_on_change_source)
	_popover.edit_set_requested.connect(_on_edit_set)
	_library.edit_set_requested.connect(_on_library_edit)
	_library.quick_mix_used.connect(func() -> void: _popover.set_open(true))
	_library.open_changed.connect(func(_open: bool) -> void: layout())
	_popover.opened_changed.connect(func(_open: bool) -> void: layout())


func _on_any_signal(_a: Variant = null) -> void:
	refresh()


## "Change" of the source card: the Library on the tab that holds the current source.
func _on_change_source(source: String) -> void:
	_library.set_open(true)
	_library.show_tab("sets" if source.begins_with("set:") else "objects")


## Popover "Edit set" / "Save as set": a hook (if installed) or the set editor.
func _on_edit_set(source: String) -> void:
	if edit_set_hook.is_valid():
		edit_set_hook.call(source)
	elif source.begins_with("set:") and not _session.tools.set_store().get_set(source.trim_prefix("set:")).is_empty():
		_set_editor.open_set(_session.tools.set_store().get_set(source.trim_prefix("set:")), false)
	else:
		_set_editor.open_set(_mix_draft(), true)


## "" opens a blank new set, otherwise the store set with that id.
func _on_library_edit(set_id: String) -> void:
	var existing := _session.tools.set_store().get_set(set_id)
	if existing.is_empty():
		_set_editor.open_set(_blank_draft(), true)
	else:
		_set_editor.open_set(existing, false)


func _blank_draft() -> Dictionary:
	return {"id": _session.tools.set_store().new_set_id(), "name": "New set",
			"items": [{"asset_id": "nature.cover.grass_tuft_a", "weight": 5.0}], "density": 1.0, "spacing": 0.6,
			"slope_min": 0.0, "slope_max": 40.0, "align": true}


## New set prefilled from the quick mix (the resolved scatter source, §6).
func _mix_draft() -> Dictionary:
	var config := _session.tools.scatter_config()
	var draft := _blank_draft()
	if not (config.items as Array).is_empty():
		draft.items = (config.items as Array).duplicate(true)
		draft.density = config.density
		draft.spacing = config.spacing
		draft.slope_min = config.slope_min
		draft.slope_max = config.slope_max
		draft.align = config.align
	return draft


# --- accessors -----------------------------------------------------------------------------

## Controls whose screen rect blocks world input (hidden ones never do).
func registered_panels() -> Array[Control]:
	return _registered.duplicate()


func world_pill() -> WorldPill:
	return _pill


func world_menu() -> WorldMenu:
	return _menu


func history_tiles() -> HistoryTiles:
	return _history


func action_pill() -> ActionPill:
	return _actions


func mode_rail() -> ModeRail:
	return _rail


func popover() -> ToolPopover:
	return _popover


func chip() -> ToolChip:
	return _chip


func gesture_hints() -> GestureHints:
	return _hints


func toast() -> Toast:
	return _toast


func ghost_label() -> GhostLabel:
	return _ghost_label


func inspector() -> ObjectInspector:
	return _inspector


func library() -> AssetLibrary:
	return _library


func set_editor() -> SetEditor:
	return _set_editor


func banner_label() -> Label:
	return _banner_label


func confirm_dialog() -> ConfirmDialog:
	return _confirm


func diagnostics_overlay() -> DiagnosticsOverlay:
	return _diagnostics


func is_left_handed() -> bool:
	return _left


func set_left_handed(on: bool) -> void:
	_left = on
	_menu.sync_left_handed(on)
	layout()


func on_ui_cancelled(reason: String) -> void:
	_popover.on_ui_cancelled(reason)
	_inspector.on_ui_cancelled(reason)
	_library.on_ui_cancelled(reason)
	refresh()


# --- refresh -------------------------------------------------------------------------------

func refresh() -> void:
	if _session == null or _session.document == null:
		return
	var s := _session.status()
	for c: Control in [_pill, _menu, _history, _actions, _rail, _chip]:
		c.call("refresh", s)
	_refresh_banner(str(s.banner))
	_hints.set_development(bool(s.development_input))
	_inspector.visible = _inspector_wanted()
	_diagnostics.refresh()
	layout()


func _refresh_banner(text: String) -> void:
	_banner.visible = text != ""
	_banner_label.text = "Editing disabled: " + text
	var width := UiKit.bold_font().get_string_size(_banner_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	_banner_label.custom_minimum_size.x = minf(ceilf(width) + 2.0, BANNER_MAX_W)


## Inspector rules (ADR 0007): Place mode, Select tool, an object selected, no world operation.
func _inspector_wanted() -> bool:
	var tools := _session.tools
	if tools.mode() != "place" or tools.active_tool() != ToolController.TOOL_SELECT or tools.selected_id() == "":
		return false
	return not (tools.has_active_operation() and not tools.has_object_edit())


# --- layout --------------------------------------------------------------------------------

func _viewport_size() -> Vector2:
	return layout_override if layout_override != Vector2.ZERO else get_viewport().get_visible_rect().size


## Explicit positions of every panel; idempotent, so it may run on any change.
func layout() -> void:
	if _session == null:
		return
	var vp := _viewport_size()
	for c: Control in [_pill, _history, _actions, _rail, _chip]:
		c.reset_size()
	_popover.set_max_height(vp.y - TOP_Y - M)
	_layout_top(vp)
	_layout_sides(vp)
	_layout_bottom(vp)
	_set_editor.position = Vector2.ZERO
	_set_editor.size = vp
	_menu.reset_size()
	_menu.position = Vector2(M, _pill.position.y + _pill.size.y + 4.0)
	_layout_floaters()


func _layout_top(vp: Vector2) -> void:
	_pill.position = Vector2(M, M)
	_actions.position = Vector2(vp.x - M - _actions.size.x, M)
	var w := _history.base_width()
	var lo := _pill.position.x + _pill.size.x + GAP
	var hi := _actions.position.x - GAP - w
	_history.position = Vector2(maxf(lo, minf(vp.x * 0.5 - w * 0.5, hi)), M)


## Rail and popover on the dominant-hand side, Library on the other (mirrored when left-handed).
func _layout_sides(vp: Vector2) -> void:
	var lib_w := AssetLibrary.WIDTH
	_library.size = Vector2(lib_w, vp.y - TOP_Y - M)
	_library.position = Vector2(M if _left else vp.x - M - lib_w, TOP_Y)
	var lib_edge := _library.position.x + (lib_w + GAP if _left else -GAP)
	_rail.position = Vector2(vp.x - M - _rail.size.x if _left else M, TOP_Y)
	_popover.position = Vector2(_rail.position.x - RAIL_GAP - _popover.size.x if _left \
			else _rail.position.x + _rail.size.x + RAIL_GAP, TOP_Y)
	var near: Control = _popover if _popover.is_open() else _rail
	var lo := M
	var hi := vp.x - M
	if _left:
		hi = near.position.x - GAP
		lo = lib_edge if _library.is_open() else M
	else:
		lo = near.position.x + near.size.x + GAP
		hi = lib_edge if _library.is_open() else vp.x - M
	_region = Vector2(lo, hi)
	var diag_x := hi - _diagnostics.size.x
	if _left:
		diag_x = lib_edge if _library.is_open() else M
	_diagnostics.position = Vector2(diag_x, TOP_Y)


func _layout_bottom(vp: Vector2) -> void:
	_chip.fit_width(_region.y - _region.x)
	var centre := clampf(vp.x * 0.5, _region.x + _chip.size.x * 0.5, _region.y - _chip.size.x * 0.5)
	_chip.position = Vector2(centre - _chip.size.x * 0.5, vp.y - M - _chip.size.y)
	var hints_x := M + (AssetLibrary.WIDTH + GAP if _left and _library.is_open() else 0.0)
	_hints.reset_size()
	_hints.position = Vector2(hints_x + 2.0, vp.y - 14.0 - _hints.size.y)


## Elements whose height depends on wrapped text; also run every frame.
func _layout_floaters() -> void:
	var vp := _viewport_size()
	var bottom := _chip.position.y - 8.0
	for c: Control in [_toast, _banner]:
		if not c.visible:
			continue
		c.size = c.get_combined_minimum_size()
		var centre := clampf(vp.x * 0.5, _region.x + c.size.x * 0.5, maxf(_region.y - c.size.x * 0.5, _region.x))
		c.position = Vector2(centre - c.size.x * 0.5, bottom - c.size.y)
		bottom = c.position.y - 8.0


func _process(_delta: float) -> void:
	if _session == null:
		return
	_layout_floaters()
	_update_ghost_label()
	if _inspector.visible and _session.input.router.state() != InputRouter.State.PENCIL_UI:
		_place_inspector()


## The label sits beside the ghost's ground point, kept inside the viewport.
func _update_ghost_label() -> void:
	var preview := _session.tools.place_preview()
	if not _ghost_label.show_preview(preview):
		return
	var camera := _session.rig.get_camera()
	var world: Vector3 = preview.world_pos
	if camera == null or camera.is_position_behind(world):
		_ghost_label.visible = false
		return
	var vp := _viewport_size()
	var pos := camera.unproject_position(world) + GHOST_LABEL_OFFSET
	_ghost_label.position = Vector2(clampf(pos.x, 0.0, maxf(vp.x - _ghost_label.size.x, 0.0)),
			clampf(pos.y, 0.0, maxf(vp.y - _ghost_label.size.y, 0.0)))


func _place_inspector() -> void:
	var y1 := _chip.position.y - GAP
	var free := Rect2(_region.x, TOP_Y, _region.y - _region.x, y1 - TOP_Y)
	var anchor := _object_anchor()
	if anchor.position == Vector2.INF:
		_inspector.position = free.position
		return
	_inspector.place(anchor, free, not _left, _other_object_points())


## Screen centres of every visible object except the selected one.
func _other_object_points() -> PackedVector2Array:
	var points := PackedVector2Array()
	var camera := _session.rig.get_camera()
	if camera == null:
		return points
	var selected := _session.tools.selected_id()
	for id in _session.presenter.object_ids():
		if id == selected:
			continue
		var centre := _session.presenter.world_bounds(id).get_center()
		if not camera.is_position_behind(centre):
			points.append(camera.unproject_position(centre))
	return points


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
