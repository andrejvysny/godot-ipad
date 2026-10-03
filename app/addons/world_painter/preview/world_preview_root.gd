class_name WorldPreviewRoot
extends Node3D
## Isolated render root of the preview (ADR 0016 P4): draws the replica's committed document with the overlay of the
## operation in progress, through the shared presentation code (TerrainAdapter, ObjectPresenter, WorldLayers) and the
## providers of PreviewAssets. It owns its camera and, unless the host profile supplies lighting, a neutral light.
## It never writes the replica; PreviewDisplay holds the mirrored document that is drawn.

const LABEL_REFRESH_MSEC := 250
const ASSET_RETRY_MSEC := 5000

var display := PreviewDisplay.new()
var adapter: TerrainAdapter
var presenter := ObjectPresenter.new()
var layers := WorldLayers.new()
var rig: OrbitCameraRig
var assets: PreviewAssets
var replica: LiveReplica
var label := Label.new()
var presented_revision := -1
var stats := {"snapshots": 0, "commits": 0, "overlays": 0, "errors": 0, "last_error": ""}

var _seen: WorldDocument
var _commits: Array[Dictionary] = []
var _overlay_token := ""
var _label_msec := 0
var _retry_msec := 0
var _camera: Camera3D


## `use_default_light`: false when the host profile already supplies lights and environment.
func setup(catalog: AssetCatalog, p_assets: PreviewAssets, use_default_light: bool, profile_camera: Camera3D) -> void:
	assets = p_assets
	if profile_camera != null:
		_camera = profile_camera
	else:
		rig = OrbitCameraRig.new()
		add_child(rig)
		_camera = rig.get_camera()
	adapter = TerrainAdapter.new()
	adapter.set_camera(_camera)
	add_child(adapter)
	presenter.setup(catalog, assets.registry, assets.cache)
	presenter.set_camera(_camera)
	add_child(presenter)
	layers.setup(catalog, assets.registry, assets.cache, RenderConfig.load_from())
	layers.set_camera(_camera)
	add_child(layers)
	assets.asset_ready.connect(_on_asset_ready)
	if use_default_light:
		_build_light()
	_build_label()


func bind_replica(p_replica: LiveReplica) -> void:
	if replica != null and replica.commit_applied.is_connected(_on_commit):
		replica.commit_applied.disconnect(_on_commit)
	replica = p_replica
	replica.commit_applied.connect(_on_commit)
	_seen = null
	_commits.clear()


func is_complete() -> bool:
	return display.doc != null and assets.missing(display.doc).is_empty()


func _on_commit(touched: Dictionary) -> void:
	_commits.append(touched)


func _process(_delta: float) -> void:
	if replica != null and replica.document != null:
		if replica.document != _seen:
			_present_snapshot()
		else:
			_follow_replica()
	_retry_missing_assets()
	assets.cache.poll(1.0)
	presenter.service_frame()
	layers.service_frame()
	_update_label()


## A failed preparation (library offline, cache gap) is tried again while the preview shows placeholders.
func _retry_missing_assets() -> void:
	var now := Time.get_ticks_msec()
	if display.doc == null or now - _retry_msec < ASSET_RETRY_MSEC:
		return
	_retry_msec = now
	if assets.providers.pending_count() == 0 and not assets.missing(display.doc).is_empty():
		assets.attach(display.doc)


func _present_snapshot() -> void:
	_seen = replica.document
	_commits.clear()
	var first := display.doc == null or display.doc.world_id != _seen.world_id
	display.rebuild_from(_seen)
	var error := adapter.replace_document(display.doc)
	if error != "":
		_fail(error)
		return
	if rig != null:
		rig.height_sampler = display.doc.sample_height
		rig.set_world_rect(display.doc.layout.world_rect())
		if first:
			rig.reset_to(rig.controller.fixture_pose(display.doc.sample_height(0.0, 0.0)))
	assets.attach(display.doc)
	presenter.rebuild(display.doc)
	layers.rebuild(display.doc)
	_overlay_token = ""
	presented_revision = display.doc.document_revision
	stats.snapshots += 1


func _follow_replica() -> void:
	for touched in _commits:
		_apply(display.apply_commit(_seen, touched))
		stats.commits += 1
	_commits.clear()
	presented_revision = display.doc.document_revision
	var token := _token_of(replica.overlay)
	if token != _overlay_token:
		_overlay_token = token
		_apply(display.apply_overlay(_seen, replica.overlay))
		stats.overlays += 1


func _token_of(overlay: LiveOverlay) -> String:
	return "%s|%d|%d|%d|%d" % [overlay.operation_id, int(replica.stats.previews), overlay.tiles.size(),
		overlay.objects.size(), overlay.scatter_tiles.size()]


func _apply(fx: Dictionary) -> void:
	for entry: Array in fx.maps:
		adapter.mark_dirty(entry[0], entry[1])
	for rect: Rect2 in fx.height_rects:
		layers.heights_changed(rect)
	if not (fx.objects as Array).is_empty():
		presenter.sync_objects(display.doc, fx.objects)
	if fx.rules:
		adapter.set_rules(display.doc.rules)
	if fx.layers:
		layers.rebuild(display.doc)
	if fx.lock:
		assets.attach(display.doc)


func _on_asset_ready(binding_id: String) -> void:
	if display.doc != null and display.doc.assets.has_binding(binding_id):
		presenter.refresh_asset(display.doc, binding_id)
		layers.scatter.asset_registered(binding_id)


func _fail(message: String) -> void:
	stats.errors += 1
	stats.last_error = message


func _build_light() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.shadow_enabled = true
	add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.18, 0.27, 0.34)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color.WHITE
	settings.ambient_light_energy = 0.5
	environment.environment = settings
	add_child(environment)


func _build_label() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	label.position = Vector2(16, 16)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	layer.add_child(label)


## Text of the on-screen label; INCOMPLETE while any referenced asset is unavailable (INT-SPEC §11).
func label_text() -> String:
	if replica == null or replica.document == null or display.doc == null:
		return "WORLD PREVIEW\nWaiting for the iPad…"
	var lines := PackedStringArray(["WORLD PREVIEW  rev %d  %s" % [presented_revision, replica.authored_hash().left(12)]])
	var missing := assets.missing(display.doc)
	if not missing.is_empty():
		lines.append("INCOMPLETE — %d asset(s) not available yet" % missing.size())
	if not replica.overlay.is_empty():
		lines.append("provisional edit in progress")
	if stats.last_error != "":
		lines.append("error: " + str(stats.last_error))
	return "\n".join(lines)


func _update_label() -> void:
	var now := Time.get_ticks_msec()
	if now - _label_msec >= LABEL_REFRESH_MSEC:
		_label_msec = now
		label.text = label_text()
