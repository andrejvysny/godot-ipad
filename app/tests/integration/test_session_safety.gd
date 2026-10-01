extends TestCase
## Resource-safety state (rendering spec §18.1, §18.3; MEMORY-04): injected telemetry and cache pressure stop
## optional work without changing the profile, the document or the history; deactivation cancels queued loads.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const MIB := 1048576

var _filter: TerrainTests.KnownWarningFilter
var _sessions: Array = []
var _now := [100000]


func before_each() -> void:
	allow_logged_errors()
	_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(_filter)


func after_each() -> void:
	for s: Variant in _sessions:
		if is_instance_valid(s):
			if s.get_parent() != null:
				tree.root.remove_child(s)
			s.free()
	_sessions.clear()
	assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))
	OS.remove_logger(_filter)


## A session whose safety clock is under test control; the sampling interval always passes between ticks.
func _start() -> EditorSession:
	var s := EditorSession.new()
	s.storage_root = scratch_dir() + "/worlds"
	s.start_fixture = "flat"
	s.provider_override = InputTests.FakeProvider.new()
	s.build_ui = false
	_sessions.append(s)
	tree.root.add_child(s)
	await tree.process_frame
	# The first real-clock sample happened during that frame; the test clock must start after it.
	_now[0] = maxi(_now[0], Time.get_ticks_msec()) + 100000
	s.render_state().safety.clock_msec = func() -> int: return _now[0]
	return s


func _tick(s: EditorSession, advance_msec: int = SessionSafety.SAMPLE_MSEC) -> void:
	_now[0] += advance_msec
	s.render_state().safety.tick()


func _preview_state(s: EditorSession) -> String:
	return str(s.texture_preview_status().state)


func _wait_preview(s: EditorSession, state: String) -> void:
	for i in 600:
		if _preview_state(s) == state:
			return
		await tree.process_frame
	fail("preview never reached %s (is %s)" % [state, _preview_state(s)])


## Distinct files: the cache counts entries per resolved path.
func _queue(s: EditorSession, key: String, file: String, priority: int) -> void:
	var path := "res://assets/bench/render_assets/slab_a/%s.tres" % file
	assert_eq(s.render_cache().request(key, path, "mesh", priority, 1024, "safety-test").status, "queued")


func _unchanged(s: EditorSession) -> Dictionary:
	return {"profile": s.render_profiles.active_name(), "scale": s.get_viewport().scaling_3d_scale,
		"hash": s.authored_hash(), "revision": s.document.document_revision, "history": s.history.size(),
		"max_fps": Engine.max_fps}


func test_memory_warning_restricts_without_changing_profile_or_document() -> void:
	var s := await _start()
	assert_eq(s.status().safety_state, "normal")
	s.rig.focus_point(Vector3(5.0, 0.0, 5.0))
	assert_eq(s.toggle_texture_preview(), "")
	assert_ne(_preview_state(s), TexturePreviewController.OFF)
	_queue(s, "spec-a", "mesh_far", 3)
	_queue(s, "near-b", "mesh_near", 1)
	var before := _unchanged(s)
	var posted: Array[String] = []
	s.message_posted.connect(func(text: String, _e: bool) -> void: posted.append(text))
	var safety := s.render_state().safety
	safety.telemetry.inject_memory_warning()
	_tick(s)
	var st := s.status()
	assert_eq(st.safety_state, "restricted")
	assert_eq(st.safety_reason, "memory warning")
	assert_eq(_preview_state(s), TexturePreviewController.RELEASING, "preview suspended")
	assert_eq(s.texture_preview_status().reason, "suspended")
	assert_eq(s.texture_preview_status().cause, "memory warning")
	assert_eq(s.render_cache().state("spec-a"), "UNLOADED", "speculative request cancelled")
	assert_eq(s.render_cache().state("near-b"), "QUEUED", "near request kept")
	assert_eq(posted.filter(func(t: String) -> bool: return t.begins_with("Resource safety:")).size(), 1)
	assert_true(posted.has("Resource safety: memory warning — preview stopped, caches trimmed"))
	safety.telemetry.inject_memory_warning()
	_tick(s)
	assert_eq(posted.filter(func(t: String) -> bool: return t.begins_with("Resource safety:")).size(), 1,
			"the message is posted once per entry")
	assert_eq(_unchanged(s), before, "profile, scale, authored state and history are untouched")
	await _wait_preview(s, TexturePreviewController.OFF)
	assert_eq(s.toggle_texture_preview(), SessionSafety.PREVIEW_REFUSED, "enabling is refused while restricted")
	assert_eq(_preview_state(s), TexturePreviewController.OFF)
	_tick(s, 59000)
	assert_eq(s.status().safety_state, "restricted", "still inside the window")
	_tick(s, 2000)
	assert_eq(s.status().safety_state, "normal", "recovered after 60 s without a warning")
	assert_eq(_preview_state(s), TexturePreviewController.OFF, "the preview is not re-enabled automatically")
	assert_eq(_unchanged(s), before)


func test_thermal_critical_restricts_until_it_clears() -> void:
	var s := await _start()
	var safety := s.render_state().safety
	safety.telemetry.inject_thermal(3)
	_tick(s)
	assert_eq(s.status().safety_state, "restricted")
	assert_eq(s.status().safety_reason, "thermal critical")
	assert_eq(s.status().thermal, "critical")
	_tick(s, 120000)
	assert_eq(s.status().safety_state, "restricted", "critical keeps re-arming the window")
	safety.telemetry.inject_thermal(0)
	_tick(s)
	assert_eq(s.status().safety_state, "restricted")
	_tick(s, 61000)
	assert_eq(s.status().safety_state, "normal")
	assert_eq(s.status().thermal, "nominal")
	assert_eq(s.render_profiles.active_name(), "performance")


func test_thermal_serious_is_a_warning_only() -> void:
	var s := await _start()
	s.rig.focus_point(Vector3(5.0, 0.0, 5.0))
	assert_eq(s.toggle_texture_preview(), "")
	_queue(s, "spec-a", "mesh_far", 3)
	var before := _unchanged(s)
	s.render_state().safety.telemetry.inject_thermal(2)
	_tick(s)
	assert_eq(s.status().safety_state, "warning")
	assert_eq(s.status().safety_reason, "thermal serious")
	assert_eq(s.render_state().safety.interventions(), 0)
	assert_ne(_preview_state(s), TexturePreviewController.OFF, "no action on a warning")
	assert_eq(s.render_cache().state("spec-a"), "QUEUED")
	assert_eq(_unchanged(s), before)
	var indicator := PerfIndicator.new()
	var base := {"profile_label": "Performance", "fps": 60.0, "profile_pending": "", "profile_target_fps": 60}
	assert_eq(indicator.caption(base), "Performance · 60 fps")
	assert_eq(indicator.caption(base.merged({"safety_state": "warning"}, true)), "Performance · 60 fps · Safety")
	assert_eq(indicator.caption(base.merged({"safety_state": "restricted"}, true)), "Performance · 60 fps · Safety")
	indicator.free()
	s.render_state().safety.telemetry.inject_thermal(0)
	_tick(s)
	assert_eq(s.status().safety_state, "normal")


func test_critical_cache_over_budget_restricts() -> void:
	var s := await _start()
	var cache := s.render_cache()
	var ceiling := int(cache.stats().ceiling_bytes)
	var path := "res://assets/bench/render_assets/slab_a/mesh_far.tres"
	assert_eq(cache.request("big", path, "mesh", 3, ceiling - 4 * MIB, "safety-test").status, "queued")
	var rejected := cache.request("near", "res://assets/bench/render_assets/slab_a/mesh_near.tres", "mesh", 0, 8 * MIB, "safety-test")
	assert_eq(rejected.reason, "over_budget")
	assert_eq(cache.stats().critical_over_budget, 1)
	_tick(s)
	assert_eq(s.status().safety_state, "restricted")
	assert_eq(s.status().safety_reason, "cache over budget")
	assert_eq(cache.state("big"), "UNLOADED", "the speculative reservation was cancelled")


func test_status_reports_unavailable_telemetry_as_null_not_zero() -> void:
	var s := await _start()
	s.render_state().safety.telemetry = RenderPlatformTelemetry.new(true)
	_tick(s)
	var st := s.status()
	assert_true(st.has("footprint_mib") and st.footprint_mib == null, "unavailable footprint is null")
	assert_eq(st.thermal, "unavailable")
	assert_eq(st.safety_state, "normal")


func test_deactivation_cancels_queued_loads_and_resume_keeps_the_preview_off() -> void:
	var s := await _start()
	s.rig.focus_point(Vector3(5.0, 0.0, 5.0))
	assert_eq(s.toggle_texture_preview(), "")
	_queue(s, "spec-a", "mesh_far", 3)
	_queue(s, "coarse-b", "mesh_mid", 2)
	_queue(s, "ghost-c", "mesh_near", 0)
	s._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_eq([s.render_cache().state("spec-a"), s.render_cache().state("coarse-b")], ["UNLOADED", "UNLOADED"])
	assert_eq(s.render_cache().state("ghost-c"), "QUEUED", "only the priority-0 request survives")
	assert_eq(_preview_state(s), TexturePreviewController.RELEASING)
	s._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _wait_preview(s, TexturePreviewController.OFF)
	for i in 5:
		await tree.process_frame
	assert_eq(_preview_state(s), TexturePreviewController.OFF, "resume does not re-enable the preview")


func test_cache_cancel_queued_by_priority() -> void:
	var cache := RenderAssetCache.new()
	for priority in 4:
		assert_eq(cache.request("k%d" % priority, "res://assets/bench/render_assets/slab_a/mesh_%s.tres" % [
				["far", "mid", "near", "selected"][priority]], "mesh", priority, 4096, "o").status, "queued")
	assert_eq(cache.cancel_queued(2), 2)
	var st := cache.stats()
	assert_eq([st.queued, st.reserved_bytes], [2, 8192])
	assert_eq(cache.cancel_queued(0), 2)
	assert_eq([cache.stats().queued, cache.stats().reserved_bytes], [0, 0])
