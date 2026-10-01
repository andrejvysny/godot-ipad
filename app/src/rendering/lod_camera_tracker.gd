class_name LodCameraTracker
extends RefCounted
## Camera snapshot used by LOD decisions: detects motion (position > MOVE_M, orientation, fov or viewport
## height change), tells whether navigation has settled and converts metric distances to the reference view.

const MOVE_M := 0.25

var has_camera := false
var pos := Vector3.INF
var fov: float = 0.0
var last_move_ms: int = -1000000  # "settled long ago" until the first motion

var _basis := Basis()
var _vh: float = LodPolicy.REFERENCE_VIEWPORT_H


## True when the camera moved since the last update. A missing or detached camera clears has_camera.
func update(camera: Camera3D, now_ms: int) -> bool:
	if camera == null or not camera.is_inside_tree():
		has_camera = false
		return false
	var xf := camera.global_transform
	var vh := camera.get_viewport().get_visible_rect().size.y
	var moved := not has_camera or xf.origin.distance_to(pos) > MOVE_M or not xf.basis.is_equal_approx(_basis) \
			or not is_equal_approx(camera.fov, fov) or not is_equal_approx(vh, _vh)
	has_camera = true
	if moved:
		pos = xf.origin
		_basis = xf.basis
		fov = camera.fov
		_vh = vh
		last_move_ms = now_ms
	return moved


func settled(now_ms: int, settle_ms: int) -> bool:
	return now_ms - last_move_ms >= settle_ms


## Effective distance of an axis-aligned box (see LodPolicy.effective_distance); 0 without a camera.
func effective_to_box(lo: Vector3, hi: Vector3) -> float:
	if not has_camera:
		return 0.0
	return LodPolicy.effective_distance(pos.distance_to(pos.clamp(lo, hi)), fov, _vh)
