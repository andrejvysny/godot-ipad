extends TestCase
## Session wiring of the AssetStudio providers (IP-03): a world with remote bindings opens read-only, becomes
## editable once everything it references is prepared, stays unavailable offline without the exact bytes, and
## cancels in-flight work on a world switch or app deactivation.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")

var sessions: Array = []
var log_filter: TerrainTests.KnownWarningFilter
var catalog: AssetCatalog


func before_each() -> void:
	allow_logged_errors()  # the pinned Terrain3D binary emits one known deprecation warning
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)
	catalog = AssetCatalog.load_from()[0]
	SessionAssets.storage_dir = scratch_dir() + "/assetstudio"


func after_each() -> void:
	for s: Variant in sessions:
		if is_instance_valid(s):
			if s.get_parent() != null:
				tree.root.remove_child(s)
			s.free()
	sessions.clear()
	SessionAssets.storage_dir = AssetStudioConnection.DIR
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


## Stores the contract fixture `name` as the latest world of `root`.
func _store(root: String, name: String) -> WorldDocument:
	var imported := WorldPackage.import_package(ContractFiles.path("fixtures/" + name + ".worldpoc"), catalog, scratch_dir() + "/pkg")
	assert_empty_string(imported[1])
	var doc: WorldDocument = imported[0]
	var dir := GenerationStore.generations_dir(root, doc.world_id).path_join("00000001")
	assert_empty_string(WorldCodec.write_generation(dir, doc, WorldCodec.default_created_with()))
	StorageFs.write_bytes(root.path_join(GenerationStore.LAST_WORLD_FILE), doc.world_id.to_utf8_buffer())
	return doc


func _start(root: String) -> EditorSession:
	var s := EditorSession.new()
	s.storage_root = root
	s.provider_override = InputTests.FakeProvider.new()
	s.build_ui = false
	sessions.append(s)
	tree.root.add_child(s)
	await tree.process_frame
	for i in 300:
		if not s.storage.is_busy():
			break
		await tree.process_frame
	return s


func _bytes_for(doc: WorldDocument) -> FakeAssetProvider:
	var fake := FakeAssetProvider.new()
	for id in doc.assets.ids():
		fake.glb_by_binding[id] = AssetTestKit.glb(AssetTestKit.GLB_V1)
	return fake


func _wait_editable(s: EditorSession) -> void:
	for i in 300:
		if s.read_only_reason == "":
			return
		await tree.process_frame


func test_contract_world_opens_read_only_then_becomes_editable_after_prepare() -> void:
	var root := scratch_dir() + "/worlds"
	var stored := _store(root, "one_remote_object")
	var s := await _start(root)
	assert_eq(s.boot_error, "")
	assert_eq(s.document.world_id, stored.world_id)
	await tree.process_frame
	assert_true(s.read_only_reason.begins_with("Read-only recovery: 1 asset binding(s) unavailable"), s.read_only_reason)
	assert_error_contains(s.read_only_reason, "temporarily_unavailable", "offline without the exact bytes: the visible reason")
	assert_eq(s.tools.read_only_reason(), s.read_only_reason)
	var id: String = s.document.assets.ids()[0]
	var obj: String = s.document.sorted_object_ids()[0]
	assert_true(s.presenter.has_object(obj), "the record is shown (placeholder)")
	assert_false(s.render_state().registry().is_ready(id))
	var fake := _bytes_for(s.document)
	s._assets.replace_assetstudio_provider(fake)
	s._assets.start()
	await _wait_editable(s)
	assert_eq(s.read_only_reason, "", "everything referenced is available now")
	assert_eq(s.tools.read_only_reason(), "")
	assert_true(s.render_state().registry().is_ready(id))
	assert_true(s.presenter.settle_now())
	var world := s.presenter.render_world()
	assert_true(world.batch_of(obj).multimesh().mesh != world.placeholder_mesh(), "the object draws prepared tiers")
	s.tools.set_tool(ToolController.TOOL_PAINT)
	assert_eq(s.last_message, "Saving revision %d" % s.document.document_revision, "the world is saved once it is editable")
	assert_empty_string(s.tools.arm_asset("nature.tree.spruce_a"), "authoring works again")


func test_world_switch_cancels_in_flight_prepare_and_unpins() -> void:
	var root := scratch_dir() + "/worlds"
	_store(root, "one_remote_object")
	var s := await _start(root)
	var fake := _bytes_for(s.document)
	fake.delay_frames = 20
	s._assets.replace_assetstudio_provider(fake)
	s._assets.start()
	await tree.process_frame
	assert_eq(fake.pending_count(), 1)
	var id: String = s.document.assets.ids()[0]
	assert_empty_string(s.open_fixture("flat"))
	for i in 40:
		await tree.process_frame
	assert_eq(fake.pending_count(), 0, "the in-flight prepare ended")
	assert_false(s.render_state().registry().is_ready(id), "a prepare finishing after the switch registers nothing")
	assert_eq(s.read_only_reason, "")
	assert_false(fake.is_prepared(id))


func test_prepared_assets_survive_a_switch_to_a_world_that_shares_them_and_drop_otherwise() -> void:
	var root := scratch_dir() + "/worlds"
	_store(root, "one_remote_object")
	var s := await _start(root)
	var fake := _bytes_for(s.document)
	s._assets.replace_assetstudio_provider(fake)
	s._assets.start()
	await _wait_editable(s)
	var id: String = s.document.assets.ids()[0]
	assert_true(fake.is_prepared(id))
	assert_empty_string(s.open_fixture("flat"))
	assert_false(fake.is_prepared(id), "no owner pins it any more")
	assert_false(s.render_state().registry().is_ready(id))


func test_app_deactivation_cancels_and_unpins_then_resume_prepares_again() -> void:
	var root := scratch_dir() + "/worlds"
	_store(root, "one_remote_object")
	var s := await _start(root)
	var fake := _bytes_for(s.document)
	s._assets.replace_assetstudio_provider(fake)
	s._assets.start()
	await _wait_editable(s)
	var id: String = s.document.assets.ids()[0]
	s._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_false(fake.is_prepared(id), "released on deactivation")
	s._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	for i in 60:
		if fake.is_prepared(id):
			break
		await tree.process_frame
	assert_true(fake.is_prepared(id), "prepared again after the app resumes")


func test_remote_scatter_world_opens_and_renders_after_prepare() -> void:
	var root := scratch_dir() + "/worlds"
	_store(root, "remote_scatter")
	var s := await _start(root)
	assert_true(s.read_only_reason != "")
	var fake := _bytes_for(s.document)
	s._assets.replace_assetstudio_provider(fake)
	s._assets.start()
	await _wait_editable(s)
	assert_eq(s.read_only_reason, "")
	s.layers.scatter.flush()
	assert_true(s.layers.scatter.settle_now())
	assert_eq(int(s.layers.scatter.stats().placeholder_batches), 0)
	assert_eq(int(s.layers.scatter.stats().instances), 3)
