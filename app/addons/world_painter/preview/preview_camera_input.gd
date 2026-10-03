class_name PreviewCameraInput
extends Node
## Mouse navigation of the preview camera (right drag orbit, middle drag or shift+right pan, wheel zoom). The camera
## is independent of the iPad's (ADR 0016 P4); same OrbitCameraRig actions the Mac consumer uses.

const ORBIT_BUTTON := MOUSE_BUTTON_RIGHT
const PAN_BUTTON := MOUSE_BUTTON_MIDDLE
const WHEEL_STEP := 1.1
const REF_SPAN := 100.0

var rig: OrbitCameraRig
var _drag := ""


func _unhandled_input(event: InputEvent) -> void:
	if rig == null:
		return
	if event is InputEventMouseButton:
		_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _drag != "":
		var motion := event as InputEventMouseMotion
		if _drag == "pan":
			_action("camera_pan_zoom", motion.position, REF_SPAN)
		else:
			rig.handle_camera_action({"type": "camera_orbit", "delta": motion.relative})


func _button(event: InputEventMouseButton) -> void:
	var pos := event.position
	if event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		var span := REF_SPAN / WHEEL_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else REF_SPAN * WHEEL_STEP
		_action("camera_pan_zoom_begin", pos, REF_SPAN)
		_action("camera_pan_zoom", pos, span)
		rig.handle_camera_action({"type": "camera_end"})
	elif event.button_index == ORBIT_BUTTON or event.button_index == PAN_BUTTON:
		if not event.pressed:
			_drag = ""
			rig.handle_camera_action({"type": "camera_end"})
		elif event.button_index == PAN_BUTTON or event.shift_pressed:
			_drag = "pan"
			_action("camera_pan_zoom_begin", pos, REF_SPAN)
		else:
			_drag = "orbit"
			rig.handle_camera_action({"type": "camera_orbit_begin"})


func _action(type: String, centroid: Vector2, span: float) -> void:
	rig.handle_camera_action({"type": type, "centroid": centroid, "span": span})
