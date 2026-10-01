class_name OrbitCameraRig
extends Node3D
## Scene-side owner of the orbit controller. Consumes router camera actions (spec §7.2, §8).
## `frozen` is set while the Pencil owns input; motion actions are then ignored.

var controller: OrbitCameraController
var height_sampler := Callable()
var frozen := false

var _camera: Camera3D


func _init(config: Dictionary = {}) -> void:
	controller = OrbitCameraController.new(config)
	_camera = Camera3D.new()
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.far = 2000.0
	add_child(_camera)
	_camera.current = true
	_sync()


func get_camera() -> Camera3D:
	return _camera


func _viewport_size() -> Vector2:
	if is_inside_tree():
		return get_viewport().get_visible_rect().size
	return Vector2(1180, 820)


func handle_camera_action(action: Dictionary) -> void:
	var type := str(action.get("type", ""))
	if type == "camera_end":
		controller.end()
		return
	if frozen:
		return
	var vp := _viewport_size()
	var clearance := true
	match type:
		"camera_orbit_begin":
			controller.end()
		"camera_orbit":
			controller.orbit(action.get("delta", Vector2.ZERO), vp)
		"camera_pan_zoom_begin":
			controller.pan_zoom_begin(action.get("centroid", Vector2.ZERO), float(action.get("span", 1.0)), vp)
			clearance = false  # CA-02: no displacement on the transition frame
		"camera_pan_zoom":
			controller.pan_zoom_update(action.get("centroid", Vector2.ZERO), float(action.get("span", 1.0)), vp)
		_:
			return
	_sync(clearance)


func focus_point(p: Vector3) -> void:
	controller.focus_point(p)
	_sync()


func focus_bounds(box: AABB) -> void:
	controller.focus_bounds(box)
	_sync()


func reset_to(pose: Dictionary) -> void:
	controller.reset_to(pose)
	_sync()


func _sync(clearance := true) -> void:
	if clearance and height_sampler.is_valid():
		controller.apply_clearance(height_sampler)
	_camera.transform = controller.camera_transform()
	_camera.fov = controller.fov_deg
