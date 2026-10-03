extends TestCase
## Schema 2/3 -> 4 upgrade in storage (ADR 0014 D9) and structure-versus-availability recovery (D8).

const SPRUCE := "nature.tree.spruce_a"

var _catalog: AssetCatalog
var _root := ""
var _storage: WorldStorage


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_root = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]


func after_each() -> void:
	if _storage != null:
		_storage.shutdown()
		if _storage.is_inside_tree():
			tree.root.remove_child(_storage)
		_storage.free()
		_storage = null
	StorageFs.remove_tree(_root)


func _make_storage(keep_count: int = 3) -> WorldStorage:
	_storage = WorldStorage.new()
	_storage.import_tmp_root = _root.path_join("import_tmp")
	tree.root.add_child(_storage)
	assert_empty_string(_storage.configure(_root, keep_count, _catalog), "configure")
	return _storage


func _gen_dir(world_id: String, n: int) -> String:
	return GenerationStore.generations_dir(_root, world_id).path_join(GenerationStore.generation_name(n))


func _gens(world_id: String) -> Array[int]:
	return GenerationStore.complete_generations(GenerationStore.generations_dir(_root, world_id))


func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## A schema 3 world on a small layout with one object and one scatter instance, stored as generation 1.
func _legacy_world(custom_layout: bool = true) -> WorldDocument:
	var layout := WorldLayout.create(Vector2i(0, 0), Vector2i(2, 1)) if custom_layout else WorldLayout.legacy()
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value(), layout, _catalog)
	doc.document_revision = 4
	var r := ObjectRecord.new()
	r.object_id = "11111111-1111-4111-8111-111111111111"
	r.binding_id = doc.assets.bundled_binding_for("built.lodge.cabin_a")
	r.set_position(10.0, 1.0, 10.0)
	doc.put_object(r)
	doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 20.0, 20.0, 0.0, 1.0, 0)
	assert_empty_string(LegacyWorldWriter.write(_gen_dir(doc.world_id, 1), doc), "legacy generation")
	return doc


func _edit(doc: WorldDocument) -> void:
	doc.get_region(doc.layout.region_locations()[0]).heights[doc.document_revision] = 2.0 + doc.document_revision * 0.25
	doc.bump_revision()


func test_first_checkpoint_pins_the_source_and_writes_a_receipt() -> void:
	var s := _make_storage()
	var original := _legacy_world()
	var source_hash: String = _json(_gen_dir(original.world_id, 1).path_join("manifest.json")).authored_content_hash
	var before := FileAccess.get_file_as_bytes(_gen_dir(original.world_id, 1).path_join("objects.json"))
	var rec := s.recover_latest_valid(original.world_id, _catalog)
	assert_empty_string(rec.error)
	var doc: WorldDocument = rec.doc
	assert_eq(doc.source_schema, 3)
	assert_false(FileAccess.file_exists(_root.path_join(doc.world_id).path_join("pins.json")), "opening writes nothing")
	_edit(doc)
	var res := s.checkpoint_now(doc)
	if not assert_true(res.ok and res.durable, str(res.error)):
		return
	assert_eq(res.generation, 2)
	assert_true(res.upgraded)
	assert_eq(doc.source_schema, 4, "the document is schema 4 once the upgrade is durable")
	var world_dir := _root.path_join(doc.world_id)
	assert_eq(_json(world_dir.path_join("pins.json")), {"schema_version": 1.0, "pinned_generations": [1.0]})
	var receipt: Dictionary = _json(world_dir.path_join("migrations").path_join("00000002.json"))
	var dest_manifest: Dictionary = _json(_gen_dir(doc.world_id, 2).path_join("manifest.json"))
	assert_eq(dest_manifest.schema_version, 4.0)
	assert_eq(receipt, {"schema_version": 1.0, "source_generation": 1.0, "source_schema": 3.0,
		"source_authored_hash": source_hash, "dest_generation": 2.0, "dest_authored_hash": dest_manifest.authored_content_hash})
	assert_eq(FileAccess.get_file_as_bytes(_gen_dir(doc.world_id, 1).path_join("objects.json")), before, "the source generation is unchanged")
	assert_eq(_json(_gen_dir(doc.world_id, 1).path_join("manifest.json")).schema_version, 3.0)
	_edit(doc)
	assert_true(s.checkpoint_now(doc).ok)
	assert_false(FileAccess.file_exists(world_dir.path_join("migrations").path_join("00000003.json")), "only the upgrade has a receipt")


func test_pruning_never_deletes_a_pinned_generation() -> void:
	var s := _make_storage(1)
	var original := _legacy_world(false)  # schema 2 on the legacy layout
	var doc: WorldDocument = s.recover_latest_valid(original.world_id, _catalog).doc
	assert_eq(doc.source_schema, 2)
	for i in 4:
		_edit(doc)
		assert_true(s.checkpoint_now(doc).ok)
	assert_eq(_gens(doc.world_id), [5, 1] as Array[int], "keep=1 retains the newest generation and the pinned source")
	assert_eq(GenerationStore.pinned_generations(_root.path_join(doc.world_id)), [1] as Array[int])
	var again := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq(again.generation, 5)
	assert_eq(again.doc.source_schema, 4)


func test_a_world_without_a_stored_source_writes_no_pin() -> void:
	var s := _make_storage()
	var loaded := SessionWorldOps.load_fixture("gentle_hills", _catalog)
	var doc: WorldDocument = loaded[0]
	assert_eq(doc.source_schema, 2)
	assert_true(s.checkpoint_now(doc).ok)
	assert_false(FileAccess.file_exists(_root.path_join(doc.world_id).path_join("pins.json")), "a fixture is not a stored generation")
	assert_eq(doc.source_schema, 4)


func test_failed_upgrade_keeps_the_document_legacy_and_removes_its_receipt() -> void:
	var s := _make_storage()
	var original := _legacy_world()
	var doc: WorldDocument = s.recover_latest_valid(original.world_id, _catalog).doc
	_edit(doc)
	s.fault_injection = {"fail_on_file": "objects.json"}
	var res := s.checkpoint_now(doc)
	assert_false(res.ok)
	assert_eq(doc.source_schema, 3, "still a schema 3 document: nothing durable yet")
	assert_false(FileAccess.file_exists(_root.path_join(doc.world_id).path_join("migrations/00000002.json")), "no receipt without a generation")
	s.fault_injection = {}
	var retry := s.checkpoint_now(doc)
	assert_true(retry.ok, str(retry.error))
	assert_true(FileAccess.file_exists(_root.path_join(doc.world_id).path_join("migrations/00000002.json")))
	assert_eq(GenerationStore.pinned_generations(_root.path_join(doc.world_id)), [1] as Array[int])


## A foreign catalog is availability, not structure: recovery opens that generation (never skips it for an older
## one or a fixture); a structurally broken newer generation is skipped.
func test_recovery_skips_only_structurally_invalid_generations() -> void:
	var s := _make_storage()
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value(), null, _catalog)
	doc.document_revision = 3
	var b := AssetBinding.bundled_default(_catalog, _catalog.get_asset(SPRUCE))
	b.catalog_sha256 = "ab".repeat(32)
	b.finalize()
	var r := ObjectRecord.new()
	r.object_id = "11111111-1111-4111-8111-111111111111"
	r.binding_id = doc.assets.add(b)
	r.set_position(1.0, 1.0, 1.0)
	doc.put_object(r)
	assert_empty_string(WorldCodec.write_generation(_gen_dir(doc.world_id, 1), doc, WorldCodec.default_created_with()))
	doc.document_revision = 4
	assert_empty_string(WorldCodec.write_generation(_gen_dir(doc.world_id, 2), doc, WorldCodec.default_created_with()))
	var broken := FileAccess.open(_gen_dir(doc.world_id, 2).path_join("regions/r_0_0.height.f32le"), FileAccess.READ_WRITE)
	broken.seek(10)
	broken.store_8(0x55)
	broken.close()
	var found := s.recover_latest_valid(doc.world_id, _catalog)
	assert_empty_string(found.error)
	assert_eq(found.generation, 1, "the corrupt newer generation is skipped, the unavailable older one is opened")
	assert_eq(found.skipped.size(), 1)
	var back: WorldDocument = found.doc
	assert_eq(back.document_revision, 3)
	assert_eq(WorldValidator.availability(back).unavailable.keys(), [b.binding_id])
	assert_eq(SessionWorldOps.read_only_text(back).begins_with("Read-only recovery: 1 asset binding(s) unavailable"), true)
	assert_eq(SessionWorldOps.read_only_text(WorldDocument.create_flat(0.0, 0, null, _catalog)), "")
	# The unavailable world exports like any other.
	var exported := s.export_latest(doc.world_id, _catalog)
	assert_empty_string(exported.error, "export stays available")
