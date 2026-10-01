class_name LibraryTile
extends PanelContainer
## One Library asset (docs/editor-v2.md §9). A Pencil press on it is owned by this control (input
## contract §2): motion beyond DRAG_PX opens a ToolController drop that follows the Pencil, release over
## terrain places the asset, a tap arms it (or disarms it when already armed). Scatter-capable assets have
## a tick circle (30 pt hit target) for the quick mix. Positions are root-viewport coordinates.

signal tick_toggled(asset_id: String, on: bool)

const DRAG_PX := 10.0
const TICK_HIT := 30.0
const NOT_READY_CAPTION := "Not ready"

var asset_id := ""

var _session: EditorSession
var _asset: AssetDefinition
var _meta := UiKit.label("", 9)
var _tick: Button
var _dot := PanelContainer.new()
var _check: TextureRect
var _pressed := false
var _dragging := false
var _dead := false  # contact was cancelled or refused; its release does nothing
var _press_pos := Vector2.ZERO
var _selected := false
var _enabled := true
var _prepared := true  # false while the asset has no render derivatives (spec §6.6)


func setup(session: EditorSession, asset: AssetDefinition) -> void:
	_session = session
	_asset = asset
	asset_id = asset.asset_id
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_build_thumb(asset))
	var name_label := UiKit.bold_label(asset.display_name, 11)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(name_label)
	_prepared = session.render_state().registry().is_ready(asset.asset_id)
	_meta.text = asset.category.capitalize() if _prepared else NOT_READY_CAPTION
	_meta.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	_meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_meta)
	add_child(column)
	if asset.scatter_allowed:
		add_child(_build_tick())
	set_enabled(_enabled)
	_apply_style()


static func _build_thumb(asset: AssetDefinition) -> Control:
	var cell := PanelContainer.new()
	cell.add_theme_stylebox_override("panel", UiKit.pill_box(Color(1, 1, 1, 0.03), 7, 0, false))
	cell.custom_minimum_size = Vector2(0, 88)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glow := GradientTexture2D.new()
	glow.fill = GradientTexture2D.FILL_RADIAL
	glow.fill_from = Vector2(0.5, 0.7)
	glow.fill_to = Vector2(1.0, 0.7)
	glow.gradient = Gradient.new()
	glow.gradient.colors = PackedColorArray([Color(1, 1, 1, 0.09), Color(1, 1, 1, 0.02)])
	var back := TextureRect.new()
	back.texture = glow
	back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var thumb := TextureRect.new()
	thumb.texture = load(asset.thumbnail) as Texture2D
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(thumb)
	cell.add_child(back)
	cell.add_child(margin)
	return cell


## Overlay with the tick button in the top-right corner (the overlay itself ignores the mouse).
func _build_tick() -> Control:
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tick = Button.new()
	_tick.toggle_mode = true
	_tick.focus_mode = Control.FOCUS_NONE
	_tick.flat = true
	for key in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		_tick.add_theme_stylebox_override(key, StyleBoxEmpty.new())
	_tick.custom_minimum_size = Vector2(TICK_HIT, TICK_HIT)
	_tick.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_tick.offset_left = -TICK_HIT - 2.0
	_tick.offset_right = -2.0
	_tick.offset_top = 2.0
	_tick.offset_bottom = TICK_HIT + 2.0
	_dot.custom_minimum_size = Vector2(16, 16)
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_dot.offset_left = -8
	_dot.offset_right = 8
	_dot.offset_top = -8
	_dot.offset_bottom = 8
	_check = UiKit.icon_rect("check", Vector2(10, 10))
	_check.modulate = UiKit.ACCENT_INK
	_dot.add_child(_check)
	_tick.add_child(_dot)
	_tick.toggled.connect(func(on: bool) -> void:
		set_ticked(on, false)
		tick_toggled.emit(asset_id, on))
	overlay.add_child(_tick)
	set_ticked(false, false)
	return overlay


func tick_button() -> Button:
	return _tick


func is_ticked() -> bool:
	return _tick != null and _tick.button_pressed


func set_ticked(on: bool, sync_button := true) -> void:
	if _tick == null:
		return
	if sync_button:
		_tick.set_pressed_no_signal(on)
	var box := UiKit.pill_box(UiKit.ACCENT if on else Color(0, 0, 0, 0.25), 8, 0, false)
	box.set_border_width_all(2)
	box.border_color = UiKit.ACCENT if on else Color(1, 1, 1, 0.35)
	_dot.add_theme_stylebox_override("panel", box)
	_check.visible = on


func is_prepared() -> bool:
	return _prepared


func meta_text() -> String:
	return _meta.text


func set_selected(on: bool) -> void:
	_selected = on
	_apply_style()


func set_enabled(on: bool) -> void:
	_enabled = on
	modulate.a = 1.0 if on and _prepared else 0.4


func _apply_style() -> void:
	var box := UiKit.pill_box(Color(1, 1, 1, 0.05), 10, 6, false)
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
	if not _enabled or not _prepared or not _session.input.editing_enabled():
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
		if not _session.input.ui_press_is_pencil():
			_dead = true  # a finger may arm by tap but never drags an asset into the world
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
		return
	_session.tools.update_drop(pos, _session.input.ui_hits.is_over_ui(pos))


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
		return
	_tap()


## A tap arms the asset; tapping the armed tile again disarms it.
func _tap() -> void:
	if _session.tools.armed_asset() == asset_id:
		_session.tools.disarm()
		return
	var error := _session.tools.arm_asset(asset_id)
	if error != "":
		_session.post_message(error, true)
	else:
		_session.post_message("Tap the terrain to place %s" % _asset.display_name)


## Called before the synthetic in-place release that follows ui_cancelled.
func cancel_contact() -> void:
	if not _pressed:
		return
	if _dragging and _session.tools.has_drop():
		_session.tools.cancel_active("ui_cancel")
	_dead = true
	_dragging = false
