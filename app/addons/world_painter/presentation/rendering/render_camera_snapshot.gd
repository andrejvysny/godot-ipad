class_name RenderCameraSnapshot
extends RefCounted
## Camera inputs captured once per decision pass; no live camera reads during projection.

var valid := false
var transform := Transform3D.IDENTITY
var projection := Projection.IDENTITY
var viewport_size := Vector2.ZERO
var internal_size := Vector2.ZERO
var render_scale := 1.0
var near := 0.05
var generation := 0
var downward_pitch_deg := 0.0
var projection_mode := Camera3D.PROJECTION_PERSPECTIVE
var keep_aspect := Camera3D.KEEP_HEIGHT
var fov_deg := 0.0
var orthographic_size := 0.0
var frustum_offset := Vector2.ZERO


static func capture(camera: Camera3D, next_generation: int = 0) -> RenderCameraSnapshot:
	var result := RenderCameraSnapshot.new()
	result.generation = next_generation
	if camera == null or not camera.is_inside_tree():
		return result
	var viewport := camera.get_viewport()
	result.transform = camera.get_camera_transform()
	result.projection = camera.get_camera_projection()
	result.viewport_size = viewport.get_visible_rect().size
	result.render_scale = viewport.scaling_3d_scale
	result.internal_size = result.viewport_size * result.render_scale
	result.near = camera.near
	result.projection_mode = camera.projection
	result.keep_aspect = camera.keep_aspect
	result.fov_deg = camera.fov
	result.orthographic_size = camera.size
	result.frustum_offset = camera.frustum_offset
	var forward := -result.transform.basis.z.normalized()
	result.downward_pitch_deg = rad_to_deg(asin(clampf(-forward.y, -1.0, 1.0)))
	result.valid = result.inputs_valid()
	return result


func inputs_valid() -> bool:
	return transform.origin.is_finite() and transform.basis.is_finite() \
			and absf(transform.basis.determinant()) > 1e-12 \
			and projection.x.is_finite() and projection.y.is_finite() \
			and projection.z.is_finite() and projection.w.is_finite() \
			and absf(projection.determinant()) > 1e-12 \
			and viewport_size.is_finite() and viewport_size.x > 0.0 and viewport_size.y > 0.0 \
			and internal_size.is_finite() and internal_size.x > 0.0 and internal_size.y > 0.0 \
			and is_finite(render_scale) and render_scale > 0.0 and is_finite(near) and near > 0.0


func same_inputs(other: RenderCameraSnapshot) -> bool:
	return other != null and valid == other.valid and transform == other.transform \
			and projection == other.projection and viewport_size == other.viewport_size \
			and internal_size == other.internal_size and render_scale == other.render_scale \
			and near == other.near and projection_mode == other.projection_mode \
			and keep_aspect == other.keep_aspect and fov_deg == other.fov_deg \
			and orthographic_size == other.orthographic_size and frustum_offset == other.frustum_offset
