class_name UiKit
extends RefCounted
## Shared look and control factories of the editor interface (spec §9). Controls are operated by
## Godot GUI events only; on iOS those are the synthetic Pencil mouse events of InputSystem.

const ACCENT := Color(0.95, 0.75, 0.2)
const PANEL_BG := Color(0.07, 0.09, 0.11, 0.92)
const MIN_HEIGHT := 48.0


static func make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 17
	var panel := _box(PANEL_BG, 6, 8)
	theme.set_stylebox("panel", "PanelContainer", panel)
	var normal := _box(Color(0.16, 0.19, 0.23), 6, 8)
	var hover := _box(Color(0.2, 0.24, 0.29), 6, 8)
	var down := _box(Color(0.12, 0.15, 0.18), 6, 8)
	var disabled := _box(Color(0.11, 0.13, 0.15), 6, 8)
	var toggled := _box(Color(0.2, 0.24, 0.29), 6, 8)
	toggled.set_border_width_all(3)
	toggled.border_color = ACCENT
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", toggled)
	theme.set_stylebox("hover_pressed", "Button", toggled)
	theme.set_stylebox("disabled", "Button", disabled)
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_disabled_color", "Button", Color(0.5, 0.52, 0.55))
	theme.set_stylebox("pressed", "HSlider", down)
	theme.set_constant("separation", "VBoxContainer", 4)
	theme.set_constant("separation", "HBoxContainer", 6)
	return theme


static func _box(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(margin)
	return box


static func button(text: String, on_pressed: Callable, toggle := false, min_width := 0) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_width, MIN_HEIGHT)
	if on_pressed.is_valid():
		b.pressed.connect(on_pressed)
	return b


static func slider(min_value: float, max_value: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = step
	s.focus_mode = Control.FOCUS_NONE
	s.scrollable = false
	s.custom_minimum_size = Vector2(0, MIN_HEIGHT)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


static func label(text: String, size := 0) -> Label:
	var l := Label.new()
	l.text = text
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	return l


static func panel() -> PanelContainer:
	return PanelContainer.new()
