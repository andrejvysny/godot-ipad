class_name UiKit
extends RefCounted
## Design tokens, theme and control factories of the editor interface (spec §9). Controls are
## operated by Godot GUI events only; on iOS those are the synthetic Pencil mouse events of
## InputSystem. No symbol glyphs in text: the default iPad font lacks them, use icon textures.

const ACCENT := Color("f2bf33")
const ACCENT_TINT := Color(0.949, 0.749, 0.2, 0.16)
const ACCENT_INK := Color("15191d")
const PANEL_BG := Color(16.0 / 255.0, 21.0 / 255.0, 26.0 / 255.0, 0.86)
const PANEL_BG_STRONG := Color(16.0 / 255.0, 21.0 / 255.0, 26.0 / 255.0, 0.94)
const PANEL_BORDER := Color(1, 1, 1, 0.08)
const TEXT := Color("e8ecef")
const TEXT_SECONDARY := Color("b8c1c9")
const TEXT_MUTED := Color("9aa4ad")
const TOOL_TEXT := Color("c9d0d6")
const SURFACE := Color(1, 1, 1, 0.06)
const SURFACE_HOVER := Color(1, 1, 1, 0.07)
const VALUE_CELL := Color(1, 1, 1, 0.04)
const DANGER_TEXT := Color("ff9a88")
const DANGER_BG := Color(1, 0.431, 0.353, 0.14)
const SAVED_DOT := Color("6fd08c")
const FAILED_DOT := Color("ff6e5a")
const MIN_HEIGHT := 48.0

static var _bold: FontVariation = null
static var _mono: SystemFont = null


static func make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 14
	theme.set_color("font_color", "Label", TEXT)
	theme.set_stylebox("panel", "PanelContainer", _panel_box(PANEL_BG, 16, 6, true))
	var pressed := _pressed_box(11, 14)
	theme.set_stylebox("normal", "Button", _box(Color.TRANSPARENT, 11, 14))
	theme.set_stylebox("hover", "Button", _box(SURFACE_HOVER, 11, 14))
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("hover_pressed", "Button", pressed)
	theme.set_stylebox("disabled", "Button", _box(Color.TRANSPARENT, 11, 14))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", TEXT)
	theme.set_color("font_pressed_color", "Button", ACCENT)
	theme.set_color("font_hover_pressed_color", "Button", ACCENT)
	theme.set_color("font_disabled_color", "Button", Color(TEXT, 0.4))
	_variations(theme)
	theme.set_constant("separation", "VBoxContainer", 4)
	theme.set_constant("separation", "HBoxContainer", 6)
	return theme


static func _variations(theme: Theme) -> void:
	_button_variation(theme, "AccentButton", _box(ACCENT, 11, 14), _box(ACCENT.lightened(0.1), 11, 14),
			_box(ACCENT, 11, 14), ACCENT_INK, ACCENT_INK, true)
	_button_variation(theme, "DangerButton", _box(DANGER_BG, 11, 14), _box(DANGER_BG.lightened(0.1), 11, 14),
			_box(DANGER_BG, 11, 14), DANGER_TEXT, DANGER_TEXT, false)
	_button_variation(theme, "SurfaceButton", _box(SURFACE_HOVER, 11, 14), _box(SURFACE_HOVER.lightened(0.15), 11, 14),
			_pressed_box(11, 14), TEXT, ACCENT, false)
	_button_variation(theme, "SegmentButton", _box(Color.TRANSPARENT, 9, 12), _box(SURFACE_HOVER, 9, 12),
			_box(ACCENT, 9, 12), TEXT, ACCENT_INK, false)
	_button_variation(theme, "ChipButton", _box(SURFACE, 22, 18), _box(SURFACE_HOVER, 22, 18),
			_box(TEXT, 22, 18), TOOL_TEXT, ACCENT_INK, false)
	var tile := [_box(Color.TRANSPARENT, 13, 2), _box(SURFACE_HOVER, 13, 2), _pressed_box(13, 2)]
	for box: StyleBoxFlat in tile:
		box.content_margin_top = 7
		box.content_margin_bottom = 5
	_button_variation(theme, "ToolTile", tile[0], tile[1], tile[2], TOOL_TEXT, ACCENT, false)
	theme.set_font_size("font_size", "ToolTile", 11)
	theme.set_constant("icon_max_width", "ToolTile", 26)
	_button_variation(theme, "MenuRow", _box(Color.TRANSPARENT, 10, 12), _box(SURFACE_HOVER, 10, 12),
			_pressed_box(10, 12), TEXT, TEXT, false)
	theme.set_type_variation("StrongPanel", "PanelContainer")
	var strong := _panel_box(PANEL_BG_STRONG, 18, 12, true)
	strong.shadow_size = 12
	strong.shadow_color = Color(0, 0, 0, 0.3)
	theme.set_stylebox("panel", "StrongPanel", strong)
	theme.set_type_variation("SubPanel", "PanelContainer")
	theme.set_stylebox("panel", "SubPanel", _panel_box(Color(1, 1, 1, 0.05), 12, 3, false))


static func _button_variation(theme: Theme, name: String, normal: StyleBoxFlat, hover: StyleBoxFlat,
		pressed: StyleBoxFlat, font: Color, font_pressed: Color, bold: bool) -> void:
	theme.set_type_variation(name, "Button")
	theme.set_stylebox("normal", name, normal)
	theme.set_stylebox("hover", name, hover)
	theme.set_stylebox("pressed", name, pressed)
	theme.set_stylebox("hover_pressed", name, pressed)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(normal.bg_color, normal.bg_color.a * 0.5)
	theme.set_stylebox("disabled", name, disabled)
	for key in ["font_color", "font_hover_color"]:
		theme.set_color(key, name, font)
	for key in ["font_pressed_color", "font_hover_pressed_color"]:
		theme.set_color(key, name, font_pressed)
	theme.set_color("font_disabled_color", name, Color(font, 0.4))
	if bold:
		theme.set_font("font", name, bold_font())


static func _box(color: Color, radius: int, margin_h: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.content_margin_left = margin_h
	box.content_margin_right = margin_h
	return box


static func _pressed_box(radius: int, margin_h: int) -> StyleBoxFlat:
	var box := _box(ACCENT_TINT, radius, margin_h)
	box.set_border_width_all(2)
	box.border_color = ACCENT
	return box


static func _panel_box(color: Color, radius: int, margin: int, border: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(margin)
	if border:
		box.set_border_width_all(1)
		box.border_color = PANEL_BORDER
	return box


static func bold_font() -> FontVariation:
	if _bold == null:
		_bold = FontVariation.new()
		_bold.base_font = ThemeDB.fallback_font
		_bold.variation_embolden = 0.5
	return _bold


static func mono_font() -> SystemFont:
	if _mono == null:
		_mono = SystemFont.new()
		_mono.font_names = PackedStringArray(["JetBrains Mono", "SF Mono", "Menlo", "Courier New", "monospace"])
	return _mono


static func icon(name: String) -> Texture2D:
	return load("res://assets/icons/%s.svg" % name) as Texture2D


## Icon display control of a fixed size (SVGs are imported at 3x for crispness).
static func icon_rect(name: String, px: Vector2) -> TextureRect:
	var r := TextureRect.new()
	r.texture = icon(name)
	r.custom_minimum_size = px
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func button(text: String, on_pressed: Callable, toggle := false, min_width := 0) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_width, MIN_HEIGHT)
	if on_pressed.is_valid():
		b.pressed.connect(on_pressed)
	return b


## Button with a theme variation (AccentButton, SurfaceButton, ...).
static func variant_button(text: String, variation: String, on_pressed: Callable, toggle := false,
		min_width := 0) -> Button:
	var b := button(text, on_pressed, toggle, min_width)
	b.theme_type_variation = variation
	return b


static func switch_button(text: String, on_toggled: Callable) -> Button:
	var b := button(text, Callable(), true)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	b.add_theme_constant_override("h_separation", 10)
	b.add_theme_constant_override("icon_max_width", 30)
	var empty := StyleBoxEmpty.new()
	empty.content_margin_left = 8
	empty.content_margin_right = 8
	for key in ["normal", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(key, empty)
	var hover := _box(SURFACE_HOVER, 11, 8)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_color_override("font_hover_pressed_color", TEXT)
	b.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.4))
	set_switch(b, false)
	if on_toggled.is_valid():
		b.toggled.connect(on_toggled)
	b.toggled.connect(func(on: bool) -> void: _set_switch_icon(b, on))
	return b


static func set_switch(b: Button, on: bool) -> void:
	b.set_pressed_no_signal(on)
	_set_switch_icon(b, on)


static func _set_switch_icon(b: Button, on: bool) -> void:
	b.icon = icon("switch_on" if on else "switch_off")


static func label(text: String, size := 0) -> Label:
	var l := Label.new()
	l.text = text
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	return l


static func bold_label(text: String, size := 0, color := TEXT) -> Label:
	var l := label(text, size)
	l.add_theme_font_override("font", bold_font())
	l.add_theme_color_override("font_color", color)
	return l


static func panel() -> PanelContainer:
	return PanelContainer.new()


static func pill(bg := PANEL_BG, radius := 16, margin := 6) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_box(bg, radius, margin, true))
	return p


static func variant_panel(variation: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = variation
	return p


static func separator_v() -> Control:
	var c := ColorRect.new()
	c.color = PANEL_BORDER
	c.custom_minimum_size = Vector2(1, 28)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


static func separator_h() -> Control:
	var c := ColorRect.new()
	c.color = PANEL_BORDER
	c.custom_minimum_size = Vector2(0, 1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c
