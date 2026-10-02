class_name BenchCameraPaths
extends RefCounted
## Deterministic world-relative camera paths of the render bench (spec §20.2). pose() is a pure function of the
## path name, the anchors of the built world and the time since the window started; nothing depends on the
## frame rate, so two runs of one world see the same poses. Poses use the controller's pose format
## {pivot, yaw, pitch, distance, fov_deg}; the camera controller clamps pitch and distance to its limits.

const OVERVIEW_PITCH_DEG := 70.0
const FOCUS_PITCH_DEG := 35.0
const FOCUS_DISTANCE_M := 40.0
const SHALLOW_PITCH_DEG := 15.0
const SHALLOW_DISTANCE_M := 25.0
const CANOPY_DISTANCE_M := 6.0
const CANOPY_PITCH_DEG := 30.0
const YAW_DEG := 30.0
const PATH_ORBIT_DEG := 360.0
const PATH_PAN_M := 60.0
const TRAVEL_PERIOD_S := 2.0
const SUMMARY_SAMPLES := 6


## ctx: {"anchors": {focus: Vector2, far: Vector2, crown_height_m, rect}, "height": Callable(x, z) -> float,
## "fit_distance": float (whole-world framing distance at the overview pitch)}.
static func pose(name: String, ctx: Dictionary, t: float, duration: float) -> Dictionary:
	var anchors: Dictionary = ctx.anchors
	var focus: Vector2 = anchors.focus
	match name:
		"overview":
			return _pose(_ground(ctx, Vector2.ZERO), YAW_DEG, OVERVIEW_PITCH_DEG, float(ctx.fit_distance))
		"focus":
			return _pose(_ground(ctx, focus), YAW_DEG, FOCUS_PITCH_DEG, FOCUS_DISTANCE_M)
		"shallow":
			return _pose(_ground(ctx, focus), YAW_DEG, SHALLOW_PITCH_DEG, SHALLOW_DISTANCE_M)
		"canopy":
			var pivot := _ground(ctx, focus)
			pivot.y += float(anchors.crown_height_m)
			return _pose(pivot, YAW_DEG, CANOPY_PITCH_DEG, CANOPY_DISTANCE_M)
		"path":
			return _path(ctx, focus, t, duration)
		"zoom_transition", "threshold_oscillation", "rotation":
			return _size_path(name, ctx, focus, t, duration)
		"travel":
			var far: Vector2 = anchors.far
			var at_far := int(floor(t / TRAVEL_PERIOD_S)) % 2 == 1
			return _pose(_ground(ctx, far if at_far else focus), YAW_DEG, FOCUS_PITCH_DEG, FOCUS_DISTANCE_M)
	return _pose(_ground(ctx, focus), YAW_DEG, FOCUS_PITCH_DEG, FOCUS_DISTANCE_M)


static func _size_path(name: String, ctx: Dictionary, focus: Vector2, t: float, duration: float) -> Dictionary:
	var u := clampf(t / maxf(duration, 0.001), 0.0, 1.0)
	if name == "rotation":
		return _pose(_ground(ctx, focus), YAW_DEG + u * PATH_ORBIT_DEG, FOCUS_PITCH_DEG, FOCUS_DISTANCE_M)
	var distance := float(ctx.get("threshold_distance", ctx.fit_distance)) * (1.0 + 0.05 * sin(t * TAU / TRAVEL_PERIOD_S))
	if name == "zoom_transition":
		distance = exp(lerpf(log(FOCUS_DISTANCE_M), log(maxf(float(ctx.fit_distance), FOCUS_DISTANCE_M)), u))
	return _pose(_ground(ctx, Vector2.ZERO), YAW_DEG, OVERVIEW_PITCH_DEG, distance)


## Calibrate once before timing; a framing distance alone does not locate the overview boundary.
static func threshold_distance(snapshot: RenderCameraSnapshot, bounds: AABB, pivot: Vector3,
		fit_distance: float, target_ratio: float) -> float:
	if snapshot == null or not snapshot.valid:
		return fit_distance
	var probe := RenderCameraSnapshot.new()
	probe.valid = true
	probe.projection = snapshot.projection
	probe.viewport_size = snapshot.viewport_size
	probe.internal_size = snapshot.internal_size
	probe.render_scale = snapshot.render_scale
	probe.near = snapshot.near
	var controller := OrbitCameraController.new()
	controller.pivot = pivot
	controller.yaw = deg_to_rad(YAW_DEG)
	controller.pitch = deg_to_rad(OVERVIEW_PITCH_DEG)
	var low := 3.0
	var high := maxf(fit_distance * 2.0, low)
	for i in 24:
		controller.distance = (low + high) * 0.5
		probe.transform = controller.camera_transform()
		var measured := ProjectedBounds.measure(bounds, probe)
		if measured.conservative or float(measured.extent_ratio) > target_ratio:
			low = controller.distance
		else:
			high = controller.distance
	return (low + high) * 0.5


## One full orbit while the pivot pans back and forth along X over the patch and the distance zooms between
## the whole-area and a close view, so LOD tiers and 32 m cells change throughout the window.
static func _path(ctx: Dictionary, focus: Vector2, t: float, duration: float) -> Dictionary:
	var u := clampf(t / maxf(duration, 0.001), 0.0, 1.0)
	var pan := sin(u * TAU) * PATH_PAN_M
	var center := _ground(ctx, focus + Vector2(pan, 0.0))
	var zoom := 0.5 - 0.5 * cos(u * TAU * 2.0)
	var distance := lerpf(12.0, float(ctx.fit_distance) * 0.25, zoom)
	var pitch := lerpf(20.0, 55.0, 0.5 - 0.5 * cos(u * TAU))
	return _pose(center, YAW_DEG + u * PATH_ORBIT_DEG, pitch, distance)


static func _ground(ctx: Dictionary, p: Vector2) -> Vector3:
	var h: float = (ctx.height as Callable).call(p.x, p.y)
	return Vector3(p.x, 0.0 if is_nan(h) else h, p.y)


static func _pose(pivot: Vector3, yaw_deg: float, pitch_deg: float, distance: float) -> Dictionary:
	return {"pivot": pivot, "yaw": deg_to_rad(yaw_deg), "pitch": deg_to_rad(pitch_deg), "distance": distance}


## Pose sequence summary for the report: SUMMARY_SAMPLES evenly spaced poses with rounded values.
static func summary(name: String, ctx: Dictionary, duration: float) -> Dictionary:
	var samples: Array[Dictionary] = []
	for i in SUMMARY_SAMPLES:
		var t := duration * float(i) / float(SUMMARY_SAMPLES - 1)
		var p := pose(name, ctx, t, duration)
		var pivot: Vector3 = p.pivot
		samples.append({"t_s": snappedf(t, 0.01), "pivot": [snappedf(pivot.x, 0.01), snappedf(pivot.y, 0.01),
			snappedf(pivot.z, 0.01)], "yaw_deg": snappedf(rad_to_deg(float(p.yaw)), 0.1),
			"pitch_deg": snappedf(rad_to_deg(float(p.pitch)), 0.1), "distance_m": snappedf(float(p.distance), 0.01)})
	return {"path": name, "duration_s": duration, "samples": samples}
