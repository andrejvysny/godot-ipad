extends TestCase
## Generation directory write/read: byte-exact payloads, strict manifest, authored hash.

const OBJ_A := "11111111-1111-4111-8111-111111111111"
const OBJ_B := "22222222-2222-4222-8222-222222222222"

var _catalog: AssetCatalog
var _dir := ""


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_dir = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]
	DirAccess.make_dir_recursive_absolute(_dir)


func after_each() -> void:
	StorageFs.remove_tree(_dir)


func _doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value())
	doc.document_revision = 7
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	var r := doc.get_region(Vector2i(-1, -1))
	r.heights[0] = -0.0
	r.heights[1] = 1e-38
	r.heights[2] = 1.4e-45  # smallest float32 denormal
	r.heights[3] = WorldConstants.HEIGHT_MAX
	r.heights[65535] = WorldConstants.HEIGHT_MIN
	doc.get_region(Vector2i(0, 0)).control[9] = ControlCodec.encode_paint(0x78, 200)
	var a := ObjectRecord.new()
	a.object_id = OBJ_B
	a.asset_id = "nature.tree.spruce_a"
	a.asset_version = 1
	a.set_position(0.1, 1.0, 1.0 / 3.0)
	a.set_yaw(deg_to_rad(33.0))
	a.uniform_scale = 1.1
	a.origin = WorldConstants.ORIGIN_SCATTER
	a.scatter_operation_id = ObjectRecord.new_uuid_v4()
	doc.put_object(a)
	var b := ObjectRecord.new()
	b.object_id = OBJ_A
	b.asset_id = "built.lodge.cabin_a"
	b.asset_version = 1
	b.grounding = WorldConstants.GROUNDING_FIXED
	b.set_position(-127.9, 5.123456789012345, 127.5)
	b.height_offset_m = -0.7
	doc.put_object(b)
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


## Replaces a payload and updates its manifest entry so later checks are reached.
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


func test_payload_bytes_round_trip_exactly() -> void:
	var doc := _doc()
	var r := doc.get_region(Vector2i(0, -1))
	r.control[0] = 0x7FC00001
	r.control[1] = 0xFFFFFFFF
	r.control[2] = 0x80000000
	var snap := WorldCodec.snapshot(doc, {})
	var dir := _gen(doc)
	var v := WorldCodec.load_verified(dir)
	if not assert_empty_string(v.error, "verify"):
		return
	for path in WorldCodec.payload_paths():
		assert_eq(v.files[path], snap.files[path], "bytes of %s" % path)
	var back := RegionBuffers.new(Vector2i(0, -1))
	back.set_from_bytes(v.files["regions/r_0_-1.height.f32le"], v.files["regions/r_0_-1.control.u32le"])
	assert_eq(back.get_control(0), 0x7FC00001, "NaN-like control pattern")
	assert_eq(back.get_control(1), 0xFFFFFFFF)
	assert_eq(back.get_control(2), 0x80000000)
	var h := v.files["regions/r_-1_-1.height.f32le"] as PackedByteArray
	assert_eq(h.slice(0, 4), PackedByteArray([0, 0, 0, 0x80]), "-0.0 sign bit kept")
	assert_eq(h.slice(8, 12), PackedByteArray([1, 0, 0, 0]), "denormal kept")
	assert_eq(h.slice(4, 8), PackedFloat32Array([1e-38]).to_byte_array(), "1e-38 kept")


func test_manifest_shape() -> void:
	var dir := _gen()
	var m := _manifest(dir)
	assert_eq(m.keys().size(), WorldCodec.MANIFEST_KEYS.size())
	assert_eq(m.format, "world-painter-poc")
	assert_eq(m.document_revision, 7.0)
	assert_eq(m.terrain.region_locations, [[-1.0, -1.0], [0.0, -1.0], [-1.0, 0.0], [0.0, 0.0]])
	var paths: Array = []
	for e in m.payload_files:
		paths.append(e.path)
		var bytes := FileAccess.get_file_as_bytes(dir.path_join(e.path))
		assert_eq(int(e.bytes), bytes.size(), "size " + e.path)
		assert_eq(e.sha256, CanonicalEncoder.sha256_hex(bytes), "hash " + e.path)
	assert_eq(PackedStringArray(paths), WorldCodec.payload_paths(), "sorted exact set")
	assert_eq(paths[0], "objects.json")
	assert_eq(m.created_with.godot, "4.7.2.stable.official.ed1daf0bf")
	var objs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("objects.json")))
	assert_eq(objs.objects[0].object_id, OBJ_A, "objects sorted by id")


func test_read_generation_round_trip() -> void:
	var doc := _doc()
	var dir := _gen(doc)
	var r := WorldCodec.read_generation(dir, _catalog)
	if not assert_empty_string(r[1], "read"):
		return
	var back: WorldDocument = r[0]
	assert_true(back != doc, "new document")
	assert_eq(CanonicalEncoder.authored_hash(back), CanonicalEncoder.authored_hash(doc), "authored hash")
	assert_eq(back.world_id, doc.world_id)
	assert_eq(back.document_revision, 7)
	assert_eq(back.sorted_object_ids(), doc.sorted_object_ids())
	for id in doc.sorted_object_ids():
		assert_true(back.get_object(id).equals(doc.get_object(id)), "object %s bit-exact" % id)
	for loc in WorldConstants.REGION_LOCATIONS:
		assert_eq(back.get_region(loc).height_bytes(), doc.get_region(loc).height_bytes(), "heights %s" % loc)
		assert_eq(back.get_region(loc).control_bytes(), doc.get_region(loc).control_bytes(), "control %s" % loc)


func test_read_rejects_invalid_content() -> void:
	var doc := _doc()
	doc.get_region(Vector2i(0, 0)).heights[3] = NAN
	var r := WorldCodec.read_generation(_gen(doc), _catalog)
	assert_eq(r[0], null)
	assert_error_contains(r[1], "height[3]", "NaN height (IO-09)")
	doc = _doc()
	doc.get_object(OBJ_A).uniform_scale = 9.0
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "uniform_scale", "invalid scale (IO-09)")
	assert_error_contains(WorldCodec.read_generation(_dir.path_join("missing"), _catalog)[1], "manifest")


func test_rejects_manifest_tampering() -> void:
	var cases := {
		"unknown format": func(m: Dictionary) -> void: m.format = "other",
		"unknown format ": func(m: Dictionary) -> void: m.format = 5,
		"unsupported schema_version 2": func(m: Dictionary) -> void: m.schema_version = 2,
		"unsupported schema_version 1.5": func(m: Dictionary) -> void: m.schema_version = 1.5,
		"missing field 'created_with'": func(m: Dictionary) -> void: m.erase("created_with"),
		"unknown field 'extra'": func(m: Dictionary) -> void: m["extra"] = 1,
		"world_id": func(m: Dictionary) -> void: m.world_id = String(m.world_id).to_upper(),
		"document_revision": func(m: Dictionary) -> void: m.document_revision = 2.5,
		"document_revision ": func(m: Dictionary) -> void: m.document_revision = -1,
		"created_with.godot": func(m: Dictionary) -> void: m.created_with.godot = "",
		"incompatible catalog": func(m: Dictionary) -> void: m.catalog.sha256 = "ab".repeat(32),
		"incompatible catalog ": func(m: Dictionary) -> void: m.catalog.version = 2,
		"catalog.sha256": func(m: Dictionary) -> void: m.catalog.sha256 = "<catalog content hash>",
		"sample_spacing_m": func(m: Dictionary) -> void: m.terrain.sample_spacing_m = 1.0,
		"region_samples": func(m: Dictionary) -> void: m.terrain.region_samples = 257,
		"region_locations": func(m: Dictionary) -> void: m.terrain.region_locations = [[0, 0], [0, -1], [-1, 0], [-1, -1]],
		"region_locations ": func(m: Dictionary) -> void: m.terrain.region_locations.pop_back(),
		"height_encoding": func(m: Dictionary) -> void: m.terrain.height_encoding = "uint16",
		"control_schema": func(m: Dictionary) -> void: m.terrain.control_schema = "terrain3d-2",
		"material_slots": func(m: Dictionary) -> void: m.terrain.material_slots = {"0": "dirt", "1": "grass"},
		"exactly the 9 payload files": func(m: Dictionary) -> void: m.payload_files.pop_back(),
		"exactly the 9 payload files ": func(m: Dictionary) -> void: m.payload_files.append(m.payload_files[0].duplicate()),
		"sorted by path": func(m: Dictionary) -> void: m.payload_files.reverse(),
		"placeholder": func(m: Dictionary) -> void: m.payload_files[1].sha256 = "<hex>",
		"placeholder ": func(m: Dictionary) -> void: m.payload_files[1].sha256 = "0".repeat(64),
		"missing field 'sha256'": func(m: Dictionary) -> void: m.payload_files[1].erase("sha256"),
		"sha256 does not match": func(m: Dictionary) -> void: m.payload_files[0].sha256 = "ab".repeat(32),
		"manifest says 1": func(m: Dictionary) -> void: m.payload_files[0].bytes = 1,
		"must be 262144 bytes": func(m: Dictionary) -> void: m.payload_files[2].bytes = 4,
		"authored_content_hash does not match": func(m: Dictionary) -> void: m.authored_content_hash = "ab".repeat(32),
		"authored_content_hash is missing": func(m: Dictionary) -> void: m.authored_content_hash = "TODO",
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


func test_rejects_payload_tampering() -> void:
	var dir := _gen()
	var f := FileAccess.open(dir.path_join("regions/r_0_0.control.u32le"), FileAccess.READ_WRITE)
	f.seek(100)
	f.store_8(0x55)
	f.close()
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "sha256 does not match")
	dir = _gen()
	DirAccess.remove_absolute(dir.path_join("regions/r_-1_0.height.f32le"))
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "r_-1_0.height")


func test_rejects_object_order_and_duplicates() -> void:
	var dir := _gen()
	var objs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("objects.json")))
	objs.objects.reverse()
	_replace_payload(dir, "objects.json", JSON.stringify(objs).to_utf8_buffer())
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "not sorted and unique", "unsorted")
	objs.objects.reverse()
	objs.objects[1] = objs.objects[0].duplicate(true)
	_replace_payload(dir, "objects.json", JSON.stringify(objs).to_utf8_buffer())
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "not sorted and unique", "duplicate id (IO-09)")
	objs.schema_version = 3
	_replace_payload(dir, "objects.json", JSON.stringify(objs).to_utf8_buffer())
	assert_error_contains(WorldCodec.read_generation(dir, _catalog)[1], "schema_version", "objects schema")


## A non-string enum value must reject the whole file (no script error, no partial load), even
## when the manifest hash matches the objects before the bad record.
func test_rejects_non_string_enum_fields_without_partial_load() -> void:
	var truncated := _doc()
	truncated.remove_object(OBJ_B)
	var truncated_hash := CanonicalEncoder.authored_hash(truncated)
	var cases := [["grounding", 5], ["grounding", 1.5], ["grounding", []], ["grounding", {}],
		["grounding", true], ["grounding", null], ["origin", 5], ["origin", ["MANUAL"]],
		["scatter_operation_id", 5], ["scatter_operation_id", []], ["scatter_operation_id", {}]]
	var base := _gen()
	for c in cases:
		var dir := _dir.path_join("t_" + StorageFs.random_hex(4))
		_copy_dir(base, dir)
		var objs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("objects.json")))
		objs.objects[1][c[0]] = c[1]  # OBJ_B, the second record
		_replace_payload(dir, "objects.json", JSON.stringify(objs).to_utf8_buffer())
		var m := _manifest(dir)
		m.authored_content_hash = truncated_hash
		_write_manifest(dir, m)
		var r := WorldCodec.read_generation(dir, _catalog)
		var label := "%s = %s" % [c[0], JSON.stringify(c[1])]
		assert_eq(r[0], null, label)
		assert_error_contains(r[1], c[0], label)


func test_write_reports_unwritable_directory() -> void:
	var blocker := _dir.path_join("file_not_dir")
	var f := FileAccess.open(blocker, FileAccess.WRITE)
	f.store_8(1)
	f.close()
	var err := WorldCodec.write_generation(blocker.path_join("gen"), _doc(), {})
	assert_error_contains(err, "cannot create directory")


func _copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to.path_join("regions"))
	for path in WorldCodec.payload_paths() + PackedStringArray(["manifest.json"]):
		DirAccess.copy_absolute(from.path_join(path), to.path_join(path))
