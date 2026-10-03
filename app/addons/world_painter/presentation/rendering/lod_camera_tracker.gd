class_name LodCameraTracker
extends RefCounted
## Shared projection snapshot. Any changed projection input invalidates stationary-camera decisions.

const MOVE_M := 0.25

var has_camera := false
var pos := Vector3.INF
var fov: float = 0.0
var last_move_ms: int = -1000000
var generation := 0
var snapshot: RenderCameraSnapshot
var _vh: float = LodPolicy.REFERENCE_VIEWPORT_H


func update(camera: Camera3D, now_ms: int) -> bool:
	var changed := update_snapshot(RenderCameraSnapshot.capture(camera, generation), now_ms)
	if changed:
		snapshot.generation = generation
	if has_camera:
		fov = camera.fov
	return changed


func update_snapshot(captured: RenderCameraSnapshot, now_ms: int) -> bool:
	if captured == null:
		captured = RenderCameraSnapshot.new()
	var changed := snapshot == null or not captured.same_inputs(snapshot)
	if changed:
		generation += 1
		last_move_ms = now_ms
	snapshot = captured
	has_camera = snapshot.valid
	if has_camera:
		pos = snapshot.transform.origin
		_vh = snapshot.viewport_size.y
		# Projection y gives vertical FOV for the legacy perspective-distance API.
		if absf(snapshot.projection.y.y) > 1e-12:
			fov = rad_to_deg(2.0 * atan(1.0 / absf(snapshot.projection.y.y)))
	return changed


func settled(now_ms: int, settle_ms: int) -> bool:
	return now_ms - last_move_ms >= settle_ms


## Legacy metric API remains for HLOD cuts until their replacement pass is complete.
func effective_to_box(lo: Vector3, hi: Vector3) -> float:
	if not has_camera:
		return 0.0
	return LodPolicy.effective_distance(pos.distance_to(pos.clamp(lo, hi)), fov, _vh)
