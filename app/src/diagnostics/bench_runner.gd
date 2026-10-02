class_name BenchRunner
extends RefCounted
## Scenario and sustained passes of RenderBench (spec §19.3, §20, §21.4). The host RenderBench owns the claim,
## capture/restore, token guard and report; this class builds the bench worlds, presents them with the bench
## catalog, applies real profiles through the profile controller, drives camera paths and edit workloads
## per frame and measures with streaming statistics. Idle pacing is never enabled and nothing here touches
## the user's document, history or storage.

const PREVIEW_WINDOW_CAP_S := 240.0
const MAX_SUSTAINED_MINUTES := 120
const MINUTE_S := 60.0

var scenarios: Array[String] = []
var profiles: Array[String] = BenchScenarios.BENCH_PROFILES.duplicate()
var kinds: Array[String] = []
var seconds := 10.0
var warmup_seconds := 2.0
var sustained_minutes := 0.0
var seed_value := 1234
var screenshots := false
var overrides: Dictionary = {}
var results: Array[Dictionary] = []
var populations: Dictionary = {}
var sustained: Dictionary = {}

var _host: RenderBench
var _session: EditorSession
var _attach: BenchAttach
var _world: Dictionary = {}
var _world_name := ""
var _world_dirty := false
var _camera_ctx: Dictionary = {}
var _saved_profile := ""
var _preview_was_active := false
var _workload: BenchWorkloads


func _init(host: RenderBench, session: EditorSession) -> void:
	_host = host
	_session = session
	_attach = BenchAttach.new(session)


func attach_state() -> BenchAttach:
	return _attach


## Before the host captures the session: remembers the user's profile and stops a running Texture Preview (the
## bench measures without it; it is never turned back on automatically).
func prepare() -> void:
	_saved_profile = _session.render_profiles.active_name()
	var render := _session.render_state()
	_preview_was_active = render.texture_preview.state() not in [TexturePreviewController.OFF,
			TexturePreviewController.RELEASING]
	render.disable_texture_preview("bench_start")


## Restores what the passes changed outside the host's own capture: workload leftovers, the preview binding,
## the editor catalog/registry attachment and the user's profile.
func restore() -> void:
	if _workload != null:
		_workload.abandon()
		_workload = null
	var render := _session.render_state()
	render.disable_texture_preview("bench_end")
	_attach.restore()
	render.texture_preview.bind(_session.terrain, _session.document)
	if _session.render_profiles.active_name() != _saved_profile:
		render.profiles.request_profile(_saved_profile, false)
	_world = {}


func report_fields() -> Dictionary:
	var out := {"evidence_class": BenchReport.platform_class(), "scenarios": scenarios, "bench_profiles": profiles,
		"kinds": kinds, "measure_seconds": seconds, "warmup_seconds": warmup_seconds,
		"populations": populations, "not_run": BenchScenarios.NOT_RUN,
		"preview_stopped_for_bench": _preview_was_active, "idle_pacing": "never_enabled"}
	if not sustained.is_empty():
		out["sustained"] = sustained
	return out


func run(token: int) -> void:
	if sustained_minutes > 0.0:
		await _run_sustained(token)
		return
	var runnable: Array[String] = []
	for name in scenarios:
		if BenchScenarios.is_scenario(name):
			runnable.append(name)
	for step in BenchScenarios.plan_steps(runnable, profiles, kinds):
		var result := await _run_step(step, token)
		if _host.stale(token):
			return
		if not result.is_empty():
			results.append(result)


# --- World and profile ---------------------------------------------------------------------

## Builds and presents the scenario's world unless it is already presented and unedited. False after an abort.
func _ensure_world(name: String) -> bool:
	if name == _world_name and not _world_dirty and not _world.is_empty():
		return true
	_world = BenchWorlds.build(name, _session.catalog, _bench_catalog(), seed_value, overrides)
	if _world.doc == null:
		_session.post_message("Render bench cannot build '%s': %s" % [name, str(_world.error)], true)
		_host.abort("bench_world_failed")
		return false
	var t0 := Time.get_ticks_usec()
	var error := _attach.attach(str(_world.catalog_kind))
	var doc: WorldDocument = _world.doc
	if error == "":
		error = _session.terrain.replace_document(doc)
	if error != "":
		_session.post_message("Render bench cannot present '%s': %s" % [name, error], true)
		_host.abort("bench_world_failed")
		return false
	_world["authored_sha256"] = CanonicalEncoder.authored_hash(doc)
	var attached_catalog := _attach.bench_catalog if _world.catalog_kind == "bench" else _session.catalog
	_world.population["authored_sha256"] = _world.authored_sha256
	_world.population["bench_catalog_sha256"] = attached_catalog.sha256
	_session.presenter.rebuild(doc)
	_session.layers.rebuild(doc)
	_session.rig.height_sampler = doc.sample_height
	_session.render_state().present_world_rect(doc.layout.world_rect())
	_host.mark_presented()
	_world_name = name
	_world_dirty = false
	_camera_ctx = _make_camera_ctx(doc)
	var population: Dictionary = (_world.population as Dictionary).duplicate()
	population["build_ms"] = _world.build_ms
	population["present_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	populations[name] = population
	RenderCounters.reset_warmup(_session.get_viewport())
	return true


func _bench_catalog() -> AssetCatalog:
	_attach.load_bench()
	return _attach.bench_catalog


func _make_camera_ctx(doc: WorldDocument) -> Dictionary:
	var size := _session.get_viewport().get_visible_rect().size
	var aspect := size.x / size.y if size.y > 0.0 else 1.0
	var fit := _session.rig.controller.fit_distance(deg_to_rad(BenchCameraPaths.YAW_DEG),
			deg_to_rad(BenchCameraPaths.OVERVIEW_PITCH_DEG), aspect)
	var rect := doc.layout.world_rect()
	var heights := doc.height_range()
	var bounds := AABB(Vector3(rect.position.x, heights.x, rect.position.y),
			Vector3(rect.size.x, maxf(heights.y - heights.x, 0.001), rect.size.y))
	var pivot := Vector3(0.0, doc.sample_height(0.0, 0.0), 0.0)
	var threshold := float(_session.render_state().config.section("overview_view").enter_extent_ratio)
	var centered := BenchCameraPaths.threshold_distance(RenderCameraSnapshot.capture(_session.rig.get_camera()),
			bounds, pivot, fit, threshold)
	return {"anchors": _world.anchors, "height": doc.sample_height, "fit_distance": fit,
		"threshold_distance": centered, "threshold_extent_ratio": threshold}


## Applies the step's profile. Real profiles go through the profile controller (allowed for the bench owner);
## legacy ablation names only change render settings. Returns the profile's target fps.
func _apply_profile(profile: String) -> float:
	_host.apply_comparison({})
	if BenchPlan.COMPARISONS.has(profile):
		var target := _apply_profile("performance")
		var error := _host.apply_comparison(BenchPlan.comparison_flags(profile))
		if error != "":
			_session.post_message(error, true)
			_host.abort("comparison_unsupported")
		return target
	if not BenchScenarios.is_real_profile(profile):
		_host._apply_settings(BenchPlan.profile_settings(profile))
		return BenchPlan.DEFAULT_TARGET_FPS
	_host.apply_mesh(0)
	var render := _session.render_state()
	render.profiles.request_profile(profile, false)
	var p := render.profiles.active_profile()
	_session.get_viewport().scaling_3d_scale = float(p.scale_3d)
	_session.sun.shadow_enabled = false
	_session.terrain.set_render_probe(true, false)
	Engine.max_fps = 0
	return float(p.target_fps)


# --- One step ------------------------------------------------------------------------------

func _run_step(step: Dictionary, token: int) -> Dictionary:
	if not _ensure_world(str(step.scenario)):
		return {}
	var t0 := Time.get_ticks_usec()
	var target_fps := _apply_profile(str(step.profile))
	if _host.stale(token):
		return {}
	RenderCounters.reset_warmup(_session.get_viewport())
	var kind := str(step.camera)
	var focus_pose := BenchCameraPaths.pose("focus", _camera_ctx, 0.0, seconds)
	_session.rig.reset_to(focus_pose if kind in BenchScenarios.WORKLOAD_KINDS else BenchCameraPaths.pose(
			kind, _camera_ctx, 0.0, seconds))
	var prepare_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var settle := await _host._settle(token)
	if _host.stale(token):
		return {}
	var telemetry_start := _telemetry()
	var cache_start := _session.render_cache().stats()
	if not await _warmup(kind, token):
		return {}
	var ready := _host.pending_state()
	var stats := BenchStreamStats.new(target_fps)
	var run := await _measure(kind, seconds, stats, token, -1)
	if run.is_empty():
		return {}
	var out := step.duplicate()
	out.merge({"target_fps": target_fps, "target_budget_ms": 1000.0 / target_fps, "prepare_ms": prepare_ms,
		"first_frame_ms": settle.first_frame_ms, "settle_ms": settle.settle_ms, "settled": settle.settled,
		"pending_at_settle": settle.pending_at_settle, "pending_before_measure": ready,
		"measurement_status": BenchPlan.measurement_status(kind, ready),
		"comparison": _session.render_state().comparison_flags(), "population": _population(), "render_stats": _session.presenter.render_stats(),
		"cache_start": cache_start, "cache": _session.render_cache().stats(), "terrain_mesh": _session.terrain.mesh_config(),
		"telemetry": {"start": telemetry_start, "end": _telemetry()},
		"summary": stats.summary(), "counters_peak": run.peak, "counters_last": run.last,
		"nodes": _session.presenter.node_count(), "view_state": _session.render_state().view.status(),
		"terrain_material": _session.terrain.material_mode(), "scatter_stats": _session.layers.scatter.stats(),
		"render": _session.render_summary()})
	var overview := _session.render_state().overview
	if overview != null:
		out["overview_stats"] = overview.stats()
	if screenshots:
		out["screenshot"] = await _screenshot(step)
	if kind in BenchScenarios.CAMERA_KINDS:
		out["camera_poses"] = BenchCameraPaths.summary(kind, _camera_ctx, seconds)
	else:
		out["workload_result"] = run.workload
		_world_dirty = kind != "preview_cycles"
	return out


## Visual check (spec §21.3) after the timed window, never inside it. "" when there is no rendering device.
func _screenshot(step: Dictionary) -> String:
	if RenderingServer.get_rendering_device() == null:
		return ""
	await RenderingServer.frame_post_draw
	var dir := _host.output_dir.path_join("bench-shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("%s-%s-%s.png" % [step.scenario, step.profile, step.camera])
	var image := _session.get_viewport().get_texture().get_image()
	return ProjectSettings.globalize_path(path) if image != null and image.save_png(path) == OK else ""


func _population() -> Dictionary:
	var out: Dictionary = (_world.population as Dictionary).duplicate()
	out["presented"] = _session.presenter.authored_object_count()
	out["represented"] = _session.presenter.represented_object_count()
	return out


func _telemetry() -> Dictionary:
	var sample := _session.render_state().safety.last_sample()
	return {"thermal": sample.get("thermal", "unavailable"), "footprint_mib": sample.get("footprint_mib"),
		"safety_state": _session.render_state().safety.state()}


## Warm-up frames use the same camera path or workload; preview cycles are not repeated for a warm-up.
func _warmup(kind: String, token: int) -> bool:
	if kind == "preview_cycles":
		return true
	var run := await _measure(kind, warmup_seconds, BenchStreamStats.new(), token, -1)
	return not run.is_empty()


## Runs frames for `duration` s (a workload that ends by itself ends the window, capped), applying the camera
## path or the edit workload every frame. Returns {} on abort, else {peak, last, workload}.
## `deadline_usec` >= 0 ends the window early (sustained mode).
func _measure(kind: String, duration: float, stats: BenchStreamStats, token: int, deadline_usec: int,
		minute_hook: Callable = Callable()) -> Dictionary:
	var initial_camera_pose := _start_segment_camera(kind, duration)
	var error := _begin_workload(kind)
	if error != "":
		return {"peak": {}, "last": {}, "workload": {"error": error}}
	var limit := PREVIEW_WINDOW_CAP_S if kind == "preview_cycles" else duration
	var viewport := _session.get_viewport()
	var peak := {"gpu_ms": null, "cpu_ms": null}
	var last := {}
	var start := Time.get_ticks_usec()
	var previous := start
	var t := 0.0
	var dynamic := kind in BenchScenarios.DYNAMIC_CAMERA_KINDS
	var self_ending := _workload != null and not _workload.is_timed()
	while t < limit:
		await _host.get_tree().process_frame
		if _host.stale(token):
			return {}
		if _host.disturbed():
			_host.abort("input_disturbance")
			return {}
		var now := Time.get_ticks_usec()
		t = float(now - start) / 1e6
		if dynamic:
			_session.rig.reset_to(BenchCameraPaths.pose(kind, _camera_ctx, t, duration))
		if _workload != null:
			_workload.frame(t)
		stats.add_frame(float(now - previous) / 1000.0)
		previous = now
		last = RenderCounters.snapshot(viewport)
		stats.add_snapshot(last)
		RenderBench._track_peak(peak, last)
		if minute_hook.is_valid():
			minute_hook.call(t, last)
		if (self_ending and _workload.is_done()) or (deadline_usec >= 0 and now >= deadline_usec):
			break
	var result := {"peak": peak, "last": last, "workload": {}, "initial_camera_pose": initial_camera_pose}
	if _workload != null:
		result.workload = _workload.finish(t)
		_workload = null
	return result


func _start_segment_camera(kind: String, duration: float) -> Dictionary:
	var path := "focus" if kind in BenchScenarios.WORKLOAD_KINDS else kind
	_session.rig.reset_to(BenchCameraPaths.pose(path, _camera_ctx, 0.0, duration))
	var actual := _session.rig.controller.get_pose()
	var pivot: Vector3 = actual.pivot
	return {"pivot": [pivot.x, pivot.y, pivot.z], "yaw_deg": rad_to_deg(float(actual.yaw)),
		"pitch_deg": rad_to_deg(float(actual.pitch)), "distance_m": actual.distance}


func _begin_workload(kind: String) -> String:
	_workload = null
	if kind not in BenchScenarios.WORKLOAD_KINDS:
		return ""
	_workload = BenchWorkloads.new(_session, _world.doc, _world.anchors.focus)
	_workload.preview_cycles = int(overrides.get("preview_cycles", BenchWorkloads.PREVIEW_CYCLES))
	return _workload.begin(kind)


# --- Sustained -----------------------------------------------------------------------------

## mixed_world_10k x performance, looping BenchScenarios.SUSTAINED_SEQUENCE for `sustained_minutes`. Per-minute
## aggregates only (at most MAX_SUSTAINED_MINUTES); the report is written once by the host.
func _run_sustained(token: int) -> void:
	var minutes := clampf(sustained_minutes, 0.0, float(MAX_SUSTAINED_MINUTES))
	var total_s := minutes * MINUTE_S
	if not _ensure_world(BenchScenarios.SUSTAINED_SCENARIO):
		return
	var target_fps := _apply_profile(BenchScenarios.SUSTAINED_PROFILE)
	sustained = {"scenario": BenchScenarios.SUSTAINED_SCENARIO, "profile": BenchScenarios.SUSTAINED_PROFILE,
		"minutes_requested": minutes, "segment_seconds": seconds, "target_fps": target_fps,
		"sequence": BenchScenarios.SUSTAINED_SEQUENCE, "minutes": [], "segments": {}, "elapsed_s": 0.0,
		"completed": false, "idle_pacing": "never_enabled"}
	_start_segment_camera("overview", seconds)
	var settle := await _host._settle(token)
	if _host.stale(token) or settle.is_empty():
		return
	if not await _warmup("overview", token):
		return
	var start := Time.get_ticks_usec()
	var deadline := start + int(total_s * 1e6)
	var minute := {"stats": BenchStreamStats.new(target_fps), "index": 0,
		"segment": "", "start": start}
	var hook := _minute_hook.bind(minute)
	while Time.get_ticks_usec() < deadline:
		for kind in BenchScenarios.SUSTAINED_SEQUENCE:
			if Time.get_ticks_usec() >= deadline:
				break
			minute.segment = kind
			var run := await _measure(kind, seconds, minute.stats, token, deadline, hook)
			if run.is_empty():
				_flush_minute(minute)
				sustained["elapsed_s"] = float(Time.get_ticks_usec() - start) / 1e6
				return
			_note_segment(kind, run)
	_flush_minute(minute)
	sustained["elapsed_s"] = float(Time.get_ticks_usec() - start) / 1e6
	sustained["completed"] = true


func _note_segment(kind: String, run: Dictionary) -> void:
	var seg: Dictionary = sustained.segments.get(kind, {"runs": 0})
	if not seg.has("initial_camera_pose"):
		seg["initial_camera_pose"] = run.initial_camera_pose
	seg["runs"] = int(seg.runs) + 1
	if kind == "preview_cycles":
		seg["cycles_done"] = int(seg.get("cycles_done", 0)) + int((run.workload as Dictionary).get("cycles_done", 0))
	sustained.segments[kind] = seg


func _minute_hook(_t: float, _snapshot: Dictionary, minute: Dictionary) -> void:
	var elapsed := float(Time.get_ticks_usec() - int(minute.start)) / 1e6
	if elapsed >= float(int(minute.index) + 1) * MINUTE_S:
		_flush_minute(minute)


## Appends the aggregate of the finished minute (bounded) and starts a fresh histogram.
func _flush_minute(minute: Dictionary) -> void:
	var stats: BenchStreamStats = minute.stats
	if stats.frames == 0:
		minute.index = int(minute.index) + 1
		return
	var list: Array = sustained.minutes
	if list.size() < MAX_SUSTAINED_MINUTES:
		var s := stats.summary()
		var tel := _telemetry()
		list.append({"minute": int(minute.index) + 1, "frames": s.frames, "frame_p50_ms": s.frame_p50_ms,
			"frame_p95_ms": s.frame_p95_ms, "frame_p99_ms": s.frame_p99_ms, "frame_max_ms": s.frame_max_ms,
			"hitches_over_50_ms": s.hitches_over_50_ms, "over_100_ms": s.over_100_ms, "missed_target": s.missed_target,
			"gpu_status": s.gpu_status, "gpu_p95_ms": s.gpu_p95_ms,
			"cpu_status": s.cpu_status, "cpu_p95_ms": s.cpu_p95_ms, "cpu_samples": s.cpu_samples, "gpu_samples": s.gpu_samples, "thermal": tel.thermal,
			"footprint_mib": tel.footprint_mib, "safety_state": tel.safety_state,
			"cache_resident_bytes": int(_session.render_cache().stats().resident_bytes),
			"nodes": _session.presenter.node_count(), "last_segment": minute.segment})
	minute.index = int(minute.index) + 1
	stats.reset()
