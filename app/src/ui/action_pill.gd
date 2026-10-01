class_name ActionPill
extends PanelContainer
## Top-right pill (docs/editor-v2.md §9): Export (the result arrives as a toast) and the Library toggle
## (active = light fill, dark text).

var _session: EditorSession
var _export := UiKit.variant_button("Export", "BarButton", Callable())
var _library_toggle := UiKit.variant_button("Library", "BarButton", Callable(), true)


func setup(session: EditorSession, library: AssetLibrary) -> void:
	_session = session
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.PANEL_BG, 12, 3))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	add_child(row)
	for b: Button in [_export, _library_toggle]:
		b.custom_minimum_size = Vector2(0, 38)
		b.add_theme_font_size_override("font_size", 12)
		row.add_child(b)
	_export.pressed.connect(func() -> void: session.export_world())
	_library_toggle.toggled.connect(func(on: bool) -> void: library.set_open(on))
	library.open_changed.connect(func(open: bool) -> void: _library_toggle.set_pressed_no_signal(open))
	_library_toggle.set_pressed_no_signal(library.is_open())


func export_button() -> Button:
	return _export


func library_button() -> Button:
	return _library_toggle


func refresh(status: Dictionary) -> void:
	var enabled := bool(status.editing_enabled)
	_export.disabled = not enabled
