class_name ScatterView
extends RefCounted
## Camera and edit-area state the scatter renderer selects by (spec §8.1, §8.2): effective distance of a cell,
## camera settling, the orbit pivot and the active area that raises decorative density. The active area is
## the ActiveEditArea circles while an operation runs (captured once as `frozen`, so densities under the
## brush stay put for the whole operation), else a circle around the camera's orbit pivot that moves only
## after the camera has settled.

const FOCUS_REACH_M := 2000.0

var camera: Camera3D
var has_camera := false
var pos := Vector3.ZERO
var focus := Vector3.ZERO  # camera forward ray on the y = 0 plane (work-queue ordering)
var fov := LodPolicy.REFERENCE_FOV_DEG
var viewport_h := LodPolicy.REFERENCE_VIEWPORT_H
var settle_ms := 250
var moved_ms := 0
var area: ActiveEditArea
var frozen := {}  # Vector2i (ground-cover cells) -> true while `freezing`
var freezing := false
var active_valid := false
var active_center := Vector2.ZERO
var active_radius := 20.0

var _xf := Transform3D()


## True when the camera transform changed since the last call.
func track(now_ms: int) -> bool:
	if camera == null or not camera.is_inside_tree():
		has_camera = false
		return false
	var viewport := camera.get_viewport()
	var moved := not has_camera or camera.global_transform != _xf
	has_camera = true
	_xf = camera.global_transform
	pos = _xf.origin
	fov = camera.fov
	if viewport != null:
		viewport_h = viewport.get_visible_rect().size.y
	if moved:
		moved_ms = now_ms
		var fwd := -_xf.basis.z
		focus = pos + fwd * minf(-pos.y / fwd.y, FOCUS_REACH_M) if fwd.y < -0.05 and pos.y > 0.0 else pos
	return moved


func is_settled(now_ms: int) -> bool:
	return now_ms - moved_ms >= settle_ms


## Where the forward ray meets the terrain (two refinements of the plane height); the camera position
## when it does not look down.
func ground_pivot(doc: WorldDocument) -> Vector3:
	var fwd := -_xf.basis.z
	if fwd.y > -0.05:
		return pos
	var p := pos
	var plane_y := 0.0
	for _i in 2:
		p = pos + fwd * clampf((plane_y - pos.y) / fwd.y, 0.0, FOCUS_REACH_M)
		var h := doc.sample_height(p.x, p.z)
		plane_y = 0.0 if is_nan(h) else h
	return p


## LodPolicy effective distance from the camera to the cell's box (`y_span` = height range around `y_ref`).
func effective(cell: Vector2i, size: float, y_ref: float, y_span: Vector2) -> float:
	var x0 := cell.x * size
	var z0 := cell.y * size
	var dx := maxf(maxf(x0 - pos.x, 0.0), pos.x - (x0 + size))
	var dz := maxf(maxf(z0 - pos.z, 0.0), pos.z - (z0 + size))
	var dy := maxf(maxf(y_ref + y_span.x - pos.y, 0.0), pos.y - (y_ref + y_span.y))
	return LodPolicy.effective_distance(sqrt(dx * dx + dy * dy + dz * dz), fov, viewport_h)


## Whether a ground-cover cell lies in the active area (see class comment).
func cell_is_active(key: Vector2i, size: float) -> bool:
	if freezing:
		return frozen.has(key)
	if not active_valid:
		return false
	var nx := clampf(active_center.x, key.x * size, (key.x + 1) * size)
	var nz := clampf(active_center.y, key.y * size, (key.y + 1) * size)
	return Vector2(nx - active_center.x, nz - active_center.y).length() <= active_radius


func is_pinned(key: Vector2i) -> bool:
	return area != null and area.is_pinned(key)
