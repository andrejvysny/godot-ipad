class_name UiHitTester
extends RefCounted
## Answers "is this root-viewport position over interface?" for the InputRouter. Only
## registered controls count (panels, rails, strips); the 3D viewport behind them is world.
## A visible registered modal covers the whole screen.
##
## When `root` is set, embedded Windows (dialogs, OptionButton/MenuButton popups) count without
## registration: a visible exclusive or popup window covers the whole screen (a tap outside it
## dismisses it, never paints), any other visible window covers its own rect. Mouse-passthrough
## windows (tooltips) never count.

## Root viewport whose embedded sub-windows are hit-tested; null disables window hit-testing.
var root: Viewport = null

var _controls: Array[Control] = []
var _modals: Array[Control] = []


func register(control: Control) -> void:
	if control != null and not _controls.has(control):
		_controls.append(control)


func register_modal(control: Control) -> void:
	if control != null and not _modals.has(control):
		_modals.append(control)


func unregister(control: Control) -> void:
	_controls.erase(control)
	_modals.erase(control)


func clear() -> void:
	_controls.clear()
	_modals.clear()


func is_over_ui(pos: Vector2) -> bool:
	if not pos.is_finite():
		return false
	_prune()
	if is_modal_visible():
		return true
	for w in _visible_windows():
		if blocks_screen(w) or window_rect(w).has_point(pos):
			return true
	for c in _controls:
		if c.is_visible_in_tree() and screen_rect(c).has_point(pos):
			return true
	return false


## Control rect in root-viewport coordinates, including any CanvasLayer transform and, for
## controls inside embedded Windows, the window's placement (get_global_rect() is window-local
## there).
static func screen_rect(c: Control) -> Rect2:
	var xf := to_root_transform(c.get_viewport()) * c.get_global_transform_with_canvas()
	return xf * Rect2(Vector2.ZERO, c.size)


## Maps a viewport's own input/canvas coordinates to root-viewport coordinates. An embedded
## Window receives events offset by its position and then un-scaled by its final transform
## (Viewport._sub_windows_forward_input + _make_input_local), so this is the inverse of that.
static func to_root_transform(vp: Viewport) -> Transform2D:
	var xf := Transform2D.IDENTITY
	var w := vp as Window
	while w != null and w.is_inside_tree() and w.is_embedded():
		xf = Transform2D(0.0, Vector2(w.position)) * w.get_final_transform() * xf
		var parent := w.get_parent()
		w = parent.get_viewport() as Window if parent != null else null
	return xf


## Embedded window rect in its embedder's coordinates, title bar included when decorated.
static func window_rect(w: Window) -> Rect2:
	var r := Rect2(Vector2(w.position), Vector2(w.size))
	if not w.borderless:
		var title := float(w.get_theme_constant("title_height"))
		r.position.y -= title
		r.size.y += title
	return r


## True for windows that own the whole screen while visible (modal dialogs, popup menus).
static func blocks_screen(w: Window) -> bool:
	return w.exclusive or w.popup_window


func is_modal_visible() -> bool:
	for m in _modals:
		if is_instance_valid(m) and m.is_visible_in_tree():
			return true
	for w in _visible_windows():
		if blocks_screen(w):
			return true
	return false


func hit_callable() -> Callable:
	return is_over_ui


func _visible_windows() -> Array[Window]:
	var out: Array[Window] = []
	if root == null or not is_instance_valid(root) or not root.is_inside_tree():
		return out
	for w: Window in root.get_embedded_subwindows():
		if is_instance_valid(w) and w.visible and not w.mouse_passthrough:
			out.append(w)
	return out


func _prune() -> void:
	for i in range(_controls.size() - 1, -1, -1):
		if not is_instance_valid(_controls[i]):
			_controls.remove_at(i)
	for i in range(_modals.size() - 1, -1, -1):
		if not is_instance_valid(_modals[i]):
			_modals.remove_at(i)
