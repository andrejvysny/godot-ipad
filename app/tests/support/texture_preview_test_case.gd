class_name TexturePreviewTestCase
extends TestCase
## Fixed-area Texture Preview, terrain side (spec §11, PREVIEW-01..07, MEMORY-04 preview part):
## state machine, fixed capture, partial readiness, late-result discard and release through the shared
## RenderAssetCache, with a real TerrainAdapter and the prepared preview PNGs.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const AUTO := WorldConstants.DEFAULT_CONTROL
const TIMEOUT_FRAMES := 600

class BenchStub extends Node:
	func is_running() -> bool:
		return true

	func abort(_reason: String) -> void:
		pass


var _filter: TerrainTests.KnownWarningFilter
var _adapter: TerrainAdapter
var _doc: WorldDocument
var _cache: RenderAssetCache
var _sessions: Array = []


func before_each() -> void:
	allow_logged_errors()
	_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(_filter)


func after_each() -> void:
	tree.paused = false
	for s: Variant in _sessions:
		if is_instance_valid(s):
			if s.get_parent() != null:
				tree.root.remove_child(s)
			s.free()
	_sessions.clear()
	if _adapter != null and is_instance_valid(_adapter):
		_adapter.get_parent().remove_child(_adapter)
		_adapter.free()
	_adapter = null
	assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))
	OS.remove_logger(_filter)


func _make(doc: WorldDocument) -> TexturePreviewController:
	return _make_with(doc, {})


func _make_with(doc: WorldDocument, sources: Dictionary) -> TexturePreviewController:
	_doc = doc
	var a := TerrainAdapter.new()
	tree.root.add_child(a)
	var cam := Camera3D.new()
	a.add_child(cam)
	cam.position = Vector3(0, 60, 60)
	a.set_camera(cam)
	assert_empty_string(a.initialize(doc), "initialize")
	_adapter = a
	var config := RenderConfig.safe_default()
	_cache = RenderAssetCache.new(_budgets())
	var ctrl := TexturePreviewController.new(_cache, config.section("texture_preview"), sources)
	ctrl.bind(a, doc)
	return ctrl


## The headless dummy renderer's texture storage is not thread-safe: concurrent texture loads corrupt it.
func _budgets() -> Dictionary:
	var budgets := RenderConfig.safe_default().section("budgets")
	budgets.inflight_loads = 1
	return budgets


## Drives the cache and the controller like the session frame loop until the state leaves LOADING.
func _drive(ctrl: TexturePreviewController, until := "") -> void:
	for i in TIMEOUT_FRAMES:
		if ctrl.state() != TexturePreviewController.LOADING and (until == "" or ctrl.state() == until):
			return
		ctrl.service(2.0)
		await tree.process_frame
	fail("preview stayed %s" % ctrl.state())


## RELEASING -> OFF takes a frame boundary.
func _off(ctrl: TexturePreviewController) -> void:
	for i in TIMEOUT_FRAMES:
		ctrl.service(2.0)
		if ctrl.state() == TexturePreviewController.OFF:
			return
		await tree.process_frame
	fail("preview stayed %s" % ctrl.state())


func _drain(ctrl: TexturePreviewController) -> void:
	for i in TIMEOUT_FRAMES:
		ctrl.service(2.0)
		var st := _cache.stats()
		if int(st.queued) + int(st.loading) == 0:
			return
		await tree.process_frame
	fail("cache never went idle")


## Flat auto world with a manual dirt patch and a sand basin so several slots are used near the origin.
func _mixed_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		var o := Vector2i(loc.x * 256, loc.y * 256)
		for j in WorldConstants.REGION_SAMPLES:
			for i in WorldConstants.REGION_SAMPLES:
				var x := (o.x + i) * 0.5
				var z := (o.y + j) * 0.5
				var k := j * 256 + i
				if x >= 0.0 and x <= 8.0 and absf(z) <= 8.0:
					r.control[k] = ControlCodec.encode(AUTO, {"overlay_id": WorldConstants.MATERIAL_DIRT, "blend": 255})
				if x >= -8.0 and x < 0.0 and absf(z) <= 8.0:
					r.heights[k] = -2.0
	doc.invalidate_all_height_ranges()
	return doc


func _paths_without(slot: int, kind: String) -> Dictionary:
	var sources := TerrainPreviewParticipant.default_sources()
	sources[slot][kind] = "res://assets/terrain/preview/does_not_exist.png"
	return sources


# --- PREVIEW-01 ----------------------------------------------------------------------------------

func _start_session() -> EditorSession:
	var s := EditorSession.new()
	s.storage_root = scratch_dir() + "/worlds"
	s.start_fixture = "flat"
	s.provider_override = InputTests.FakeProvider.new()
	s.build_ui = false
	_sessions.append(s)
	tree.root.add_child(s)
	await tree.process_frame
	for i in 300:
		if not s.storage.is_busy():
			break
		await tree.process_frame
	return s


func _place_boulder(s: EditorSession, x: float, z: float) -> String:
	var asset := s.catalog.get_asset("nature.rock.boulder_a")
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.binding_id = s.document.assets.bundled_binding_for(asset.asset_id)
	r.grounding = asset.default_grounding
	r.set_position(x, s.document.sample_height(x, z), z)
	s.document.put_object(r)
	s.presenter.sync_object(s.document, r.object_id)
	return r.object_id


func _session_frames(s: EditorSession, until: String) -> void:
	for i in TIMEOUT_FRAMES:
		if str(s.texture_preview_status().state) == until:
			return
		await tree.process_frame
	fail("session preview never reached %s: %s" % [until, s.texture_preview_status()])
