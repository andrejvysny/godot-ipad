extends TestCase
## Schema 3 generations (docs/world-format.md §11) on small layouts, plus WORLD-03 limits.
## The 64-region km1 round trip lives in tests/integration/test_world_layout_storage.gd.

const OBJ_A := "11111111-1111-4111-8111-111111111111"
const PATH_A := "33333333-3333-4333-8333-333333333333"
const SPRUCE := "nature.tree.spruce_a"

var _catalog: AssetCatalog
var _dir := ""
var _layout: WorldLayout


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_catalog.get_asset(SPRUCE).scatter_mesh = "res://assets/test_scatter_mesh.tres"
	_layout = WorldLayout.create(Vector2i(0, 0), Vector2i(2, 1))  # x in [0, 255.5], z in [0, 127.5]
	_dir = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]
	DirAccess.make_dir_recursive_absolute(_dir)


func after_each() -> void:
	StorageFs.remove_tree(_dir)


func _doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value(), _layout)
	doc.document_revision = 3
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	doc.get_region(Vector2i(1, 0)).heights[7] = 12.5
	doc.scatter.add(SPRUCE, 1, 200.5, 50.25, 1.0, 1.25, 1)
	var p := PathRecord.new()
	p.path_id = PATH_A
	p.width_m = 2.0
	p.points = PackedVector2Array([Vector2(10, 10), Vector2(250, 120)])
	doc.put_path(p)
	var o := ObjectRecord.new()
	o.object_id = OBJ_A
	o.asset_id = "built.lodge.cabin_a"
	o.asset_version = 1
	o.grounding = WorldConstants.GROUNDING_FIXED
	o.set_position(255.5, 3.0, 127.5)
	doc.put_object(o)
	return doc


func _gen(doc: WorldDocument = null) -> String:
	var dir := _dir.path_join("gen_" + StorageFs.random_hex(4))
	assert_empty_string(WorldCodec.write_generation(dir, doc if doc else _doc(), WorldCodec.default_created_with()), "write")
	return dir


func _manifest(dir: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("manifest.json")))


func _write_manifest(dir: String, m: Dictionary) -> void:
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(m, "  "))
	f.close()


func _replace_payload(dir: String, path: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(dir.path_join(path), FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	var m := _manifest(dir)
	for e in m.payload_files:
		if e.path == path:
			e.bytes = data.size()
			e.sha256 = CanonicalEncoder.sha256_hex(data)
	_write_manifest(dir, m)


func _copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to.path_join("regions"))
	for path in WorldCodec.payload_paths(_layout) + PackedStringArray(["manifest.json"]):
		DirAccess.copy_absolute(from.path_join(path), to.path_join(path))


func test_payload_paths_follow_the_layout() -> void:
	assert_eq(WorldCodec.payload_paths().size(), 15, "default is the legacy layout")
	assert_eq(WorldCodec.payload_paths(WorldLayout.legacy()), WorldCodec.payload_paths())
	assert_eq(WorldCodec.payload_paths(_layout).size(), 3 + 3 * 2)
	assert_eq(WorldCodec.payload_paths(WorldLayout.km1()).size(), 3 + 3 * 64)
	var sorted := WorldCodec.payload_paths(WorldLayout.km1())
	var copy := sorted.duplicate()
	copy.sort()
	assert_eq(sorted, copy, "byte-wise sorted")
	assert_eq(WorldCodec.payload_limit("scatter.bin", 2), 512 * 1024)
	assert_eq(WorldCodec.payload_limit("scatter.bin", 3), 4 * 1024 * 1024)
	assert_eq(WorldCodec.payload_limit("objects.json", 3), 128 * 1024 * 1024)
	assert_eq(WorldCodec.payload_limit("regions/r_0_0.height.f32le", 3), WorldConstants.REGION_MAP_BYTES)


func test_schema_3_round_trip_is_exact() -> void:
	var doc := _doc()
	var snap := WorldCodec.snapshot(doc, {})
	assert_eq(snap.layout_min, Vector2i(0, 0), "layout travels as plain values")
	assert_eq(snap.layout_count, Vector2i(2, 1))
	var dir := _gen(doc)
	var m := _manifest(dir)
	assert_eq(m.schema_version, 3.0)
	assert_eq(m.terrain.layout, {"min_region": [0.0, 0.0], "region_count": [2.0, 1.0]})
	assert_eq(m.terrain.region_locations, [[0.0, 0.0], [1.0, 0.0]])
	assert_eq(m.payload_files.size(), 9)
	assert_eq(JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("objects.json"))).schema_version, 3.0)
	var r := WorldCodec.read_generation(dir, _catalog)
	if not assert_empty_string(r[1], "read"):
		return
	var back: WorldDocument = r[0]
	assert_true(back.layout.equals(_layout))
	assert_eq(back.schema_version, 3)
	assert_eq(CanonicalEncoder.authored_hash(back), CanonicalEncoder.authored_hash(doc))
	assert_eq(CanonicalEncoder.authored_hash(back), m.authored_content_hash)
	assert_eq(CanonicalEncoder.authored_bytes(back).slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V3\n")
	var again := _gen(back)
	for path in WorldCodec.payload_paths(_layout) + PackedStringArray(["manifest.json"]):
		if path != "manifest.json":
			assert_eq(FileAccess.get_file_as_bytes(again.path_join(path)), FileAccess.get_file_as_bytes(dir.path_join(path)), path)


func test_legacy_documents_still_write_schema_2() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	var dir := _gen(doc)
	var m := _manifest(dir)
	assert_eq(m.schema_version, 2.0)
	assert_false(m.terrain.has("layout"))
	assert_eq(m.payload_files.size(), 15)
	assert_eq(JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("objects.json"))).schema_version, 2.0)
	assert_eq(CanonicalEncoder.authored_bytes(doc).slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V2\n")
	var back: WorldDocument = WorldCodec.read_generation(dir, _catalog)[0]
	assert_true(back.layout.is_legacy())


func test_rejects_layout_manifest_tampering() -> void:
	var cases := {
		"schema 3 must not use the legacy 2x2 layout": func(m: Dictionary) -> void: m.terrain.layout = {"min_region": [-1, -1], "region_count": [2, 2]},
		"missing field 'layout'": func(m: Dictionary) -> void: m.terrain.erase("layout"),
		"terrain.layout has unknown field": func(m: Dictionary) -> void: m.terrain.layout["extra"] = 1,
		"terrain.layout.min_region must be two integers": func(m: Dictionary) -> void: m.terrain.layout.min_region = [0, 0.5],
		"region_count": func(m: Dictionary) -> void: m.terrain.layout.region_count = [9, 1],
		"min_region": func(m: Dictionary) -> void: m.terrain.layout.min_region = [-9, 0],
		"leaves the region range": func(m: Dictionary) -> void: m.terrain.layout.min_region = [7, 0],
		"terrain.region_locations must be exactly": func(m: Dictionary) -> void: m.terrain.region_locations = [[1, 0], [0, 0]],
		"terrain.region_locations must be exactly ": func(m: Dictionary) -> void: m.terrain.layout.region_count = [1, 1],
		"exactly the 9 payload files": func(m: Dictionary) -> void: m.payload_files.pop_back(),
		"exactly the 9 payload files ": func(m: Dictionary) -> void: m.payload_files.append(m.payload_files[0].duplicate()),
	}
	var base := _gen()
	for key in cases:
		var dir := _dir.path_join("t_" + StorageFs.random_hex(4))
		_copy_dir(base, dir)
		var m := _manifest(dir)
		cases[key].call(m)
		_write_manifest(dir, m)
		var r := WorldCodec.read_generation(dir, _catalog)
		assert_eq(r[0], null, key)
		assert_error_contains(r[1], String(key).strip_edges(), key)


func test_schema_2_manifest_rejects_a_layout_block() -> void:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	var dir := _gen(doc)
	var m := _manifest(dir)
	m.terrain["layout"] = WorldLayout.legacy().to_manifest()
	_write_manifest(dir, m)
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "unknown field 'layout'")


func test_rejects_missing_and_extra_region_files() -> void:
	var dir := _gen()
	DirAccess.remove_absolute(dir.path_join("regions/r_1_0.control.u32le"))
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "r_1_0.control")
	dir = _gen()
	var f := FileAccess.open(dir.path_join("regions/r_2_0.height.f32le"), FileAccess.WRITE)
	f.store_8(1)
	f.close()
	var extra := WorldCodec.load_verified(dir)
	assert_empty_string(extra.error, "a stray file is not part of the manifest and is ignored by the reader")
	var m := _manifest(dir)
	m.payload_files.append({"path": "regions/r_2_0.height.f32le", "bytes": 1, "sha256": "ab".repeat(32)})
	_write_manifest(dir, m)
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "exactly the 9 payload files")


func test_objects_schema_must_match_the_manifest_schema() -> void:
	var dir := _gen()
	var objs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("objects.json")))
	objs.schema_version = 2
	_replace_payload(dir, "objects.json", JSON.stringify(objs).to_utf8_buffer())
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "schema_version")


func test_object_scatter_and_path_extent_comes_from_the_layout() -> void:
	# The valid document has content at x = 255.5, which is outside the legacy extent.
	assert_empty_string(WorldCodec.read_generation(_gen(), _catalog)[1])
	var doc := _doc()
	doc.get_object(OBJ_A).set_position(256.0, 3.0, 127.5)
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "outside the world extent", "object")
	doc = _doc()
	doc.scatter.z[0] = 128.0
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "extent", "scatter")
	doc = _doc()
	doc.get_path_record(PATH_A).points[1] = Vector2(250.0, -0.5)
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "extent", "path")


func test_object_count_limit_follows_the_manifest_schema() -> void:
	var legacy_doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	legacy_doc.catalog_id = _catalog.catalog_id
	legacy_doc.catalog_version = _catalog.catalog_version
	legacy_doc.catalog_sha256 = _catalog.sha256
	var dir := _gen(legacy_doc)
	_replace_payload(dir, "objects.json", _empty_records(2001, 2))
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "2001 objects exceed the limit of 2000", "schema 2")
	dir = _gen()
	_replace_payload(dir, "objects.json", _empty_records(2001, 3))
	var r := WorldCodec.read_generation(dir, _catalog)
	assert_false(r[1].contains("exceed the limit"), "2001 objects pass the count limit under schema 3")
	_replace_payload(dir, "objects.json", _empty_records(50001, 3))
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "50001 objects exceed the limit of 50000", "schema 3")


## Cheap over-limit input: the count check runs before any record is parsed.
func _empty_records(n: int, schema: int) -> PackedByteArray:
	var parts := PackedStringArray()
	parts.resize(n)
	parts.fill("{}")
	return ('{"schema_version": %d, "objects": [%s]}' % [schema, ",".join(parts)]).to_utf8_buffer()


func test_scatter_decode_limit_is_per_schema() -> void:
	var header := PackedByteArray()
	header.append_array("WPSC".to_ascii_buffer())
	header.resize(16)
	header.encode_u32(4, 1)
	header.encode_u32(8, 0)
	header.encode_u32(12, 20001)
	assert_error_contains(ScatterLayer.decode(header)[1], "20001 instances exceed the limit of 20000", "default is schema 2")
	assert_error_contains(ScatterLayer.decode(header, 20000)[1], "exceed the limit of 20000")
	assert_error_contains(ScatterLayer.decode(header, 100000)[1], "truncated", "schema 3 passes the count check")
	header.encode_u32(12, 100001)
	assert_error_contains(ScatterLayer.decode(header, 100000)[1], "100001 instances exceed the limit of 100000")


func test_oversized_manifest_is_rejected_per_schema() -> void:
	var dir := _gen()
	var m := _manifest(dir)
	m.created_with.world_painter = "x".repeat(300 * 1024)
	_write_manifest(dir, m)
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "manifest")
	dir = _gen()
	m = _manifest(dir)
	m.created_with.world_painter = "x".repeat(100 * 1024)
	_write_manifest(dir, m)
	assert_empty_string(WorldCodec.read_generation(dir, _catalog)[1], "100 KiB fits the schema 3 limit")
	var legacy_doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	legacy_doc.catalog_id = _catalog.catalog_id
	legacy_doc.catalog_version = _catalog.catalog_version
	legacy_doc.catalog_sha256 = _catalog.sha256
	dir = _gen(legacy_doc)
	m = _manifest(dir)
	m.created_with.world_painter = "x".repeat(100 * 1024)
	_write_manifest(dir, m)
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "manifest is", "100 KiB exceeds the schema 2 limit")


func test_write_snapshot_rejects_an_invalid_layout() -> void:
	var snap := WorldCodec.snapshot(_doc(), {})
	snap.layout_count = Vector2i(9, 1)
	assert_error_contains(WorldCodec.write_snapshot(_dir.path_join("bad"), snap), "invalid layout")
