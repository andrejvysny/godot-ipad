class_name ProjectedBounds
extends RefCounted
## Unclipped eight-corner AABB projection. Near-plane intersections retain geometry conservatively.


static func measure(bounds: AABB, snapshot: RenderCameraSnapshot) -> Dictionary:
	var result := _conservative()
	if snapshot == null or not snapshot.valid or not snapshot.inputs_valid() \
			or not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size == Vector3.ZERO:
		return result
	var box := bounds.abs()
	var inverse := snapshot.transform.affine_inverse()
	var closest_depth := -INF
	var farthest_depth := INF
	var points: Array[Vector3] = []
	for index in 8:
		var point := inverse * box.get_endpoint(index)
		if not point.is_finite():
			return result
		points.append(point)
		closest_depth = maxf(closest_depth, -point.z)
		farthest_depth = minf(farthest_depth, -point.z)
	if closest_depth <= 0.0:
		return {"valid": true, "conservative": false, "behind": true, "reference_px": 0.0,
				"display_px": 0.0, "internal_px": 0.0, "rect": Rect2(), "extent_ratio": 0.0}
	if farthest_depth <= snapshot.near:
		result.valid = true
		return result
	return _project(points, snapshot)


static func _project(points: Array[Vector3], snapshot: RenderCameraSnapshot) -> Dictionary:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point in points:
		var clip := snapshot.projection * Vector4(point.x, point.y, point.z, 1.0)
		if not clip.is_finite() or absf(clip.w) < 1e-12:
			return _conservative()
		var ndc := Vector2(clip.x, -clip.y) / clip.w
		if not ndc.is_finite():
			return _conservative()
		low = low.min(ndc)
		high = high.max(ndc)
	var normalized_size := (high - low) * 0.5
	var display_size := normalized_size * snapshot.viewport_size
	var internal_size := normalized_size * snapshot.internal_size
	var display_px := maxf(display_size.x, display_size.y)
	return {"valid": true, "conservative": false, "behind": false,
			"reference_px": display_px * LodPolicy.REFERENCE_VIEWPORT_H / snapshot.viewport_size.y,
			"display_px": display_px, "internal_px": maxf(internal_size.x, internal_size.y),
			"rect": Rect2((low + Vector2.ONE) * 0.5 * snapshot.viewport_size, display_size),
			"extent_ratio": maxf(normalized_size.x, normalized_size.y)}


static func _conservative() -> Dictionary:
	return {"valid": false, "conservative": true, "behind": false, "reference_px": INF,
			"display_px": INF, "internal_px": INF, "rect": Rect2(), "extent_ratio": INF}
