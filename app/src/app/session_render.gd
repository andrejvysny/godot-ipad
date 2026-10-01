class_name SessionRender
extends RefCounted
## Render-side session state (spec §4.1, §8.2, §11, §12.1, §15.3, §15.4): the manual profile
## controller, the presentation-only vegetation toggle, the shared render registry/cache, the
## ActiveEditArea wiring, the Texture Preview and the cached slow part of EditorSession.status().
## Never touches the document.

const MIN_SLOW_STATUS_MSEC := 100
const BLOCKED := "blocked"
const ACTIVE_MARGIN_M := 2.0
const RING_COLOR := Color(0.55, 0.85, 1.0, 0.9)

var config: RenderConfig
var profiles: RenderProfileController
var vegetation_hidden := false
var cache: RenderAssetCache
var active_edit: ActiveEditArea
var texture_preview: TexturePreviewController

var _registry: RenderAssetRegistry
var _tools: ToolController
var _op_radius: float = 0.0
var _budget_ms: float = 1.0
var _preview_state := TexturePreviewController.OFF
var _preview_ring: BrushRing
var _preview_ring_key := ""
var _session: EditorSession
var _slow_status: Dictionary = {}
var _slow_status_msec := -1


func _init(session: EditorSession) -> void:
	_session = session
	config = RenderConfig.load_from()
	profiles = RenderProfileController.new(config)
	profiles.set_apply_hook(_apply_profile)
	profiles.profile_applied.connect(_on_profile_applied)
	var budgets := config.section("budgets")
	_budget_ms = float(budgets.main_thread_soft_ms)
	if RenderingServer.get_rendering_device() == null:
		budgets.inflight_loads = 1  # the dummy renderer's texture storage is not thread-safe
	cache = RenderAssetCache.new(budgets)
	active_edit = ActiveEditArea.new(float(config.section("cells").objects_m), int(config.section("stability").settle_ms))
	texture_preview = TexturePreviewController.new(cache, config.section("texture_preview"))
	session.world_replaced.connect(_on_world_replaced)


## The validated registry of the session's catalog; created on first use (the catalog loads after this object).
func registry() -> RenderAssetRegistry:
	if _registry == null:
		_registry = RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, _session.catalog)
	return _registry


## Once per frame after the tools: polls the shared cache, then applies the presenter's render work.
func service_frame(budget_ms: float = -1.0) -> void:
	var budget := _budget_ms if budget_ms < 0.0 else budget_ms
	# A tap or no-op finish ends an operation without a signal.
	if profiles.pending_name() != "" and not _session.tools.has_active_operation():
		profiles.operation_ended()
	cache.poll(budget)
	active_edit.tick(Time.get_ticks_msec())
	if active_edit.is_active() and _tools != null:
		var hit := _tools.last_hit()
		if hit != null and hit.ok:
			active_edit.update(_tools.active_operation_id(), hit.position, _op_radius)
	texture_preview.service(budget)
	_sync_preview()
	_session.presenter.service_frame(budget)


func bind_tools(tools: ToolController) -> void:
	_tools = tools
	_session.presenter.placeholders_reported.connect(_session.post_message)
	tools.operation_started.connect(_on_operation_started)
	tools.operation_finished.connect(func(_change: WorldChange) -> void: _operation_ended("finished"))
	tools.operation_cancelled.connect(func(reason: String) -> void: _operation_ended(reason))


func _on_operation_started(_tool: String) -> void:
	var center := Vector3.ZERO
	var hit := _tools.last_hit()
	if hit != null and hit.ok:
		center = hit.position
	_op_radius = _active_radius() + ACTIVE_MARGIN_M
	active_edit.begin(_tools.active_operation_id(), center, _op_radius)


func _operation_ended(outcome: String) -> void:
	profiles.operation_ended()
	active_edit.end(active_edit.operation_id(), outcome)


## Brush radius of the active mode, else the selected object's bounds radius, else the profile's area radius.
func _active_radius() -> float:
	var values := _tools.settings(_tools.mode())
	if values.has("radius"):
		return float(values.radius)
	var bounds := _session.presenter.world_bounds(_tools.selected_id())
	if bounds.size != Vector3.ZERO:
		return bounds.size.length() * 0.5
	return float(profiles.active_profile().get("active_area_radius_m", 20.0))


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
	_session.presenter.set_default_role(str(p.near_min_role))
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
		"vegetation_hidden": vegetation_hidden, "texture_preview": texture_preview.status(), "fps": 1000.0 / frame_p50_ms if frame_p50_ms > 0.0 else 0.0}


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


# --- Texture Preview (spec §11) ----------------------------------------------------------

## Turns the preview on at the selected object's anchor or the camera pivot, or off. Returns "" or the
## reason it did not turn on.
func toggle_texture_preview() -> String:
	var state := texture_preview.state()
	if state == TexturePreviewController.RELEASING:
		return _refuse_preview("Texture Preview is still releasing.")
	if state != TexturePreviewController.OFF and state != TexturePreviewController.ERROR:
		texture_preview.disable("user")
		_sync_preview()
		return ""
	if _session.bench_active():
		return _refuse_preview(EditorSession.BENCH_MESSAGE)
	var center := _preview_center()
	if not center.is_finite():
		return _refuse_preview(TexturePreviewController.NO_AREA)
	texture_preview.bind(_session.terrain, _session.document)
	var result := texture_preview.enable_at(center)
	_sync_preview()
	return "" if bool(result.ok) else str(result.message)


func _refuse_preview(message: String) -> String:
	_session.post_message(message, true)
	return message


## App deactivation (spec §18.3): stop the bench and optional preview work before the save path runs.
func on_app_deactivated() -> void:
	_session.abort_render_bench("app_deactivated")
	disable_texture_preview("app_deactivated")


func disable_texture_preview(reason: String) -> void:
	texture_preview.disable(reason)
	_sync_preview()


func _on_world_replaced() -> void:
	texture_preview.on_world_replaced()
	texture_preview.bind(_session.terrain, _session.document)
	_sync_preview()


## Selected object's anchor, else the camera pivot when it rests on terrain; NAN vector otherwise.
func _preview_center() -> Vector3:
	var id := _session.tools.selected_id()
	if id != "" and _session.presenter.has_object(id):
		return _session.presenter.anchor_position(id)
	var pivot := _session.rig.controller.pivot
	var h := _session.document.sample_height(pivot.x, pivot.z)
	return Vector3(NAN, NAN, NAN) if is_nan(h) else Vector3(pivot.x, h, pivot.z)


func _sync_preview() -> void:
	var st := texture_preview.status()
	var state := str(st.state)
	_sync_ring(st)
	if state == _preview_state:
		return
	_preview_state = state
	match state:
		TexturePreviewController.ACTIVE:
			_session.post_message("Texture Preview on")
		TexturePreviewController.LIMITED:
			_session.post_message("Texture Preview limited: %d textures unavailable" % (st.missing as Array).size())
		TexturePreviewController.ERROR:
			_session.post_message("Texture Preview error: " + str(st.reason), true)
		TexturePreviewController.OFF:
			_session.post_message("Texture Preview off")
	_session.status_changed.emit()


## Thin terrain-draped outline of the captured area while the preview is not off; redrawn when the
## terrain under it changes.
func _sync_ring(st: Dictionary) -> void:
	if str(st.state) == TexturePreviewController.OFF:
		if _preview_ring != null:
			_preview_ring.hide_ring()
		_preview_ring_key = ""
		return
	var key := "%d|%d" % [int(st.generation), _session.document.document_revision]
	if key == _preview_ring_key:
		return
	_preview_ring_key = key
	if _preview_ring == null:
		_preview_ring = BrushRing.new()
		_session.add_child(_preview_ring)
	_preview_ring.show_at(_session.document, st.center, float(st.radius), RING_COLOR)
