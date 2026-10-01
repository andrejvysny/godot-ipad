class_name PerfIndicator
extends PanelContainer
## Small performance/profile pill left of the action pill (spec PREF-22, docs/editor-v2.md §9.1): the active
## profile and measured fps, and the profile waiting for the current edit. The text turns to the danger
## tone while fps is below 0.9 x the profile target; that is a warning only and never changes anything.
## EditorUI places and registers it; pressing it toggles the PerfMenu.

signal toggled(open: bool)

const HEIGHT := 38.0
const WARN_FRACTION := 0.9
const NO_FPS := "—"

var _session: EditorSession
var _button := UiKit.variant_button("", "PillButton", Callable(), true)


func setup(session: EditorSession) -> void:
	_session = session
	add_theme_stylebox_override("panel", UiKit.pill_box(UiKit.PANEL_BG, 12, 3))
	_button.add_theme_font_size_override("font_size", 12)
	_button.toggled.connect(func(on: bool) -> void: toggled.emit(on))
	add_child(_button)
	refresh(session.status())


func button() -> Button:
	return _button


func text() -> String:
	return _button.text


func is_warning() -> bool:
	return _button.get_theme_color("font_color") == UiKit.DANGER_TEXT


## Keeps the pressed state in step with the menu, which can also close itself.
func set_open(on: bool) -> void:
	_button.set_pressed_no_signal(on)


func refresh(status: Dictionary) -> void:
	if _session == null:
		return
	_button.text = caption(status)
	var warn := is_below_target(float(status.fps), int(status.profile_target_fps))
	var color := UiKit.DANGER_TEXT if warn else UiKit.TEXT
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		_button.add_theme_color_override(key, color)
	_button.custom_minimum_size = Vector2(0, HEIGHT)
	reset_size()


## "<Label> · <fps> fps", plus " -> <pending label>" while a profile switch waits for the edit.
func caption(status: Dictionary) -> String:
	var fps := float(status.fps)
	var text := "%s · %s fps" % [status.profile_label, str(roundi(fps)) if fps > 0.0 else NO_FPS]
	var pending := str(status.profile_pending)
	if pending != "":
		text += " -> " + str(_session.render_config.profile(pending).get("label", pending))
	return text


static func is_below_target(fps: float, target_fps: int) -> bool:
	return fps > 0.0 and target_fps > 0 and fps < WARN_FRACTION * float(target_fps)
