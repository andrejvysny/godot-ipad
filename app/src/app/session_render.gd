class_name SessionRender
extends RefCounted
## Render-side session state (spec §4.1, §15.3, §15.4): the manual profile controller, the
## presentation-only vegetation toggle and the cached slow part of EditorSession.status().
## Never touches the document.

const MIN_SLOW_STATUS_MSEC := 100
const BLOCKED := "blocked"

var config: RenderConfig
var profiles: RenderProfileController
var vegetation_hidden := false

var _session: EditorSession
var _slow_status: Dictionary = {}
var _slow_status_msec := -1


func _init(session: EditorSession) -> void:
	_session = session
	config = RenderConfig.load_from()
	profiles = RenderProfileController.new(config)
	profiles.set_apply_hook(_apply_profile)
	profiles.profile_applied.connect(_on_profile_applied)


## Applies or defers (during an operation) the profile; never automatic. Returns the controller result.
func request_profile(name: String) -> Dictionary:
	if _session.bench_active():
		_session.post_message(EditorSession.BENCH_MESSAGE, true)
		return {"status": BLOCKED, "name": name}
	var result := profiles.request_profile(name, _session.tools.has_active_operation())
	if str(result.status) == RenderProfileController.PENDING:
		_session.post_message("%s applies after the current edit" % profile_label(name))
	return result


func profile_label(name: String) -> String:
	return str(config.profile(name).get("label", name))


## Immediate and deferred applies alike; the silent startup apply happens before ready_for_input.
func _on_profile_applied(name: String) -> void:
	if _session.ready_for_input:
		_session.post_message("Profile: " + profile_label(name))


func _apply_profile(_name: String, p: Dictionary) -> void:
	var viewport := _session.get_viewport()
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = float(p.scale_3d)
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false
	viewport.mesh_lod_threshold = float(p.mesh_lod_threshold_px)
	# Cap only below the display rate (Detailed 30 fps); 0 leaves pacing to vsync.
	Engine.max_fps = int(p.target_fps) if int(p.target_fps) < 60 else 0
	_session.status_changed.emit()


## Presentation only: never stored in the document or history.
func set_vegetation_hidden(on: bool) -> void:
	vegetation_hidden = on
	var rule := config.vegetation_rule()
	_session.layers.set_vegetation_hidden(on, rule)
	_session.presenter.set_vegetation_hidden(on, rule)
	_session.status_changed.emit()


## Profile keys of status().
func profile_status(frame_p50_ms: float) -> Dictionary:
	var p := profiles.active_profile()
	return {"profile": profiles.active_name(), "profile_label": str(p.get("label", "")),
		"profile_pending": profiles.pending_name(), "profile_target_fps": int(p.get("target_fps", 0)),
		"vegetation_hidden": vegetation_hidden, "fps": 1000.0 / frame_p50_ms if frame_p50_ms > 0.0 else 0.0}


## Frame percentiles, render counters and stats that sort or query the RenderingServer, refreshed at
## most every 1000 / diagnostics_refresh_hz ms.
func slow_status() -> Dictionary:
	var interval := maxi(MIN_SLOW_STATUS_MSEC, roundi(1000.0 / float(config.section("ui").diagnostics_refresh_hz)))
	var now := Time.get_ticks_msec()
	if _slow_status_msec < 0 or now - _slow_status_msec >= interval:
		_slow_status_msec = now
		var s := _session
		_slow_status = {"renderer": RenderingServer.get_current_rendering_method(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"frame_p50_ms": s.frames.p50(), "frame_p95_ms": s.frames.p95(),
			"brush_p95_ms": s.frames.sample_p95("brush"), "terrain_stats": s.terrain.stats(),
			"render": RenderCounters.snapshot(s.get_viewport())}
	return _slow_status


func invalidate_slow_status() -> void:
	_slow_status_msec = -1
