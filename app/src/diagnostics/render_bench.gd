class_name RenderBench
extends Node
## In-app render benchmark (spec §18.1, §18.3): frame time, GPU/CPU render time and draw counts
## over object count x render profile x camera pose, written as one JSON report. The authored
## document, history and storage are never touched; the presenter shows a synthetic copy that is
## replaced by the real document when the run ends (or when this node is freed early).
## Results only count as device evidence when produced on an iPad (evidence_class says which).

signal finished(report: Dictionary)

const GROUND_PITCH_DEG := 15.0
const GROUND_DISTANCE_M := 25.0
const PEAK_KEYS: Array[String] = ["visible_draws", "shadow_draws", "visible_prims", "shadow_prims",
	"visible_objects", "gpu_ms", "cpu_ms"]

var output_dir := "user://traces"
var warmup_frames := 90
var measure_frames := 300
var counts := PackedInt32Array([0, 1000, 5000])
var rng_seed := 1234
var report: Dictionary = {}

var _session: EditorSession
var _running := false
var _presented_synthetic := false
var _current_count := -1
var _saved: Dictionary = {}


func start(session: EditorSession) -> String:
	if _running:
		return "Render bench is already running."
	if session.tools.has_active_operation():
		return EditorSession.BUSY_MESSAGE
	_session = session
	_saved = _capture()
	_running = true
	session.post_message("Render bench running — do not touch the screen")
	_run()
	return ""


func _exit_tree() -> void:
	if _running:
		_running = false
		_restore()


func _capture() -> Dictionary:
	var sun := _session.sun
	return {"shadows": sun.shadow_enabled, "mode": sun.directional_shadow_mode,
		"distance": sun.directional_shadow_max_distance,
		"scale": _session.get_viewport().scaling_3d_scale, "pose": _session.rig.controller.get_pose()}


func _restore() -> void:
	if not is_instance_valid(_session) or _saved.is_empty():
		return
	var sun := _session.sun
	sun.shadow_enabled = _saved.shadows
	sun.directional_shadow_mode = _saved.mode
	sun.directional_shadow_max_distance = _saved.distance
	_session.get_viewport().scaling_3d_scale = _saved.scale
	_session.terrain.set_render_probe(true, true)
	_session.rig.reset_to(_saved.pose)
	if _presented_synthetic:
		_session.presenter.rebuild(_session.document)
		_presented_synthetic = false
	_saved = {}
	_session.status_changed.emit()


func _run() -> void:
	var started := Time.get_unix_time_from_system()
	var results: Array[Dictionary] = []
	for step in BenchPlan.default_steps(counts):
		results.append(await _run_step(step))
		if not _running:
			return
	_restore()
	_running = false
	report = _build_report(results, started)
	var path := _write_report()
	if path != "":
		_session.post_message("Render bench saved: " + path)
		print("RENDER_BENCH saved ", ProjectSettings.globalize_path(path))
	finished.emit(report)
	if OS.get_cmdline_user_args().has("--bench-quit"):
		get_tree().quit(0)


func _run_step(step: Dictionary) -> Dictionary:
	var settings := BenchPlan.profile_settings(step.profile)
	_apply_settings(settings)
	_apply_camera(step.camera)
	var rebuild_ms := _present_count(int(step.count))
	await _wait_frames(warmup_frames)
	if not _running:
		return {}
	var measured := await _measure()
	var out := step.duplicate()
	out.merge({"rebuild_ms": rebuild_ms, "objects_presented": _session.presenter.object_count(),
		"settings": settings, "summary": measured.summary, "counters_peak": measured.peak,
		"counters_last": measured.last, "disturbed": measured.disturbed})
	return out


func _apply_settings(s: Dictionary) -> void:
	var sun := _session.sun
	sun.shadow_enabled = s.shadows
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if int(s.splits) == 4 \
			else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = s.shadow_distance
	_session.get_viewport().scaling_3d_scale = s.scale
	_session.terrain.set_render_probe(s.terrain_visible, s.terrain_shadows)


func _apply_camera(camera: String) -> void:
	var height := _session.document.sample_height(0.0, 0.0)
	var pose := _session.rig.controller.fixture_pose(0.0 if is_nan(height) else height)
	if camera == "ground":
		pose["pitch"] = deg_to_rad(GROUND_PITCH_DEG)
		pose["distance"] = GROUND_DISTANCE_M
	_session.rig.reset_to(pose)


## Rebuilds the presenter when the object count changes; returns the rebuild time in ms (0 if skipped).
func _present_count(count: int) -> float:
	if count == _current_count:
		return 0.0
	_current_count = count
	var doc := _session.document.duplicate_deep()
	for rec in BenchPlan.synth_objects(doc, _session.catalog, count, rng_seed):
		doc.put_object(rec)
	var t0 := Time.get_ticks_usec()
	_session.presenter.rebuild(doc)
	_presented_synthetic = true
	return float(Time.get_ticks_usec() - t0) / 1000.0


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _measure() -> Dictionary:
	var frame_ms := PackedFloat64Array()
	var gpu_ms := PackedFloat64Array()
	var cpu_ms := PackedFloat64Array()
	var peak := {}
	var last := {}
	var disturbed := false
	var viewport := _session.get_viewport()
	var previous := Time.get_ticks_usec()
	for i in measure_frames:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append(float(now - previous) / 1000.0)
		previous = now
		last = RenderCounters.snapshot(viewport)
		gpu_ms.append(float(last.gpu_ms))
		cpu_ms.append(float(last.cpu_ms))
		_track_peak(peak, last)
		disturbed = disturbed or not _session.input.router.contacts().is_empty()
	return {"summary": BenchPlan.summarize(frame_ms, gpu_ms, cpu_ms), "peak": peak, "last": last,
		"disturbed": disturbed}


static func _track_peak(peak: Dictionary, sample: Dictionary) -> void:
	for key in PEAK_KEYS:
		peak[key] = maxf(float(peak.get(key, 0.0)), float(sample[key]))


func _build_report(results: Array[Dictionary], started: float) -> Dictionary:
	var is_device := OS.has_feature("ios") and not OS.has_feature("simulator")
	return {"evidence_class": "DEVICE" if is_device else "HOST — not device evidence",
		"device_model": OS.get_model_name(), "os": OS.get_name() + " " + OS.get_version(),
		"debug_build": OS.is_debug_build(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"viewport_size": [_session.get_viewport().size.x, _session.get_viewport().size.y],
		"warmup_frames": warmup_frames, "measure_frames": measure_frames, "seed": rng_seed,
		"steps": results, "started_unix": started,
		"duration_s": Time.get_unix_time_from_system() - started}


func _write_report() -> String:
	DirAccess.make_dir_recursive_absolute(output_dir)
	var path := output_dir.path_join("render-bench-%d.json" % int(Time.get_unix_time_from_system()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_session.post_message("Render bench report could not be written.", true)
		return ""
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return path
