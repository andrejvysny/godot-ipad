extends TestCase
## Sample-grid mapping (TE-08), bilinear sampling, and authored-hash invariants.

const BINDING := "b11111111111111111111111111111111"


func _ramp_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			for i in WorldConstants.REGION_SAMPLES:
				var gx: int = loc.x * 256 + i
				var gz: int = loc.y * 256 + j
				r.heights[j * 256 + i] = gx * 0.01 + gz * 0.001
	return doc


func test_negative_coordinates_use_floor() -> void:
	assert_eq(WorldConstants.sample_region(-1), -1, "g=-1 region")
	assert_eq(WorldConstants.sample_local(-1), 255, "g=-1 local")
	assert_eq(WorldConstants.sample_region(-256), -1)
	assert_eq(WorldConstants.sample_region(-257), -2)
	assert_eq(WorldConstants.sample_region(255), 0)
	assert_eq(WorldConstants.sample_local(-256), 0)


func test_bilinear_matches_ramp_including_seams() -> void:
	var doc := _ramp_doc()
	for x in [-128.0, -127.75, -0.5, -0.25, 0.0, 0.1, 0.25, 63.9, 127.5]:
		for z in [-128.0, -0.25, 0.0, 17.3, 127.5]:
			var expected: float = (x / 0.5) * 0.01 + (z / 0.5) * 0.001
			assert_near(doc.sample_height(x, z), expected, 1e-5, "h(%s,%s)" % [x, z])


func test_outside_extent_is_nan_not_zero() -> void:
	var doc := _ramp_doc()
	for p in [Vector2(127.75, 0), Vector2(128, 0), Vector2(-128.25, 0), Vector2(0, 200), Vector2(0, -129)]:
		assert_true(is_nan(doc.sample_height(p.x, p.y)), "outside %s" % p)
	assert_true(is_nan(doc.sample_normal(500, 0).x), "normal outside")


func test_height_range_invalidation() -> void:
	var doc := WorldDocument.create_flat(1.0, 0)
	assert_eq(doc.height_range(), Vector2(1, 1))
	doc.get_region(Vector2i(0, 0)).heights[5] = 9.0
	doc.invalidate_height_range(Vector2i(0, 0))
	assert_eq(doc.height_range(), Vector2(1, 9))


func test_authored_hash_ignores_world_id_and_revision() -> void:
	var a := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var b := a.duplicate_deep()
	b.world_id = ObjectRecord.new_uuid_v4()
	b.document_revision = 42
	assert_eq(CanonicalEncoder.authored_hash(a), CanonicalEncoder.authored_hash(b))
	b.get_region(Vector2i(-1, 0)).control[3] = ControlCodec.encode_paint(0, 1)
	assert_ne(CanonicalEncoder.authored_hash(a), CanonicalEncoder.authored_hash(b), "control change alters hash")


func test_authored_hash_negative_zero_is_canonical() -> void:
	var a := WorldDocument.create_flat(0.0, 0, null, AssetCatalog.load_from()[0])
	var r := ObjectRecord.new()
	r.object_id = "00000000-0000-4000-8000-000000000001"
	r.binding_id = a.assets.bundled_binding_for("nature.rock.boulder_a")
	r.set_position(0.0, 0.0, 0.0)
	a.put_object(r)
	var b := a.duplicate_deep()
	b.get_object(r.object_id).set_position(-0.0, 0.0, -0.0)
	assert_eq(CanonicalEncoder.authored_hash(a), CanonicalEncoder.authored_hash(b))


func test_object_record_round_trip_and_rejections() -> void:
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.binding_id = BINDING
	r.set_position(12.5, 4.25, -7.0)
	r.set_yaw(deg_to_rad(30.0))
	var json := JSON.stringify(r.to_dict(), "", true, true)
	var parsed: Array = ObjectRecord.from_dict(JSON.parse_string(json))
	assert_empty_string(parsed[1])
	assert_true(parsed[0].equals(r), "exact JSON round trip")
	assert_near(parsed[0].get_yaw(), deg_to_rad(30.0), 1e-12, "yaw")
	var bad := r.to_dict()
	bad.uniform_scale = 0.0
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "uniform_scale")
	bad = r.to_dict()
	bad.position = [1.0, NAN, 2.0]
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "position")
	bad = r.to_dict()
	bad.grounding = "FLOATING"
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "grounding")
	bad = r.to_dict()
	bad.object_id = "not-a-uuid"
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "object_id")
	bad = r.to_dict()
	bad.binding_id = "nature.tree.spruce_a"
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "binding_id")
	bad = r.to_dict()
	bad["asset_id"] = "nature.tree.spruce_a"
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "unknown field", "schema 4 records are exact")
	bad = r.to_dict()
	bad.f64le.position[0] = ObjectRecord.f64_hex(13.5)
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "f64le", "bits disagreeing with decimal")
	bad = r.to_dict()
	bad.erase("f64le")
	assert_error_contains(ObjectRecord.from_dict(bad)[1], "f64le", "missing exact block")


## Godot 4.7's JSON parser is not correctly rounded; exact bits must win (ADR 0003).
func test_exact_bits_survive_where_decimal_parse_is_lossy() -> void:
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.binding_id = BINDING
	r.set_yaw(deg_to_rad(30.0))  # cos(15°) is a known lossy decimal for Godot's parser
	var parsed: Array = ObjectRecord.from_dict(JSON.parse_string(JSON.stringify(r.to_dict(), "", true, true)))
	assert_eq(parsed[0].rotation_xyzw[3], r.rotation_xyzw[3], "bit-exact w")
	assert_eq(ObjectRecord.f64_hex(0.1), "9a9999999999b93f", "known little-endian vector")


func test_node_transform_applies_anchor_after_rotation_and_scale() -> void:
	var r := ObjectRecord.new()
	r.set_position(10.0, 2.0, -3.0)
	r.set_yaw(PI / 2.0)
	r.uniform_scale = 2.0
	var anchor := Vector3(1.0, -0.5, 0.0)
	var t := r.node_transform(anchor)
	# The anchor point, transformed by the node transform, must land exactly on `position`.
	assert_vec_near(t * anchor, Vector3(10.0, 2.0, -3.0), 1e-5, "anchor lands on position")


func test_holes_have_no_surface_without_changing_raw_bytes() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	for loc in WorldLayout.legacy().region_locations():
		var region := doc.get_region(loc)
		region.control[255 * 256 + 255] |= ControlCodec.HOLE_BIT
		var gx: int = loc.x * 256 + 255
		var gz: int = loc.y * 256 + 255
		var x := gx * 0.5
		var z := gz * 0.5
		var before := CanonicalEncoder.authored_hash(doc)
		assert_true(is_nan(doc.sample_height(x, z)), "hole sample")
		if x < 127.5:
			assert_true(is_nan(doc.sample_height(x + 0.1, z)), "hole cell interior")
			assert_eq(doc.sample_height(x + 0.5, z), 0.0, "next control cell has surface")
		assert_false(TerrainPicker.raycast(doc, Vector3(x, 10, z), Vector3.DOWN).ok, "no hole pick")
		assert_eq(doc.get_height_at_sample(gx, gz), 0.0, "raw height remains authored")
		assert_eq(CanonicalEncoder.authored_hash(doc), before, "sampling preserves payload")


func test_object_enums_reject_wrong_types_without_script_errors() -> void:
	var record := ObjectRecord.new()
	record.object_id = ObjectRecord.new_uuid_v4()
	record.binding_id = BINDING
	for field in ["grounding", "origin"]:
		for value in [null, 1, true, [], {}]:
			var data := record.to_dict()
			data[field] = value
			assert_error_contains(ObjectRecord.from_dict(data)[1], field)
	assert_true(ObjectRecord.is_uuid(record.object_id))
	assert_false(ObjectRecord.is_uuid("bad"))


func test_fixture_authored_hash_matches_manifest_in_godot() -> void:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	for name in ["flat", "gentle_hills", "stress_100"]:
		var path: String = "res://fixtures/" + name
		var loaded := WorldCodec.read_generation(path, catalog)
		assert_empty_string(loaded[1])
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path + "/manifest.json"))
		assert_eq(CanonicalEncoder.legacy_authored_hash(loaded[0])[0], manifest.authored_content_hash)


## WORLD-01: legacy fixtures keep the hashes recorded in config/toolchain.lock.json, read as schema 2 on the
## legacy layout, and re-writing them as schema 2 reproduces every binary payload byte for byte.
func test_legacy_fixtures_keep_recorded_hashes_and_bytes() -> void:
	var recorded := {
		"flat": "bedce13a23c1190c8cf01b9c3666a7dc7d2c728c1d85504af34baa84f382279b",
		"gentle_hills": "133d5013176873deba05b98c45109fed36e6c3ddbe370627043a6e9e77034934",
	}
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var out := "user://wp_storage_tests/legacy_bytes_%s" % StorageFs.random_hex(4)
	for name in recorded:
		var path: String = "res://fixtures/" + name
		var loaded := WorldCodec.read_generation(path, catalog)
		assert_empty_string(loaded[1], name)
		var doc: WorldDocument = loaded[0]
		assert_true(doc.layout.is_legacy() and doc.source_schema == 2 and doc.schema_version == 4, name)
		assert_eq(CanonicalEncoder.legacy_authored_hash(doc)[0], recorded[name], name)
		assert_eq(CanonicalEncoder.legacy_authored_bytes(doc)[0].slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V2\n")
		assert_eq(CanonicalEncoder.authored_bytes(doc).slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V4\n")
		var dir := out.path_join(name)
		assert_empty_string(LegacyWorldWriter.write(dir, doc), name)
		for file in WorldCodec.payload_paths(WorldLayout.legacy(), 2):
			if file == "objects.json":
				continue  # fixtures are written by Python with other JSON whitespace; the content is hashed above
			assert_eq(FileAccess.get_file_as_bytes(dir.path_join(file)),
				FileAccess.get_file_as_bytes(path.path_join(file)), "%s/%s" % [name, file])
	StorageFs.remove_tree(out)


## Schema 2 fixture -> in-memory bindings -> schema 4 files -> read back: terrain bytes, rules, paths, object
## IDs and transform bits and scatter order/records are unchanged (ADR 0014 D9).
func test_fixture_conversion_to_schema_4_preserves_content() -> void:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var out := "user://wp_storage_tests/convert_%s" % StorageFs.random_hex(4)
	for name in ["gentle_hills", "stress_100"]:
		var old: WorldDocument = WorldCodec.read_generation("res://fixtures/" + name, catalog)[0]
		var dir := out.path_join(name)
		assert_empty_string(WorldCodec.write_generation(dir, old, WorldCodec.default_created_with()), name)
		var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("manifest.json")))
		assert_eq(m.schema_version, 4.0, name)
		var back_result := WorldCodec.read_generation(dir, catalog)
		assert_empty_string(back_result[1], name)
		var back: WorldDocument = back_result[0]
		assert_eq(back.source_schema, 4)
		for loc in old.layout.region_locations():
			assert_eq(back.get_region(loc).height_bytes(), old.get_region(loc).height_bytes(), "%s heights %s" % [name, loc])
			assert_eq(back.get_region(loc).control_bytes(), old.get_region(loc).control_bytes(), "%s control %s" % [name, loc])
			assert_eq(back.get_region(loc).color_bytes(), old.get_region(loc).color_bytes(), "%s color %s" % [name, loc])
		assert_true(back.rules.equals(old.rules), name)
		assert_eq(PathRecord.encode_all(back.paths), PathRecord.encode_all(old.paths), name)
		assert_eq(back.sorted_object_ids(), old.sorted_object_ids(), name)
		for id in old.sorted_object_ids():
			var a := old.get_object(id)
			var b := back.get_object(id)
			assert_eq(b.binding_id, a.binding_id, "%s %s binding" % [name, id])
			assert_eq(ObjectRecord.f64_hex(b.position[0]) + ObjectRecord.f64_hex(b.rotation_xyzw[3]),
				ObjectRecord.f64_hex(a.position[0]) + ObjectRecord.f64_hex(a.rotation_xyzw[3]), "%s %s bits" % [name, id])
			assert_true(a.equals(b), "%s %s" % [name, id])
		assert_true(back.scatter.equals(old.scatter), "%s scatter order and records" % name)
		assert_eq(back.scatter.x, old.scatter.x)
		assert_eq(back.scatter.scale, old.scatter.scale)
	StorageFs.remove_tree(out)


func test_stress_100_fixture_loads_valid_and_grounded() -> void:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var loaded := WorldCodec.read_generation("res://fixtures/stress_100", catalog)
	assert_empty_string(loaded[1])
	var doc: WorldDocument = loaded[0]
	assert_eq(doc.objects.size(), 100)
	assert_eq(WorldValidator.validate(doc, catalog).size(), 0)
	assert_eq(WorldValidator.grounding_report(doc, catalog).size(), 0)
