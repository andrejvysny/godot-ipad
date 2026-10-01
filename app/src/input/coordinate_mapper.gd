class_name CoordinateMapper
extends RefCounted
## The single place where device scale is applied (spec §6.3). Converts provider positions to
## root-viewport canvas coordinates, the space Control.get_global_rect() and push_input(ev, true)
## use.
##
## SPACE_UIKIT_POINTS: window_px = raw_points * content_scale (Godot's iOS view sizes its
## drawable as points * contentScaleFactor), then viewport = root_final_transform^-1 * window_px,
## exactly the transform Viewport._make_input_local applies to OS events. 3D render scale
## (scaling_3d_scale) is not part of this transform, so UI picking never moves with it.
##
## A singular or non-finite root transform (e.g. a zero-size window) makes the mapping invalid:
## map()/unmap() return NAN ("no sample") in uikit_points space and point conversions return NAN,
## so callers never route input through a degenerate transform.

var generation: int = 0

var _space: String = InputProvider.SPACE_VIEWPORT
var _content_scale: float = 1.0
var _final := Transform2D.IDENTITY
var _inverse := Transform2D.IDENTITY
var _viewport_size := Vector2.ZERO
var _configured := false
var _valid := true


## Returns true when the mapping changed (and `generation` was bumped).
func configure(space: String, metrics: Dictionary, root_final_transform: Transform2D,
		viewport_size: Vector2) -> bool:
	var scale: float = float(metrics.get("content_scale", 1.0))
	if not is_finite(scale) or scale <= 0.0:
		scale = 1.0
	if _configured and space == _space and scale == _content_scale \
			and root_final_transform == _final and viewport_size == _viewport_size:
		return false
	_configured = true
	_space = space
	_content_scale = scale
	_final = root_final_transform
	_valid = _is_invertible(root_final_transform)
	_inverse = root_final_transform.affine_inverse() if _valid else Transform2D.IDENTITY
	_viewport_size = viewport_size
	generation += 1
	return true


## False while the root transform is singular or non-finite.
func is_valid() -> bool:
	return _valid


func space() -> String:
	return _space


func content_scale() -> float:
	return _content_scale


func viewport_size() -> Vector2:
	return _viewport_size


func map(raw: Vector2) -> Vector2:
	if _space == InputProvider.SPACE_UIKIT_POINTS:
		return _inverse * (raw * _content_scale) if _valid else Vector2(NAN, NAN)
	return raw


## Inverse of map(); used by calibration and tests.
func unmap(viewport_pos: Vector2) -> Vector2:
	if _space == InputProvider.SPACE_UIKIT_POINTS:
		return (_final * viewport_pos) / _content_scale if _valid else Vector2(NAN, NAN)
	return viewport_pos


## Viewport units per logical point, for point-based thresholds (5 pt orbit, 2 pt calibration).
## Assumes uniform stretch (canvas_items + expand keeps aspect).
func viewport_units_per_point() -> float:
	return _content_scale * _inverse.get_scale().x if _valid else NAN


func points_to_viewport(points: float) -> float:
	return points * viewport_units_per_point()


func viewport_to_points(units: float) -> float:
	var upp := viewport_units_per_point()
	return units / upp if upp > 0.0 else NAN


static func _is_invertible(t: Transform2D) -> bool:
	return t.x.is_finite() and t.y.is_finite() and t.origin.is_finite() \
			and absf(t.determinant()) > 1e-12
