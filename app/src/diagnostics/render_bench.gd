class_name RenderBench
extends Node
## In-app render benchmark (spec §19, §20.4): frame pacing, GPU/CPU render time with validity, draw
## counts and settling latency over object count x render profile x camera pose, written as one
## JSON report. The run owns the session (EditorSession.claim_bench), which drops tool input and
## refuses world operations meanwhile. The population is a dedicated deterministic document; the
## user's document is never mutated. Every exit path (completion, abort, node removal, world
## replacement, report-write failure) restores the captured session state, releases the claim,
## writes a report and frees the runner.

signal finished(report: Dictionary)
signal aborted(reason: String, report: Dictionary)

const GROUND_PITCH_DEG := 15.0
const GROUND_DISTANCE_M := 25.0
const BENCH_FIXTURE := "gentle_hills"
## Bounds the per-step sample arrays (36000 frames = 10 minutes at 60 fps); acceptance runs repeat steps.
const MAX_MEASURE_FRAMES := 36000
const SETTLE_CAP_MSEC := 10000
const PEAK_KEYS: Array[String] = ["visible_draws", "shadow_draws", "visible_prims", "shadow_prims",
	"visible_objects", "gpu_ms", "cpu_ms"]
const TIMING_KEYS: Array[String] = ["gpu_ms", "cpu_ms"]

var output_dir := "user://traces"
var warmup_frames := 90
var measure_frames := 300
var counts := PackedInt32Array([0, 1000, 5000])
var rng_seed := 1234
var profiles: Array[String] = BenchPlan.PROFILES.duplicate()
var cameras: Array[String] = BenchPlan.CAMERAS.duplicate()
var report: Dictionary = {}
var report_path := ""
var write_error := ""

# --- Scenario/sustained mode (BenchRunner); without scenarios or sustained minutes the legacy matrix runs ---
var scenarios: Array[String] = []
var scenario_profiles: Array[String] = []  # empty: BenchScenarios.BENCH_PROFILES
var scenario_kinds: Array[String] = []  # empty: every camera path and workload of the scenario
var measure_seconds := 10.0
var warmup_seconds := 2.0
var sustained_minutes := 0.0
var world_overrides: Dictionary = {}  # {"objects": n, "scatter": n}: small variants for tests
var screenshots := false  # scenario mode: one PNG per step, taken after its timed window (visual checks)

var _runner: BenchRunner
var _session: EditorSession
var _running := false
var _run_token := 0
var _busy := false  # the _run coroutine has not unwound yet
var _free_pending := false
var _current_count := -1
var _presented_bench := false
var _bench_doc: WorldDocument
var _last_settings: Dictionary = {}
var _saved: Dictionary = {}
var _before: Dictionary = {}
var _results: Array[Dictionary] = []
var _started := 0.0


func is_running() -> bool:
	return _running


func start(session: EditorSession) -> String:
	if _running:
		return EditorSession.BENCH_RUNNING
	if session.tools.has_active_operation():
		return EditorSession.BUSY_MESSAGE
	var claim := session.claim_bench(self)
	if claim != "":
		return claim
	_session = session
	measure_frames = clampi(measure_frames, 1, MAX_MEASURE_FRAMES)
	_prepare_runner(session)
	_saved = _capture()
	_before = BenchReport.authored_state(session)
	_results.clear()
	_started = Time.get_unix_time_from_system()
	_running = true
	session.world_replaced.connect(_on_world_replaced)
	session.tools.select("")
	# Measure every population with vegetation visible and no frame cap; both are restored.
	session.set_vegetation_hidden(false)
	Engine.max_fps = 0
	session.post_message("Render bench running — Diagnostics › Abort bench to stop")
	_run(_run_token)
	return ""


func abort(reason: String) -> void:
	_end("ABORTED", reason)


func _exit_tree() -> void:
	_end("ABORTED", "node_removed")


func _on_world_replaced() -> void:
	_end("ABORTED", "world_replaced")


func _stale(token: int) -> bool:
	return token != _run_token or not is_inside_tree()


func _disturbed() -> bool:
	return not _session.input.router.contacts().is_empty()


# --- Capture and restore (extend both when new session state is touched) ------------------

func _capture() -> Dictionary:
	var viewport := _session.get_viewport()
	var sun := _session.sun
	return {"shadows": sun.shadow_enabled, "mode": sun.directional_shadow_mode,
		"distance": sun.directional_shadow_max_distance, "scale": viewport.scaling_3d_scale,
		"scaling_mode": viewport.scaling_3d_mode, "msaa": viewport.msaa_3d,
		"probe": _session.terrain.get_render_probe(), "pose": _session.rig.controller.get_pose(),
		"selected": _session.tools.selected_id(), "presenter_objects": _session.presenter.authored_object_count(),
		"profile": _session.render_profiles.active_name(), "vegetation_hidden": _session.vegetation_hidden(),
		"max_fps": Engine.max_fps, "attach": BenchAttach.state(_session),
		"preview_off": _session.render_state().texture_preview.state() in [TexturePreviewController.OFF,
		TexturePreviewController.RELEASING]}


## Restores in order: settings, documents, selection, camera. A replaced world keeps its own
## selection and camera. Returns true when a fresh capture equals the saved one.
func _restore(reason: String) -> bool:
	_restore_settings()
	var documents_ok := _restore_documents()
	var keys: Array = _saved.keys()
	if reason != "world_replaced":
		_session.tools.select(_saved.selected)
		_session.rig.reset_to(_saved.pose)
	else:
		keys = ["shadows", "mode", "distance", "scale", "scaling_mode", "msaa", "probe", "profile",
			"vegetation_hidden", "max_fps", "attach", "preview_off"]
	var now := _capture()
	for key: String in keys:
		if not _same(now[key], _saved[key]):
			return false
	return documents_ok


func _restore_settings() -> void:
	if _runner != null:
		_runner.restore()
	var viewport := _session.get_viewport()
	var sun := _session.sun
	sun.shadow_enabled = _saved.shadows
	sun.directional_shadow_mode = _saved.mode
	sun.directional_shadow_max_distance = _saved.distance
	viewport.scaling_3d_scale = _saved.scale
	viewport.scaling_3d_mode = _saved.scaling_mode
	viewport.msaa_3d = _saved.msaa
	_session.terrain.set_render_probe(_saved.probe.visible, _saved.probe.cast_shadows)
	Engine.max_fps = _saved.max_fps
	_session.set_vegetation_hidden(_saved.vegetation_hidden)


func _restore_documents() -> bool:
	if not _presented_bench:
		return true
	_presented_bench = false
	var doc := _session.document
	var error := _session.terrain.replace_document(doc)
	_session.presenter.rebuild(doc)
	_session.layers.rebuild(doc)
	_session.rig.height_sampler = doc.sample_height
	_session.render_state().present_world_rect(Rect2())
	return error == ""


static func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT and typeof(b) == TYPE_FLOAT:
		return is_equal_approx(a, b)
	if typeof(a) == TYPE_VECTOR3 and typeof(b) == TYPE_VECTOR3:
		return (a as Vector3).is_equal_approx(b)
	if typeof(a) == TYPE_DICTIONARY and typeof(b) == TYPE_DICTIONARY:
		for key: Variant in (a as Dictionary).keys():
			if not (b as Dictionary).has(key) or not _same(a[key], b[key]):
				return false
		return (a as Dictionary).size() == (b as Dictionary).size()
	return a == b


# --- Run ---------------------------------------------------------------------------------

func _run(token: int) -> void:
	_busy = true
	if _runner != null:
		await _runner.run(token)
	else:
		await _run_legacy(token)
	_end("COMPLETED", "")  # no-op when the loop was cut short by an abort
	_busy = false
	if _free_pending:
		queue_free()


func _run_legacy(token: int) -> void:
	var steps := BenchPlan.default_steps(counts, profiles, cameras, profiles.size() == BenchPlan.PROFILES.size())
	for step in steps:
		var result := await _run_step(step, token)
		if _stale(token):
			break
		_results.append(result)


func _run_step(step: Dictionary, token: int) -> Dictionary:
	var viewport := _session.get_viewport()
	var t0 := Time.get_ticks_usec()
	var settings := BenchPlan.profile_settings(step.profile)
	var changed := _present_count(int(step.count))
	if not _running:
		return {}
	var probe_error := _apply_settings(settings)
	_apply_camera(step.camera)
	if changed or settings != _last_settings:
		RenderCounters.reset_warmup(viewport)
	_last_settings = settings
	var prepare_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var settle := await _settle(token)
	if _stale(token) or not await _wait_frames(warmup_frames, token):
		return {}
	var measured := await _measure(token)
	if measured.is_empty():
		return {}
	var out := step.duplicate()
	out.merge({"population": {"fixture": BENCH_FIXTURE, "objects": _bench_doc.objects.size(),
		"scatter_instances": _bench_doc.scatter.count(), "paths": _bench_doc.paths.size()},
		"objects_presented": _session.presenter.authored_object_count(), "prepare_ms": prepare_ms,
		"first_frame_ms": settle.first_frame_ms, "settle_ms": settle.settle_ms, "settled": settle.settled,
		"terrain_probe_supported": probe_error == "", "settings": settings, "summary": measured.summary,
		"counters_peak": measured.peak, "counters_last": measured.last, "render": _session.render_summary()})
	return out


func _apply_settings(s: Dictionary) -> String:
	var sun := _session.sun
	sun.shadow_enabled = s.shadows
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if int(s.splits) == 4 \
			else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = s.shadow_distance
	_session.get_viewport().scaling_3d_scale = s.scale
	return _session.terrain.set_render_probe(s.terrain_visible, s.terrain_shadows)


func _apply_camera(camera: String) -> void:
	_session.render_state().present_world_rect(_bench_doc.layout.world_rect())
	var height := _bench_doc.sample_height(0.0, 0.0)
	var pose := _session.rig.controller.fixture_pose(0.0 if is_nan(height) else height)
	if camera == "ground":
		pose["pitch"] = deg_to_rad(GROUND_PITCH_DEG)
		pose["distance"] = GROUND_DISTANCE_M
	_session.rig.reset_to(pose)


## Exactly `count` synthetic objects on a fresh fixture copy (never the user's document), presented
## through the production paths. Rebuilds only when the count changes; true when it did.
func _present_count(count: int) -> bool:
	if count == _current_count:
		return false
	var loaded := SessionWorldOps.load_fixture(BENCH_FIXTURE, _session.catalog)
	if loaded[1] != "":
		_session.post_message("Render bench cannot build its world: " + str(loaded[1]), true)
		abort("bench_world_failed")
		return false
	var doc: WorldDocument = loaded[0]
	doc.objects.clear()
	doc.paths.clear()
	doc.scatter = ScatterLayer.new()
	for rec in BenchPlan.synth_objects(doc, _session.catalog, count, rng_seed):
		doc.put_object(rec)
	_current_count = count
	_bench_doc = doc
	_presented_bench = true
	_session.terrain.replace_document(doc)
	_session.presenter.rebuild(doc)
	_session.layers.rebuild(doc)
	_session.rig.height_sampler = doc.sample_height
	return true


func _pending() -> bool:
	return _session.presenter.has_pending_work() or _session.terrain.has_pending_uploads() \
			or _session.layers.scatter.has_dirty()


## first_frame_ms: end of prepare to the end of the next process frame; settle_ms: until no
## presenter, terrain-upload or scatter work is pending (capped).
func _settle(token: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	await get_tree().process_frame
	if _stale(token):
		return {}
	var first_ms := Time.get_ticks_msec() - t0
	while _pending() and Time.get_ticks_msec() - t0 < SETTLE_CAP_MSEC:
		await get_tree().process_frame
		if _stale(token):
			return {}
	return {"first_frame_ms": first_ms, "settle_ms": Time.get_ticks_msec() - t0, "settled": not _pending()}


## False when the run ended or was aborted (input disturbance) while waiting.
func _wait_frames(n: int, token: int) -> bool:
	for i in n:
		await get_tree().process_frame
		if _stale(token):
			return false
		if _disturbed():
			abort("input_disturbance")
			return false
	return true


func _measure(token: int) -> Dictionary:
	var frame_ms := PackedFloat64Array()
	var gpu_ms := PackedFloat64Array()
	var cpu_ms := PackedFloat64Array()
	var peak := {"gpu_ms": null, "cpu_ms": null}
	var last := {}
	var viewport := _session.get_viewport()
	var status := RenderCounters.NOT_RUN
	var previous := Time.get_ticks_usec()
	for i in measure_frames:
		await get_tree().process_frame
		if _stale(token):
			return {}
		if _disturbed():
			abort("input_disturbance")
			return {}
		var now := Time.get_ticks_usec()
		frame_ms.append(float(now - previous) / 1000.0)
		previous = now
		last = RenderCounters.snapshot(viewport)
		var valid: bool = last.gpu_status == RenderCounters.AVAILABLE
		if valid:
			gpu_ms.append(float(last.gpu_ms))
			cpu_ms.append(float(last.cpu_ms))
		if valid or status != RenderCounters.AVAILABLE:
			status = last.gpu_status
		_track_peak(peak, last, valid)
	return {"summary": BenchPlan.summarize(frame_ms, gpu_ms, cpu_ms, status, status), "peak": peak, "last": last}


static func _track_peak(peak: Dictionary, sample: Dictionary, timing_valid: bool) -> void:
	for key in PEAK_KEYS:
		if key in TIMING_KEYS and not timing_valid:
			continue
		peak[key] = maxf(float(peak.get(key, 0.0)) if peak.get(key) != null else 0.0, float(sample[key]))


# --- Exit ---------------------------------------------------------------------------------

## Single exit for every path. Restores, releases the claim, writes the (possibly partial)
## report, emits the signal and frees the runner. Safe to call repeatedly.
func _end(status: String, reason: String) -> void:
	if not _running:
		return
	_running = false
	_run_token += 1
	var valid := is_instance_valid(_session)
	var restored := false
	if valid:
		if _session.world_replaced.is_connected(_on_world_replaced):
			_session.world_replaced.disconnect(_on_world_replaced)
		restored = _restore(reason)
		_session.release_bench(self)
	report = _build_report(status, reason, restored)
	var written := BenchReport.write(report, output_dir)
	report_path = written[0]
	write_error = written[1]
	if valid:
		_announce(status, reason)
	if status == "COMPLETED":
		finished.emit(report)
	else:
		aborted.emit(reason, report)
	if OS.get_cmdline_user_args().has("--bench-quit") and is_inside_tree():
		get_tree().quit(0 if status == "COMPLETED" else 1)
	if _busy:
		_free_pending = true
	else:
		queue_free()


func _announce(status: String, reason: String) -> void:
	if write_error != "":
		_session.post_message(write_error, true)
		return
	var text := "Render bench saved: " + report_path if status == "COMPLETED" \
			else "Render bench aborted (%s); partial report: %s" % [reason, report_path]
	_session.post_message(text, status != "COMPLETED")
	print("RENDER_BENCH ", status.to_lower(), " ", ProjectSettings.globalize_path(report_path))


func _build_report(status: String, reason: String, restored: bool) -> Dictionary:
	var viewport := _session.get_viewport() if is_instance_valid(_session) else null
	var after := BenchReport.authored_state(_session) if is_instance_valid(_session) else _before
	return {"status": status, "abort_reason": null if status == "COMPLETED" else reason,
		"evidence": BenchReport.evidence(),
		"fingerprints": BenchReport.fingerprints(_session.catalog) if is_instance_valid(_session) else {},
		"os": OS.get_name() + " " + OS.get_version(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"viewport_size": [viewport.size.x, viewport.size.y] if viewport != null else [],
		"correctness": BenchReport.correctness(_before, after, restored),
		"warmup_frames": warmup_frames, "measure_frames": measure_frames, "seed": rng_seed,
		"counts": Array(counts), "profiles": profiles, "cameras": cameras,
		"steps": _results, "started_unix": _started,
		"duration_s": Time.get_unix_time_from_system() - _started}.merged(
			_runner.report_fields() if _runner != null else {})


# --- Hooks for BenchRunner (scenario/sustained mode) ---------------------------------------

func _prepare_runner(session: EditorSession) -> void:
	if scenarios.is_empty() and sustained_minutes <= 0.0:
		return
	_runner = BenchRunner.new(self, session)
	_runner.scenarios = scenarios
	_runner.profiles = scenario_profiles if not scenario_profiles.is_empty() else BenchScenarios.BENCH_PROFILES.duplicate()
	_runner.kinds = scenario_kinds
	_runner.seconds = measure_seconds
	_runner.warmup_seconds = warmup_seconds
	_runner.sustained_minutes = sustained_minutes
	_runner.screenshots = screenshots
	_runner.seed_value = rng_seed
	_runner.overrides = world_overrides
	_runner.results = _results
	_runner.prepare()


func stale(token: int) -> bool:
	return _stale(token)


func disturbed() -> bool:
	return _disturbed()


## The runner replaced the session's terrain/presenter/layers with a bench world: restore rebuilds them.
func mark_presented() -> void:
	_presented_bench = true
