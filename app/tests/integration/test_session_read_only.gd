extends TestCase
## A structurally valid world with unavailable asset bindings opens in read-only recovery (ADR 0014 D8):
## shown, every record kept, authoring refused with a posted reason, export still possible.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const OBJ := "11111111-1111-4111-8111-111111111111"

var sessions: Array = []
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	allow_logged_errors()  # the pinned Terrain3D binary emits one known deprecation warning
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	for s: Variant in sessions:
		if is_instance_valid(s):
			if s.get_parent() != null:
				tree.root.remove_child(s)
			s.free()
	sessions.clear()
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


## A stored world whose only object is a spruce of a catalog with another content hash.
func _store_unavailable_world(root: String) -> WorldDocument:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, null, catalog)
	doc.document_revision = 6
	var b := AssetBinding.bundled_default(catalog, catalog.get_asset("nature.tree.spruce_a"))
	b.catalog_sha256 = "ab".repeat(32)
	b.finalize()
	var r := ObjectRecord.new()
	r.object_id = OBJ
	r.binding_id = doc.assets.add(b)
	r.set_position(5.0, 0.0, 5.0)
	doc.put_object(r)
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


func test_unknown_catalog_hash_opens_read_only_and_refuses_editing() -> void:
	var root := scratch_dir() + "/worlds"
	var stored := _store_unavailable_world(root)
	var s := await _start(root)
	assert_eq(s.boot_error, "")
	assert_eq(s.document.world_id, stored.world_id, "recovered, not replaced by a fixture")
	assert_eq(s.document.document_revision, 6)
	assert_true(s.read_only_reason.begins_with("Read-only recovery: 1 asset binding(s) unavailable"), s.read_only_reason)
	assert_eq(s.tools.read_only_reason(), s.read_only_reason)
	assert_true(s.last_message_is_error and s.last_message == s.read_only_reason, "the reason is posted")
	assert_true(s.presenter.has_object(OBJ), "the record is shown (placeholder) and kept")
	var before := s.authored_hash()
	var generations := GenerationStore.complete_generations(GenerationStore.generations_dir(root, s.document.world_id))
	assert_eq(generations, [1] as Array[int], "opening writes no checkpoint")
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.PENCIL
	sample.timestamp_s = 1.0
	sample.position_viewport = s.rig.get_camera().unproject_position(Vector3(5.0, 0.0, 5.0))
	for tool_id in [ToolController.TOOL_PAINT, ToolController.TOOL_RAISE, ToolController.TOOL_SELECT]:
		s.tools.set_tool(tool_id)
		s._on_tool_action({"type": "tool_begin", "sample": sample, "over_ui": false})
		assert_false(s.tools.has_active_operation(), "%s starts nothing" % tool_id)
	assert_ne(s.tools.arm_asset("nature.tree.spruce_a"), "")
	assert_eq(s.save_now(), s.read_only_reason, "no checkpoint is requested")
	assert_eq(s.history.size(), 0)
	assert_eq(s.authored_hash(), before)
	assert_eq(GenerationStore.complete_generations(GenerationStore.generations_dir(root, s.document.world_id)), [1] as Array[int])
	var exported := s.export_world()
	assert_eq(exported.error, "", "export stays available")
	assert_true(FileAccess.file_exists(exported.path))


func test_a_fully_available_world_is_not_read_only() -> void:
	var s := await _start(scratch_dir() + "/worlds")
	assert_eq(s.read_only_reason, "")
	assert_eq(s.tools.read_only_reason(), "")
	s.tools.set_tool(ToolController.TOOL_PAINT)
	assert_empty_string(s.tools.arm_asset("nature.tree.spruce_a"))
