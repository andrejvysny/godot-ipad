class_name Toast
extends PanelContainer
## Transient message above the active-tool chip (docs/editor-v2.md §9): 2.2 s, errors in the danger
## colour. Not registered with UiHitTester.

const SECONDS := 2.2
const MAX_WIDTH := 560.0

var _label := UiKit.bold_label("", 12)
var _timer := Timer.new()
var _max_width := MAX_WIDTH


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.TOAST_BG, 10, 8, false))
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	_timer.one_shot = true
	_timer.timeout.connect(func() -> void: visible = false)
	add_child(_timer)
	visible = false


func show_message(text: String, is_error: bool) -> void:
	_label.text = text
	_label.tooltip_text = text
	_label.add_theme_color_override("font_color", UiKit.DANGER_TEXT if is_error else UiKit.TEXT)
	visible = true
	_fit()
	_timer.start(SECONDS)


## Wraps long messages within `w` (the free span between the side panels), at most MAX_WIDTH.
func fit_width(w: float) -> void:
	var limit := minf(w - get_theme_stylebox("panel").get_minimum_size().x, MAX_WIDTH)
	if absf(limit - _max_width) < 0.5:
		return
	_max_width = limit
	_fit()


func _fit() -> void:
	var width := UiKit.bold_font().get_string_size(_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	_label.custom_minimum_size.x = minf(ceilf(width) + 2.0, _max_width)
	reset_size()


func label() -> Label:
	return _label
