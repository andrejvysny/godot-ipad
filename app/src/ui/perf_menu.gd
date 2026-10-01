class_name PerfMenu
extends PanelContainer
## Dropdown of the PerfIndicator: the three explicit render profiles as radio rows (a profile requested during
## an edit shows "after edit"), the Hide vegetation switch (presentation only), the Texture Preview switch
## with its status line and the target line.
## EditorUI places and registers it.

const WIDTH := 250.0
const ROW_HEIGHT := 40.0

var _session: EditorSession
var _rows: Dictionary = {}  # profile name -> Button
var _vegetation: Button
var _preview: Button
var _preview_info := UiKit.label("", 11)
var _info := UiKit.label("", 11)


func setup(session: EditorSession) -> void:
	_session = session
	var box := UiKit.pill_box(Color(UiKit.PANEL_BG, 0.96), 12, 6)
	box.shadow_size = 12
	box.shadow_color = Color(0, 0, 0, 0.35)
	add_theme_stylebox_override("panel", box)
	custom_minimum_size.x = WIDTH
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	add_child(column)
	for name in session.render_config.profile_names():
		var b := UiKit.variant_button("", "MenuRow", _request.bind(name), true)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size.y = ROW_HEIGHT
		b.add_theme_font_size_override("font_size", 13)
		column.add_child(b)
		_rows[name] = b
	_vegetation = UiKit.switch_button("Hide vegetation", _on_hide_vegetation, true)
	_vegetation.custom_minimum_size.y = ROW_HEIGHT
	_vegetation.add_theme_font_size_override("font_size", 13)
	column.add_child(_vegetation)
	_preview = UiKit.switch_button("Texture Preview", _on_texture_preview, true)
	_preview.custom_minimum_size.y = ROW_HEIGHT
	_preview.add_theme_font_size_override("font_size", 13)
	column.add_child(_preview)
	_preview_info.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	column.add_child(_preview_info)
	_info.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	column.add_child(_info)
	visible = false
	session.tools.operation_started.connect(func(_tool: String) -> void: close())
	refresh(session.status())


func profile_button(name: String) -> Button:
	return _rows[name]


func vegetation_switch() -> Button:
	return _vegetation


func preview_switch() -> Button:
	return _preview


func preview_text() -> String:
	return _preview_info.text


func info_text() -> String:
	return _info.text


func close() -> void:
	visible = false


func toggle_open(on: bool) -> void:
	visible = on


func _request(name: String) -> void:
	_session.request_profile(name)
	close()
	refresh(_session.status())


func _on_hide_vegetation(on: bool) -> void:
	_session.set_vegetation_hidden(on)


func _on_texture_preview(_on: bool) -> void:
	_session.toggle_texture_preview()
	refresh(_session.status())


func refresh(status: Dictionary) -> void:
	if _session == null:
		return
	var active := str(status.profile)
	var pending := str(status.profile_pending)
	for name: String in _rows:
		var b: Button = _rows[name]
		var label := str(_session.render_config.profile(name).get("label", name))
		b.text = label + ("  (after edit)" if name == pending else "")
		b.set_pressed_no_signal(name == active)
	UiKit.set_switch(_vegetation, bool(status.vegetation_hidden))
	var preview: Dictionary = status.texture_preview
	UiKit.set_switch(_preview, [TexturePreviewController.LOADING, TexturePreviewController.ACTIVE,
			TexturePreviewController.LIMITED].has(str(preview.state)))
	_preview_info.text = TexturePreviewController.status_text(preview)
	_info.text = "Target %d fps · 3D %d%%" % [int(status.profile_target_fps), roundi(float(status.render_scale) * 100.0)]
