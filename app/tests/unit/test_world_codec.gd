extends TestCase
## Generation directory write/read: byte-exact payloads, strict manifest, authored hash.

const OBJ_A := "11111111-1111-4111-8111-111111111111"
const OBJ_B := "22222222-2222-4222-8222-222222222222"
const PATH_A := "33333333-3333-4333-8333-333333333333"
const PATH_B := "44444444-4444-4444-8444-444444444444"
const SPRUCE := "nature.tree.spruce_a"

var _catalog: AssetCatalog
var _dir := ""


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	# The shipped catalog has no scatter-capable asset yet; make spruce one for these tests.
	_catalog.get_asset(SPRUCE).scatter_mesh = "res://assets/test_scatter_mesh.tres"
	_dir = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]
	DirAccess.make_dir_recursive_absolute(_dir)


func after_each() -> void:
	StorageFs.remove_tree(_dir)


func _doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(1.0, ControlCodec.grass_value(), null, _catalog)
	doc.document_revision = 7
	var r := doc.get_region(Vector2i(-1, -1))
	r.heights[0] = -0.0
	r.heights[1] = 1e-38
	r.heights[2] = 1.4e-45  # smallest float32 denormal
	r.heights[3] = WorldConstants.HEIGHT_MAX
	r.heights[65535] = WorldConstants.HEIGHT_MIN
	doc.get_region(Vector2i(0, 0)).control[9] = ControlCodec.encode_paint(0x78, 200)
	doc.get_region(Vector2i(0, 0)).control[10] = (3 << 27) | (2 << 22) | (77 << 14) | 1
	var col := doc.get_region(Vector2i(-1, 0)).color
	col[0] = 12
	col[1] = 34
	col[2] = 56
	col[3] = 255
	col[col.size() - 1] = 7
	doc.get_region(Vector2i(-1, 0)).color = col
	doc.rules.rock_enabled = false
	doc.rules.rock_slope_deg = 45
	doc.rules.sand_height_dm = 12
	var spruce := doc.assets.bundled_binding_for(SPRUCE)
	doc.scatter.add(spruce, 1.5, -2.25, 1.0, 1.25, 1)
	doc.scatter.add(spruce, -128.0, 127.5, -3.1416, 0.5, 0)
	var pa := PathRecord.new()
	pa.path_id = PATH_B
	pa.width_m = 2.5
	pa.points = PackedVector2Array([Vector2(-10, -10), Vector2(0, 5.5), Vector2(10, 20)])
	doc.put_path(pa)
	var pb := PathRecord.new()
	pb.path_id = PATH_A
	pb.width_m = 1.0
	pb.points = PackedVector2Array([Vector2(1, 1), Vector2(2, 2)])
	doc.put_path(pb)
	var a := ObjectRecord.new()
	a.object_id = OBJ_B
	a.binding_id = spruce
	a.set_position(0.1, 1.0, 1.0 / 3.0)
	a.set_yaw(deg_to_rad(33.0))
	a.uniform_scale = 1.1
	a.origin = WorldConstants.ORIGIN_SCATTER
	a.scatter_operation_id = ObjectRecord.new_uuid_v4()
	doc.put_object(a)
	var b := ObjectRecord.new()
	b.object_id = OBJ_A
	b.binding_id = doc.assets.bundled_binding_for("built.lodge.cabin_a")
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


func test_created_with_is_never_empty_in_a_project_without_an_application_version() -> void:
	var saved: Variant = ProjectSettings.get_setting("application/config/version")
	ProjectSettings.set_setting("application/config/version", "")
	var cw := WorldCodec.default_created_with()
	ProjectSettings.set_setting("application/config/version", saved)
	for k: String in WorldCodec.CREATED_WITH_KEYS:
		assert_true(str(cw[k]) != "", "created_with.%s is non-empty" % k)
	assert_eq(cw.world_painter, "unknown", "the documented fallback")
	assert_eq(ProjectSettings.get_setting("application/config/version"), saved, "setting restored")


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
	for path in WorldCodec.payload_paths(WorldLayout.legacy()):
		assert_eq(v.files[path], snap.files[path], "bytes of %s" % path)
	var back := RegionBuffers.new(Vector2i(0, -1))
	back.set_from_bytes(v.files["regions/r_0_-1.height.f32le"], v.files["regions/r_0_-1.control.u32le"],
		v.files["regions/r_0_-1.color.rgba8"])
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
	assert_eq(m.keys().size(), WorldCodec.MANIFEST_KEYS_V4.size())
	assert_eq(m.format, "world-painter-poc")
	assert_eq(m.document_revision, 7.0)
	assert_eq(m.terrain.region_locations, [[-1.0, -1.0], [0.0, -1.0], [-1.0, 0.0], [0.0, 0.0]])
	var paths: Array = []
	for e in m.payload_files:
		paths.append(e.path)
		var bytes := FileAccess.get_file_as_bytes(dir.path_join(e.path))
		assert_eq(int(e.bytes), bytes.size(), "size " + e.path)
		assert_eq(e.sha256, CanonicalEncoder.sha256_hex(bytes), "hash " + e.path)
	assert_eq(PackedStringArray(paths), WorldCodec.payload_paths(WorldLayout.legacy()), "sorted exact set")
	assert_eq(paths.size(), 16)
	assert_eq(paths[0], "asset_locks.json")
	assert_eq(paths[1], "objects.json")
	assert_eq(paths[2], "paths.bin")
	assert_eq(paths[15], "scatter.bin")
	assert_eq(m.asset_lock, {"path": "asset_locks.json", "sha256": CanonicalEncoder.sha256_hex(
		FileAccess.get_file_as_bytes(dir.path_join("asset_locks.json")))})
	assert_false(m.has("catalog"), "schema 4 has no catalog block")
	assert_eq(m.terrain.layout, {"min_region": [-1.0, -1.0], "region_count": [2.0, 2.0]}, "layout always present")
	assert_eq(m.terrain.color_encoding, "rgba8-tint-v1")
	assert_eq(m.terrain.control_schema, "terrain3d-1.0.2-control-v2")
	assert_eq(m.terrain.rules, {"rock_enabled": false, "rock_slope_deg": 45.0, "sand_enabled": true, "sand_height_dm": 12.0})
	assert_eq(m.schema_version, 4.0)
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
	for loc in WorldLayout.legacy().region_locations():
		assert_eq(back.get_region(loc).height_bytes(), doc.get_region(loc).height_bytes(), "heights %s" % loc)
		assert_eq(back.get_region(loc).control_bytes(), doc.get_region(loc).control_bytes(), "control %s" % loc)
		assert_eq(back.get_region(loc).color_bytes(), doc.get_region(loc).color_bytes(), "color %s" % loc)
	assert_true(back.rules.equals(doc.rules), "rules")
	assert_false(back.rules.equals(TerrainRules.defaults()), "non-default rules survived")
	assert_true(back.scatter.equals(doc.scatter), "scatter")
	assert_eq(back.scatter.count(), 2)
	assert_eq(back.sorted_path_ids(), doc.sorted_path_ids())
	for id in doc.sorted_path_ids():
		assert_true(back.get_path_record(id).equals(doc.get_path_record(id)), "path %s" % id)
	assert_eq(back.get_color_at_sample(-256, 0), (12 << 24) | (34 << 16) | (56 << 8) | 255, "tint sample")


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
		"unsupported schema_version 1": func(m: Dictionary) -> void: m.schema_version = 1,
		"unsupported schema_version 5": func(m: Dictionary) -> void: m.schema_version = 5,
		"unsupported schema_version 1.5": func(m: Dictionary) -> void: m.schema_version = 1.5,
		"missing field 'created_with'": func(m: Dictionary) -> void: m.erase("created_with"),
		"unknown field 'extra'": func(m: Dictionary) -> void: m["extra"] = 1,
		"world_id": func(m: Dictionary) -> void: m.world_id = String(m.world_id).to_upper(),
		"document_revision": func(m: Dictionary) -> void: m.document_revision = 2.5,
		"document_revision ": func(m: Dictionary) -> void: m.document_revision = -1,
		"created_with.godot": func(m: Dictionary) -> void: m.created_with.godot = "",
		"missing field 'asset_lock'": func(m: Dictionary) -> void: m.erase("asset_lock"),
		"unknown field 'catalog'": func(m: Dictionary) -> void: m["catalog"] = {"id": "poc_nature", "version": 2, "sha256": "ab".repeat(32)},
		"asset_lock.path": func(m: Dictionary) -> void: m.asset_lock.path = "locks.json",
		"asset_lock sha256 differs": func(m: Dictionary) -> void: m.asset_lock.sha256 = "ab".repeat(32),
		"asset_lock.sha256 is missing": func(m: Dictionary) -> void: m.asset_lock.sha256 = "<lock hash>",
		"asset_lock has unknown field": func(m: Dictionary) -> void: m.asset_lock["extra"] = 1,
		"missing field 'layout'": func(m: Dictionary) -> void: m.terrain.erase("layout"),
		"sample_spacing_m": func(m: Dictionary) -> void: m.terrain.sample_spacing_m = 1.0,
		"region_samples": func(m: Dictionary) -> void: m.terrain.region_samples = 257,
		"region_locations": func(m: Dictionary) -> void: m.terrain.region_locations = [[0, 0], [0, -1], [-1, 0], [-1, -1]],
		"region_locations ": func(m: Dictionary) -> void: m.terrain.region_locations.pop_back(),
		"height_encoding": func(m: Dictionary) -> void: m.terrain.height_encoding = "uint16",
		"control_schema": func(m: Dictionary) -> void: m.terrain.control_schema = "terrain3d-2",
		"color_encoding": func(m: Dictionary) -> void: m.terrain.color_encoding = "rgb8",
		"material_slots": func(m: Dictionary) -> void: m.terrain.material_slots = {"0": "dirt", "1": "grass"},
		"material_slots ": func(m: Dictionary) -> void: m.terrain.material_slots = {"0": "grass", "1": "dirt"},
		"missing field 'rules'": func(m: Dictionary) -> void: m.terrain.erase("rules"),
		"rules missing field 'sand_enabled'": func(m: Dictionary) -> void: m.terrain.rules.erase("sand_enabled"),
		"rules has unknown field": func(m: Dictionary) -> void: m.terrain.rules["extra"] = 1,
		"must be a boolean": func(m: Dictionary) -> void: m.terrain.rules.rock_enabled = 1,
		"must be a boolean ": func(m: Dictionary) -> void: m.terrain.rules.sand_enabled = "true",
		"rock_slope_deg must be an integer": func(m: Dictionary) -> void: m.terrain.rules.rock_slope_deg = 30.5,
		"sand_height_dm must be an integer": func(m: Dictionary) -> void: m.terrain.rules.sand_height_dm = "-4",
		"rock_slope_deg 9 outside": func(m: Dictionary) -> void: m.terrain.rules.rock_slope_deg = 9,
		"rock_slope_deg 61 outside": func(m: Dictionary) -> void: m.terrain.rules.rock_slope_deg = 61,
		"sand_height_dm -31 outside": func(m: Dictionary) -> void: m.terrain.rules.sand_height_dm = -31,
		"sand_height_dm 31 outside": func(m: Dictionary) -> void: m.terrain.rules.sand_height_dm = 31,
		"rules must be an object": func(m: Dictionary) -> void: m.terrain.rules = [],
		"exactly the 16 payload files": func(m: Dictionary) -> void: m.payload_files.pop_back(),
		"exactly the 16 payload files ": func(m: Dictionary) -> void: m.payload_files.append(m.payload_files[0].duplicate()),
		"sorted by path": func(m: Dictionary) -> void: m.payload_files.reverse(),
		"placeholder": func(m: Dictionary) -> void: m.payload_files[1].sha256 = "<hex>",
		"placeholder ": func(m: Dictionary) -> void: m.payload_files[1].sha256 = "0".repeat(64),
		"missing field 'sha256'": func(m: Dictionary) -> void: m.payload_files[1].erase("sha256"),
		"sha256 does not match": func(m: Dictionary) -> void: m.payload_files[1].sha256 = "ab".repeat(32),
		"manifest says 1": func(m: Dictionary) -> void: m.payload_files[1].bytes = 1,
		"must be 262144 bytes": func(m: Dictionary) -> void: m.payload_files[3].bytes = 4,
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


func test_rejects_scatter_and_path_payload_damage() -> void:
	var base := _gen()
	var scatter: PackedByteArray = FileAccess.get_file_as_bytes(base.path_join("scatter.bin"))
	var pathbin: PackedByteArray = FileAccess.get_file_as_bytes(base.path_join("paths.bin"))
	var bad_scatter := scatter.duplicate()
	bad_scatter.append(0)
	var bad_magic := scatter.duplicate()
	bad_magic[0] = 0x58
	var bad_paths := pathbin.duplicate()
	bad_paths.append(0)
	var cases := [
		["scatter.bin", bad_scatter, "trailing"],
		["scatter.bin", bad_magic, "bad magic"],
		["paths.bin", bad_paths, "trailing"],
		["paths.bin", pathbin.slice(0, 20), "truncated"],
	]
	for c in cases:
		var dir := _dir.path_join("t_" + StorageFs.random_hex(4))
		_copy_dir(base, dir)
		_replace_payload(dir, c[0], c[1])
		var r := WorldCodec.read_generation(dir, _catalog)
		assert_eq(r[0], null, "%s %s" % [c[0], c[2]])
		assert_error_contains(r[1], c[2], "%s %s" % [c[0], c[2]])


func test_semantic_scatter_and_path_errors_reach_the_reader() -> void:
	var doc := _doc()
	doc.scatter.scale[0] = 9.0
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "scale", "scatter scale")
	doc = _doc()
	doc.scatter.x[1] = 128.0
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "extent", "scatter extent")
	doc = _doc()
	doc.get_path_record(PATH_A).points[1] = Vector2(500, 0)
	assert_error_contains(WorldCodec.read_generation(_gen(doc), _catalog)[1], "extent", "path extent")


func test_unknown_scatter_asset_is_rejected_on_read() -> void:
	var dir := _gen()
	var plain := _catalog.to_plain()
	plain.assets[SPRUCE].scatter_allowed = false
	var no_scatter := AssetCatalog.from_plain(plain)
	assert_error_contains(WorldCodec.read_generation(dir, no_scatter)[1], "scatter_allowed", "catalog forbids scatter")
	assert_true(no_scatter.get_asset(SPRUCE) != null)


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
	for path in WorldCodec.payload_paths(WorldLayout.legacy()) + PackedStringArray(["manifest.json"]):
		DirAccess.copy_absolute(from.path_join(path), to.path_join(path))
