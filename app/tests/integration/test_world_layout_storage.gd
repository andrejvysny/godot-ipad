extends TestCase
## WORLD-02/03 persistence on the 64-region km1 layout (docs/world-format.md §11): checkpoint,
## recovery, package export and import. One 48 MiB world only; desktop evidence.

const SPRUCE := "nature.tree.spruce_a"

var _catalog: AssetCatalog
var _root := ""
var _storage: WorldStorage


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_catalog.get_asset(SPRUCE).scatter_mesh = "res://assets/test_scatter_mesh.tres"
	_root = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]


func after_each() -> void:
	if _storage != null:
		_storage.shutdown()
		if _storage.is_inside_tree():
			tree.root.remove_child(_storage)
		_storage.free()
		_storage = null
	StorageFs.remove_tree(_root)


func _doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, WorldLayout.km1())
	doc.document_revision = 5
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	doc.get_region(Vector2i(3, 3)).heights[5] = 7.5
	doc.get_region(Vector2i(-4, -4)).control[9] = ControlCodec.encode_paint(0x78, 200)
	for i in 100:
		var r := ObjectRecord.new()
		r.object_id = "00000000-0000-4000-8000-%012d" % i
		r.asset_id = "nature.rock.boulder_a"
		r.asset_version = 1
		r.grounding = WorldConstants.GROUNDING_FIXED
		r.set_position(-500.0 + 9.7 * i, 0.5, 511.5 - 9.9 * i)
		doc.put_object(r)
	for i in 50:
		doc.scatter.add(SPRUCE, 1, -511.0 + 20.5 * i, 400.0 - 17.25 * i, 0.5, 1.0, 1)
	for k in 3:
		var p := PathRecord.new()
		p.path_id = "33333333-3333-4333-8333-33333333333%d" % k
		p.width_m = 2.0
		p.points = PackedVector2Array([Vector2(-500.0 + k, -500.0), Vector2(0.0, 12.5), Vector2(511.5, 511.5)])
		doc.put_path(p)
	return doc


func test_km1_checkpoint_recover_export_import_round_trip() -> void:
	_storage = WorldStorage.new()
	_storage.import_tmp_root = _root.path_join("import_tmp")
	tree.root.add_child(_storage)
	assert_empty_string(_storage.configure(_root, 3, _catalog), "configure")
	var doc := _doc()
	var hash := CanonicalEncoder.authored_hash(doc)
	var res := _storage.checkpoint_now(doc)
	if not assert_true(res.ok, str(res.error)):
		return
	var gen_dir: String = res.path
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(gen_dir.path_join("manifest.json")))
	assert_eq(manifest.schema_version, 3.0)
	assert_eq(manifest.payload_files.size(), 3 + 3 * 64)
	assert_eq(manifest.authored_content_hash, hash)
	var rec := _storage.recover_latest_valid(doc.world_id, _catalog)
	assert_empty_string(rec.error, "recover")
	var back: WorldDocument = rec.doc
	assert_eq(CanonicalEncoder.authored_hash(back), hash, "recovered hash")
	assert_true(back.layout.equals(WorldLayout.km1()))
	assert_eq(WorldCodec.objects_json_bytes(back), WorldCodec.objects_json_bytes(doc), "objects.json bytes")
	assert_eq(back.scatter.encode(), doc.scatter.encode(), "scatter bytes")
	assert_eq(PathRecord.encode_all(back.paths), PathRecord.encode_all(doc.paths), "paths bytes")
	assert_eq(back.get_region(Vector2i(3, 3)).height_bytes(), doc.get_region(Vector2i(3, 3)).height_bytes())
	assert_eq(back.get_region(Vector2i(-4, -4)).control_bytes(), doc.get_region(Vector2i(-4, -4)).control_bytes())
	assert_eq(back.objects.size(), 100)
	var ex := _storage.export_latest(doc.world_id, _catalog)
	if not assert_empty_string(ex.error, "export"):
		return
	var imported := WorldLoader.load_world(ex.path, _catalog, _root.path_join("import_tmp"))
	assert_empty_string(imported[1], "import")
	assert_eq(CanonicalEncoder.authored_hash(imported[0]), hash, "imported hash")
	var loaded := WorldLoader.load_world(gen_dir, _catalog)
	assert_eq(CanonicalEncoder.authored_hash(loaded[0]), hash, "consumer load of the generation directory")
	assert_eq(WorldLoader.report(imported[0], _catalog).object_count, 100)
