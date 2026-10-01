extends TestCase
## Session-start pipeline warm-up (rendering spec §17): the draw set exists for exactly two frames under the
## camera, is then freed, never becomes presenter/world/document state, and is reported in status().

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")

var session: EditorSession
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	if is_instance_valid(session):
		if session.get_parent() != null:
			tree.root.remove_child(session)
		session.free()
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


func _boot() -> void:
	session = EditorSession.new()
	session.storage_root = scratch_dir() + "/worlds"
	session.provider_override = ScriptedInputProvider.new()
	session.build_ui = false
	tree.root.add_child(session)


func test_warmup_nodes_live_two_frames_then_are_freed_without_touching_ownership() -> void:
	await _boot()
	var warmup := session.render_state().warmup
	var root := warmup.node()
	assert_true(root != null and warmup.is_active(), "the draw set exists at session start")
	assert_eq(root.get_parent(), session.rig.get_camera(), "just in front of the camera")
	assert_true(root.get_child_count() > 0 and warmup.draws == root.get_child_count())
	var hash_before := session.authored_hash()
	for child in root.get_children():
		assert_eq((child as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_true(session.presenter.find_child(PipelineWarmup.NODE_NAME, true, false) == null, "not presenter state")
	assert_true(session.presenter.render_world().find_child(PipelineWarmup.NODE_NAME, true, false) == null)
	assert_true(session.layers.find_child(PipelineWarmup.NODE_NAME, true, false) == null)
	await tree.process_frame
	assert_true(warmup.is_active(), "still present on the second frame")
	for i in 4:
		await tree.process_frame
	assert_false(warmup.is_active(), "freed after the warm-up frames")
	assert_false(is_instance_valid(root))
	assert_true(session.rig.get_camera().find_child(PipelineWarmup.NODE_NAME, true, false) == null)
	var status: Dictionary = session.status().pipeline_warmup
	assert_eq(status.state, "done")
	assert_eq(int(status.draws), warmup.draws)
	assert_true(status.compilations_delta.has("surface") and status.compilations_delta.has("draw"))
	assert_true(float(status.ms) >= 0.0)
	assert_eq(session.authored_hash(), hash_before, "the document is untouched")
	assert_eq(session.history.size(), 0)


func test_warmup_covers_every_ready_editor_asset_and_shared_materials() -> void:
	await _boot()
	var warmup := session.render_state().warmup
	var registry := session.render_state().registry()
	var names := PackedStringArray()
	for child in warmup.node().get_children():
		names.append(child.name)
	for id in registry.ready_ids():
		assert_true(names.has(id.replace(".", "_")), "selected-tier MeshInstance3D of " + id)
	for special in ["placeholder", "ghost_box", "overview"]:
		assert_true(names.has(special), special)
	var multimeshes := 0
	for child in warmup.node().get_children():
		if child is MultiMeshInstance3D:
			multimeshes += 1
			assert_eq((child as MultiMeshInstance3D).multimesh.instance_count, 1)
	assert_true(multimeshes >= registry.ready_ids().size(), "one MultiMesh per distinct tier mesh")


func test_warmup_is_skipped_for_a_running_bench_request_and_aborts_when_one_starts() -> void:
	var warmup := PipelineWarmup.new()
	var camera := Camera3D.new()
	tree.root.add_child(camera)
	var registry := RenderAssetRegistry.empty_for(AssetCatalog.new())
	warmup.start(camera, registry, StandardMaterial3D.new(), BoxMesh.new(), StandardMaterial3D.new())
	assert_true(warmup.is_active())
	warmup.tick(true)
	assert_false(warmup.is_active(), "a bench start frees the nodes at once")
	assert_eq(warmup.state, "skipped")
	assert_eq(camera.get_child_count(), 0)
	tree.root.remove_child(camera)
	camera.free()


## Rendered runs only (scripts/dev.py test --rendered): the warm-up draws reach the renderer and the counter deltas are reported.
func test_gpu_warmup_reports_pipeline_counter_deltas() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("    NOT RUN: no rendering device (headless); run scripts/dev.py test --rendered")
		return
	await _boot()
	for i in 6:
		await tree.process_frame
	var status: Dictionary = session.status().pipeline_warmup
	print("    PIPELINE_WARMUP ", JSON.stringify(status))
	assert_eq(status.state, "done")
	assert_true(int(status.draws) > 0)
	for key: String in ["canvas", "mesh", "surface", "draw", "specialization"]:
		assert_true(status.compilations_delta.has(key), key)
		assert_true(int(status.compilations_delta[key]) >= 0, key)
