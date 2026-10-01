class_name LibraryTile
extends PanelContainer
## One Library asset. A Pencil press on it is owned by this control (input contract §2): motion
## beyond DRAG_PX opens a ToolController drop that follows the Pencil, release over terrain places
## the asset, a tap selects the asset for the Place tool. Positions are root-viewport coordinates.

const DRAG_PX := 10.0

var asset_id := ""

var _session: EditorSession
var _asset: AssetDefinition
var _report := Callable()  # (text: String, pos: Vector2, valid: bool); empty text clears
var _meta := UiKit.label("", 11)
var _pressed := false
var _dragging := false
var _dead := false  # contact was cancelled or refused; its release does nothing
var _press_pos := Vector2.ZERO
var _selected := false
var _enabled := true


func setup(session: EditorSession, asset: AssetDefinition, report: Callable) -> void:
	_session = session
	_asset = asset
	asset_id = asset.asset_id
	_report = report
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)
	var thumb := TextureRect.new()
	thumb.texture = load(asset.thumbnail) as Texture2D
	thumb.custom_minimum_size = Vector2(92, 92)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(thumb)
	var name_label := UiKit.bold_label(asset.display_name, 14)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(name_label)
	_meta.text = "r %s m · %s–%s×" % [_trim(asset.footprint_radius_m), _trim(asset.scale_min), _trim(asset.scale_max)]
	_meta.add_theme_font_override("font", UiKit.mono_font())
	_meta.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_meta)
	_apply_style()


static func _trim(v: float) -> String:
	var text := "%.2f" % v
	return text.rstrip("0").rstrip(".")


func meta_text() -> String:
	return _meta.text


func set_selected(on: bool) -> void:
	_selected = on
	_apply_style()


func set_enabled(on: bool) -> void:
	_enabled = on
	modulate.a = 1.0 if on else 0.4


func _apply_style() -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, 0.05)
	box.set_corner_radius_all(14)
	box.set_content_margin_all(10)
	box.set_border_width_all(2)
	box.border_color = UiKit.ACCENT if _selected else Color(UiKit.ACCENT, 0.0)
	add_theme_stylebox_override("panel", box)


func _root_pos(local: Vector2) -> Vector2:
	return UiHitTester.to_root_transform(get_viewport()) * get_global_transform_with_canvas() * local


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed:
			_on_press(_root_pos(button.position))
		else:
			_on_release(_root_pos(button.position))
		accept_event()
	elif event is InputEventMouseMotion and _pressed:
		_on_motion(_root_pos((event as InputEventMouseMotion).position))
		accept_event()


func _on_press(pos: Vector2) -> void:
	if not _enabled or not _session.input.editing_enabled():
		return
	_pressed = true
	_dragging = false
	_dead = false
	_press_pos = pos


func _on_motion(pos: Vector2) -> void:
	if _dead:
		return
	if not _dragging:
		if pos.distance_to(_press_pos) <= DRAG_PX:
			return
		var error := _session.tools.begin_drop(asset_id)
		if error != "":
			_session.post_message(error, true)
			_dead = true
			return
		_dragging = true
	if not _session.tools.has_drop():
		_dragging = false
		_dead = true
		_clear_hint()
		return
	var over := _session.input.ui_hits.is_over_ui(pos)
	_session.tools.update_drop(pos, over)
	if _report.is_valid():
		var valid := not over and _session.presenter.ghost_valid()
		var text := "Lift to place %s" % _asset.display_name if valid \
				else "Over a panel · lift cancels" if over else "No terrain here · lift cancels"
		_report.call(text, pos, valid)


func _on_release(pos: Vector2) -> void:
	var was_dead := _dead
	var was_dragging := _dragging
	var was_pressed := _pressed
	_pressed = false
	_dragging = false
	_dead = false
	if was_dead or not was_pressed:
		return
	if was_dragging:
		_session.tools.finish_drop(pos, _session.input.ui_hits.is_over_ui(pos))
		_clear_hint()
		return
	var error := _session.tools.arm_asset(asset_id)
	if error != "":
		_session.post_message(error, true)
	else:
		_session.post_message("Touch the terrain to place %s." % _asset.display_name)


## Called before the synthetic in-place release that follows ui_cancelled.
func cancel_contact() -> void:
	if not _pressed:
		return
	if _dragging and _session.tools.has_drop():
		_session.tools.cancel_active("ui_cancel")
	_dead = true
	_dragging = false
	_clear_hint()


func _clear_hint() -> void:
	if _report.is_valid():
		_report.call("", Vector2.ZERO, true)
