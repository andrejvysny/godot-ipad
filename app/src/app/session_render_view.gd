class_name SessionRenderView
extends RefCounted
## A single view mask is published before any scheduled renderer work.

var policy := RenderViewState.new()
var tracker := LodCameraTracker.new()
var _session: EditorSession
var _render: SessionRender
var _masked := false
var _forced := ""


func _init(session: EditorSession, render: SessionRender) -> void:
	_session = session
	_render = render
	policy.configure(render.config.section("overview_view"))


func update() -> void:
	tracker.update(_session.rig.get_camera(), Time.get_ticks_msec())
	var snapshot := tracker.snapshot
	_session.presenter.set_camera_snapshot(snapshot)
	_session.layers.scatter.set_camera_snapshot(snapshot)
	if _render.overview != null:
		_render.overview.set_camera_snapshot(snapshot)
	var doc: WorldDocument = (_session.terrain as TerrainAdapter).get_document() if _session.terrain is TerrainAdapter else _session.document
	if doc == null:
		doc = _session.document
	var rect: Rect2 = doc.layout.world_rect()
	var heights: Vector2 = doc.height_range()
	var bounds := AABB(Vector3(rect.position.x, heights.x, rect.position.y),
			Vector3(rect.size.x, maxf(heights.y - heights.x, 0.001), rect.size.y))
	if not _session.tools.has_active_operation():
		policy.force_state(_forced)
	policy.update(snapshot, bounds, _session.tools.has_active_operation())
	_publish(policy.state == RenderViewState.TERRAIN_ONLY)


func _publish(suppressed: bool) -> void:
	if suppressed == _masked:
		return
	_masked = suppressed
	_session.presenter.set_view_suppressed(suppressed)
	_session.layers.scatter.set_view_suppressed(suppressed)
	if _render.overview != null:
		_render.overview.set_view_suppressed(suppressed)
	_render.texture_preview.set_view_suspended(suppressed)
	if suppressed:
		_session.post_message("Terrain overview — objects hidden")
	_session.status_changed.emit()


func force_state(value: String) -> void:
	_forced = value


func focus_before_action(hit: TerrainHit) -> bool:
	if not _masked:
		return false
	if hit == null or not hit.ok:
		_session.post_message("Aim at terrain to focus objects.")
		return true
	var radius := float(_render.profiles.active_profile().get("active_area_radius_m", 20.0))
	_render.focus_area(AABB(hit.position - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, 1.0, radius * 2.0)))
	return true


func local_focus() -> void:
	_forced = ""
	policy.clear_for_local_focus()
	_publish(false)


func capture() -> Dictionary:
	return {"state": policy.state, "forced": _forced, "local_focus": policy._local_focus}


func restore(saved: Dictionary) -> void:
	_forced = str(saved.get("forced", ""))
	policy.forced_state = _forced
	policy.state = str(saved.get("state", RenderViewState.LOCAL))
	policy._local_focus = bool(saved.get("local_focus", false))
	_publish(policy.state == RenderViewState.TERRAIN_ONLY)


func reset() -> void:
	_forced = ""
	policy = RenderViewState.new()
	policy.configure(_render.config.section("overview_view"))
	_publish(false)


func status() -> Dictionary:
	return {"view_state": policy.state, "camera_generation": tracker.generation,
		"objects_view_suppressed": _masked}
