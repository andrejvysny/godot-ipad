class_name ScrubField
extends Range
## Relative-drag value field (spec §9). Pressing never jumps the value; moving by dx changes it
## by dx / width of the range. Emits the same drag signals as Slider so handlers port directly.

signal drag_started()
signal drag_ended(value_changed: bool)

var caption := "":
	set(v):
		caption = v
		queue_redraw()
var formatter := Callable()
## Shown instead of `value` while finite: the owner's applied value (e.g. a snapped yaw) can differ
## from the raw drag value.
var display_value := NAN:
	set(v):
		display_value = v
		queue_redraw()
var editable := true:
	set(v):
		editable = v
		queue_redraw()
var stacked := false:
	set(v):
		stacked = v
		size_flags_horizontal = Control.SIZE_EXPAND_FILL if v else Control.SIZE_FILL
		custom_minimum_size = Vector2(0, UiKit.MIN_HEIGHT) if v else Vector2(170, UiKit.MIN_HEIGHT)
		queue_redraw()

var _dragging := false
var _start_value := 0.0
var _start_x := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(170, UiKit.MIN_HEIGHT)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	value_changed.connect(func(_v: float) -> void: queue_redraw())
	changed.connect(queue_redraw)


func is_dragging() -> bool:
	return _dragging


func _gui_input(event: InputEvent) -> void:
	if not editable:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed and not _dragging:
			_dragging = true
			_start_value = value
			_start_x = button.position.x
			drag_started.emit()
			accept_event()
		elif not button.pressed and _dragging:
			_dragging = false
			drag_ended.emit(not is_equal_approx(value, _start_value))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		if size.x > 0.0:
			value = _start_value + (motion.position.x - _start_x) / size.x * (max_value - min_value)
		accept_event()


func _format() -> String:
	var shown := display_value if is_finite(display_value) else value
	if formatter.is_valid():
		return str(formatter.call(shown))
	return "%.2f" % shown


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var box := StyleBoxFlat.new()
	box.bg_color = UiKit.VALUE_CELL if stacked else UiKit.SURFACE
	box.set_corner_radius_all(12)
	draw_style_box(box, rect)
	var font := ThemeDB.fallback_font
	var bold := UiKit.bold_font()
	var mono := UiKit.mono_font()
	var tint := Color(1, 1, 1, 1.0 if editable else 0.4)
	if stacked:
		_draw_stacked(font, mono, tint)
		return
	var span := max_value - min_value
	var ratio := clampf((value - min_value) / span, 0.0, 1.0) if span > 0.0 else 0.0
	var fill_w := ratio * size.x
	if fill_w > 0.0:
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(UiKit.ACCENT, 0.24)
		fill.set_corner_radius_all(12)
		draw_style_box(fill, Rect2(0, 0, maxf(fill_w, 24.0), size.y))
		draw_rect(Rect2(maxf(fill_w - 2.0, 0.0), 6, 2, size.y - 12), UiKit.ACCENT)
	var base := size.y * 0.5 + 5.0
	draw_string(bold, Vector2(14, base), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiKit.TEXT_SECONDARY * tint)
	var text := _format()
	var width := mono.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(mono, Vector2(size.x - 14.0 - width, base), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiKit.TEXT * tint)


func _draw_stacked(font: Font, mono: Font, tint: Color) -> void:
	var cap_w := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(font, Vector2((size.x - cap_w) * 0.5, 17), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiKit.TEXT_MUTED * tint)
	var text := _format()
	var width := mono.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	draw_string(mono, Vector2((size.x - width) * 0.5, 38), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, UiKit.TEXT * tint)
