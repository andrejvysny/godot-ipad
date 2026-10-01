class_name SelfTestDriver
extends Node
## Drives the synthetic input of the editor self-test: projects world points through the session
## camera and pushes pointer samples across real frames. Also snapshots document buffers.

const MAX_ATTEMPTS := 3

var session: EditorSession
var provider: ScriptedInputProvider
var next_id := 100


# --- Input driving ------------------------------------------------------------------------

func next_contact() -> int:
	next_id += 1
	return next_id


func frame() -> void:
	await get_tree().process_frame


func frames(count: int) -> void:
	for i in count:
		await frame()


func until(deadline_usec: int) -> void:
	await frame()
	while Time.get_ticks_usec() < deadline_usec:
		await frame()


func to_screen(world: Vector3) -> Vector2:
	return session.rig.get_camera().unproject_position(world)


func ground(x: float, z: float) -> Vector3:
	return Vector3(x, session.document.sample_height(x, z), z)


func hit_at(point: Vector2) -> Vector3:
	var camera := session.rig.get_camera()
	var hit := TerrainPicker.raycast(session.document, camera.project_ray_origin(point), camera.project_ray_normal(point))
	return hit.position if hit.ok else Vector3(NAN, NAN, NAN)


func seg(a: Vector3, b: Vector3) -> Array[Vector3]:
	return [a, b]


## Drags a MOUSE_DEV contact along projected world points; each segment lasts at least segment_s.
func drag(points: Array[Vector3], source: int, contact: int, frames_per_segment: int,
		segment_s := 0.0, dwell_s := 0.0) -> void:
	var path: Array[Vector2] = []
	for p in points:
		path.append(to_screen(p))
	provider.push(source, contact, PointerSample.Phase.BEGIN, path[0])
	await frame()
	for i in range(1, path.size()):
		var started := Time.get_ticks_usec()
		for k in range(1, frames_per_segment + 1):
			var fraction := float(k) / float(frames_per_segment)
			provider.push(source, contact, PointerSample.Phase.MOVE, path[i - 1].lerp(path[i], fraction))
			await until(started + int(segment_s * fraction * 1_000_000.0))
	if dwell_s > 0.0:
		await until(Time.get_ticks_usec() + int(dwell_s * 1_000_000.0))
	provider.push(source, contact, PointerSample.Phase.END, path[path.size() - 1])
	await frame()


## One brush stroke over real time. A stroke cancelled by a frame stall is retried.
func stroke(points: Array[Vector3]) -> Dictionary:
	var before := session.history.size()
	var attempts := 0
	var over_ui := false
	for p in points:
		over_ui = over_ui or bool(session.input.router.ui_hit_test.call(to_screen(p)))
	while attempts < MAX_ATTEMPTS:
		attempts += 1
		var cancels := provider.cancel_events
		await drag(points, PointerSample.Source.MOUSE_DEV, next_contact(), 10, 0.9, 0.2)
		await frames(3)
		if session.history.size() > before or provider.cancel_events == cancels:
			break
	return {"committed": session.history.size() > before, "attempts": attempts, "over_ui": over_ui}


func tap(point: Vector2) -> void:
	var contact := next_contact()
	provider.push(PointerSample.Source.MOUSE_DEV, contact, PointerSample.Phase.BEGIN, point)
	await frames(2)
	provider.push(PointerSample.Source.MOUSE_DEV, contact, PointerSample.Phase.END, point)
	await frames(3)


## Multi-finger gesture: every FINGER contact lerps from starts[i] to ends[i].
func fingers(starts: Array, ends: Array, steps: int) -> void:
	var contacts: Array[int] = []
	for i in starts.size():
		contacts.append(next_contact())
		provider.push(PointerSample.Source.FINGER, contacts[i], PointerSample.Phase.BEGIN, starts[i])
		await frame()
	for k in range(1, steps + 1):
		for i in starts.size():
			var pos: Vector2 = (starts[i] as Vector2).lerp(ends[i], float(k) / float(steps))
			provider.push(PointerSample.Source.FINGER, contacts[i], PointerSample.Phase.MOVE, pos)
		await frame()
	for i in starts.size():
		provider.push(PointerSample.Source.FINGER, contacts[i], PointerSample.Phase.END, ends[i])
	await frame()


func settle_storage() -> void:
	var guard := 0
	while session.storage.is_busy() and guard < 600:
		guard += 1
		await frame()


func snapshot(kind: String) -> Dictionary:
	var out := {}
	for loc: Vector2i in session.document.regions:
		var region := session.document.get_region(loc)
		out[loc] = region.heights.duplicate() if kind == "heights" else region.control.duplicate()
	return out


func changed_regions(a: Dictionary, b: Dictionary) -> Array:
	var out := []
	for loc: Vector2i in a:
		if a[loc] != b[loc]:
			out.append(loc)
	return out
