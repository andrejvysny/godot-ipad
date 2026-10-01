class_name OrbitCameraController
extends RefCounted
## Pure orbit-camera math (spec §8). Angles in radians; pitch > 0 looks down. Fov is vertical
## (Camera3D KEEP_HEIGHT). The camera never rolls: world up is always +Y.

const DEFAULTS := {
	"pitch_min_deg": 15.0, "pitch_max_deg": 80.0, "distance_min_m": 3.0, "distance_max_m": 350.0,
	"initial_pitch_deg": 45.0, "initial_yaw_deg": 30.0, "initial_distance_m": 140.0,
	"fov_deg": 60.0, "ground_clearance_m": 1.0, "orbit_deg_per_viewport_width": 270.0,
	"precision_distance_m": 30.0, "precision_min_factor": 0.4,
}

var pivot := Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var distance: float = 100.0
var fov_deg: float = 60.0

var _cfg: Dictionary = {}
const MAX_HIT_DISTANCE_FACTOR := 4.0  # grazing hits farther than this * distance count as no hit

var _gesture_active := false
var _anchored := false
var _plane_y: float = 0.0
var _base_distance: float = 0.0
var _base_span: float = 1.0
var _base_pivot := Vector3.ZERO
var _anchor := Vector3.ZERO


func _init(config: Dictionary = {}) -> void:
	_cfg = DEFAULTS.duplicate()
	for key: String in config:
		_cfg[key] = config[key]
	fov_deg = _f("fov_deg")
	reset_to({})


func _f(key: String) -> float:
	return float(_cfg[key])


func reset_to(pose: Dictionary) -> void:
	end()
	pivot = pose.get("pivot", Vector3.ZERO)
	yaw = float(pose.get("yaw", deg_to_rad(_f("initial_yaw_deg"))))
	pitch = float(pose.get("pitch", deg_to_rad(_f("initial_pitch_deg"))))
	distance = float(pose.get("distance", _f("initial_distance_m")))
	fov_deg = float(pose.get("fov_deg", _f("fov_deg")))
	_clamp_state()


func fixture_pose(center_height: float) -> Dictionary:
	return {
		"pivot": Vector3(0.0, center_height, 0.0),
		"yaw": deg_to_rad(_f("initial_yaw_deg")),
		"pitch": deg_to_rad(_f("initial_pitch_deg")),
		"distance": _f("initial_distance_m"),
		"fov_deg": _f("fov_deg"),
	}


func get_pose() -> Dictionary:
	return {"pivot": pivot, "yaw": yaw, "pitch": pitch, "distance": distance, "fov_deg": fov_deg}


func set_pose(pose: Dictionary) -> void:
	reset_to(pose)


func _clamp_state() -> void:
	pitch = clampf(pitch, deg_to_rad(_f("pitch_min_deg")), deg_to_rad(_f("pitch_max_deg")))
	distance = clampf(distance, _f("distance_min_m"), _f("distance_max_m"))


func camera_position() -> Vector3:
	var cp := cos(pitch)
	return pivot + Vector3(sin(yaw) * cp, sin(pitch), cos(yaw) * cp) * distance


func camera_transform() -> Transform3D:
	var z := (camera_position() - pivot).normalized()
	var x := Vector3.UP.cross(z).normalized()
	var y := z.cross(x)
	return Transform3D(Basis(x, y, z), camera_position())


## Returns [origin, direction]; matches Camera3D.project_ray_origin/normal for this pose.
func screen_ray(pos: Vector2, viewport_size: Vector2) -> Array[Vector3]:
	if not _valid_viewport(viewport_size):
		var o := camera_position()
		return [o, (pivot - o).normalized()]
	var t := camera_transform()
	var th := tan(deg_to_rad(fov_deg) * 0.5)
	var aspect := viewport_size.x / viewport_size.y
	var ndc_x := pos.x / viewport_size.x * 2.0 - 1.0
	var ndc_y := 1.0 - pos.y / viewport_size.y * 2.0
	var local := Vector3(ndc_x * th * aspect, ndc_y * th, -1.0)
	var dir := (t.basis * local).normalized()
	return [t.origin, dir]


func _valid_viewport(size: Vector2) -> bool:
	return size.x > 0.0 and size.y > 0.0


func precision_factor() -> float:
	var f := clampf(distance / _f("precision_distance_m"), 0.0, 1.0)
	return lerpf(_f("precision_min_factor"), 1.0, f)


func orbit(delta: Vector2, viewport_size: Vector2) -> void:
	if not _valid_viewport(viewport_size):
		return
	var k := deg_to_rad(_f("orbit_deg_per_viewport_width")) / viewport_size.x * precision_factor()
	yaw -= delta.x * k
	pitch += delta.y * k
	_clamp_state()


func _ground_hit(pos: Vector2, viewport_size: Vector2, plane_y: float) -> Variant:
	var ray := screen_ray(pos, viewport_size)
	if ray[1].y > -1e-6:
		return null
	var t := (plane_y - ray[0].y) / ray[1].y
	if t <= 0.0 or t > MAX_HIT_DISTANCE_FACTOR * distance:
		return null
	return ray[0] + ray[1] * t


func pan_zoom_begin(centroid: Vector2, span: float, viewport_size: Vector2) -> void:
	_gesture_active = true
	_plane_y = pivot.y
	_base_distance = distance
	_base_span = maxf(span, 1.0)
	_base_pivot = pivot
	var hit: Variant = _ground_hit(centroid, viewport_size, _plane_y)
	_anchored = hit != null
	_anchor = hit if _anchored else pivot


func pan_zoom_update(centroid: Vector2, span: float, viewport_size: Vector2) -> void:
	if not _gesture_active:
		pan_zoom_begin(centroid, span, viewport_size)
		return
	var ratio := _base_span / maxf(span, 1.0)
	var last_pivot := pivot
	distance = clampf(_base_distance * ratio, _f("distance_min_m"), _f("distance_max_m"))
	if not _anchored:
		# First hit after a miss: re-baseline here so the pivot never jumps.
		var first: Variant = _ground_hit(centroid, viewport_size, _plane_y)
		if first != null:
			_anchor = first
			_base_pivot = pivot
			_base_distance = distance
			_base_span = maxf(span, 1.0)
			_anchored = true
		return
	pivot = _base_pivot
	var hit: Variant = _ground_hit(centroid, viewport_size, _plane_y)
	if hit == null:
		pivot = last_pivot
		return
	var shift: Vector3 = _anchor - (hit as Vector3)
	pivot = Vector3(
		clampf(_base_pivot.x + shift.x, WorldConstants.WORLD_MIN, WorldConstants.WORLD_MAX_SAMPLE),
		_base_pivot.y,
		clampf(_base_pivot.z + shift.z, WorldConstants.WORLD_MIN, WorldConstants.WORLD_MAX_SAMPLE))


func end() -> void:
	_gesture_active = false


func focus_point(p: Vector3) -> void:
	end()
	pivot = p


func focus_bounds(box: AABB) -> void:
	end()
	pivot = box.get_center()
	var radius := box.size.length() * 0.5
	var half_fov := deg_to_rad(fov_deg) * 0.5
	distance = clampf(radius / sin(half_fov) * 1.2, _f("distance_min_m"), _f("distance_max_m"))


## sampler(x, z) -> ground height, NAN outside the world (no adjustment there).
func apply_clearance(height_sampler: Callable) -> bool:
	var need := _f("ground_clearance_m")
	var adjusted := false
	var pitch_max := deg_to_rad(_f("pitch_max_deg"))
	while true:
		var cp := camera_position()
		var h: float = height_sampler.call(cp.x, cp.z)
		if is_nan(h) or cp.y >= h + need - 1e-5:
			return adjusted
		if pitch >= pitch_max:
			pivot.y += h + need - cp.y
			return true
		pitch = minf(pitch + deg_to_rad(1.0), pitch_max)
		adjusted = true
	return adjusted
