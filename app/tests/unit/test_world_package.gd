extends TestCase
## .worldpoc export -> import round trip (IO-01/IO-02 desktop half) and safe rejection.

var _catalog: AssetCatalog
var _dir := ""


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	# The shipped catalog has no scatter-capable asset yet; make spruce one for these tests.
	_catalog.get_asset("nature.tree.spruce_a").scatter_mesh = "res://assets/test_scatter_mesh.tres"
	_dir = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]
	DirAccess.make_dir_recursive_absolute(_dir)


func after_each() -> void:
	StorageFs.remove_tree(_dir)


func _doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(3.0, ControlCodec.grass_value())
	doc.document_revision = 12
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	for i in 20:
		doc.get_region(WorldConstants.REGION_LOCATIONS[i % 4]).heights[i * 997] = -0.0 if i == 0 else i * 0.013
		doc.get_region(WorldConstants.REGION_LOCATIONS[i % 4]).control[i * 131] = ControlCodec.encode_paint(0x7C, i * 12)
	doc.get_region(Vector2i(0, -1)).color[40] = 99
	doc.rules.rock_slope_deg = 41
	for i in 4:
		doc.scatter.add("nature.tree.spruce_a", 1, i * 3.1 - 5.0, 0.7 * i, 0.3 * i, 0.6 + 0.1 * i, i % 2)
	var path := PathRecord.new()
	path.path_id = ObjectRecord.new_uuid_v4()
	path.width_m = 3.3
	path.points = PackedVector2Array([Vector2(-4.4, 1.1), Vector2(6.6, 9.9)])
	doc.put_path(path)
	for i in 5:
		var r := ObjectRecord.new()
		r.object_id = ObjectRecord.new_uuid_v4()
		r.asset_id = ["nature.tree.spruce_a", "nature.rock.boulder_a", "built.lodge.cabin_a"][i % 3]
		r.asset_version = 1
		r.set_position(i * 17.123456789 - 60.0, 3.0 + i * 0.1, 0.1 * i - 0.3)
		r.set_yaw(i * 0.7)
		r.uniform_scale = 0.75 + i * 0.1
		r.height_offset_m = 0.1 * i
		doc.put_object(r)
	return doc


func _gen(doc: WorldDocument) -> String:
	var dir := _dir.path_join("gen")
	assert_empty_string(WorldCodec.write_generation(dir, doc, WorldCodec.default_created_with()), "write")
	return dir


## Per-test extraction root: user:// is shared with concurrently running sandboxes.
func _tmp_root() -> String:
	return _dir.path_join("import_tmp")


func _import_tmp_count() -> int:
	var d := DirAccess.open(_tmp_root())
	return 0 if d == null else d.get_directories().size() + d.get_files().size()


func test_export_import_round_trip() -> void:
	var doc := _doc()
	var out := _dir.path_join("exports/world.worldpoc")
	if not assert_empty_string(WorldPackage.export_package(_gen(doc), out, _catalog), "export"):
		return
	assert_false(FileAccess.file_exists(out + ".partial"), "no partial left")
	var info := ZipInspector.inspect(out)
	assert_true(info.ok, str(info.error))
	var names: Array = []
	for e in info.entries:
		if not e.is_dir:
			names.append(e.name)
	var expected: Array = ["manifest.json"]
	expected.append_array(Array(WorldCodec.payload_paths()))
	assert_eq(names, expected, "fixed entry order")
	var before := _import_tmp_count()
	var r := WorldPackage.import_package(out, _catalog, _tmp_root())
	if not assert_empty_string(r[1], "import"):
		return
	var back: WorldDocument = r[0]
	assert_eq(CanonicalEncoder.authored_hash(back), CanonicalEncoder.authored_hash(doc), "authored hash")
	assert_eq(back.sorted_object_ids(), doc.sorted_object_ids(), "object ids")
	for id in doc.sorted_object_ids():
		var a := doc.get_object(id)
		var b := back.get_object(id)
		for k in 3:
			assert_eq(ObjectRecord.f64_hex(b.position[k]), ObjectRecord.f64_hex(a.position[k]), "position bits")
		for k in 4:
			assert_eq(ObjectRecord.f64_hex(b.rotation_xyzw[k]), ObjectRecord.f64_hex(a.rotation_xyzw[k]), "rotation bits")
		assert_eq(ObjectRecord.f64_hex(b.uniform_scale), ObjectRecord.f64_hex(a.uniform_scale), "scale bits")
		assert_eq(ObjectRecord.f64_hex(b.height_offset_m), ObjectRecord.f64_hex(a.height_offset_m), "offset bits")
	for loc in WorldConstants.REGION_LOCATIONS:
		assert_eq(back.get_region(loc).height_bytes(), doc.get_region(loc).height_bytes(), "heights %s" % loc)
		assert_eq(back.get_region(loc).control_bytes(), doc.get_region(loc).control_bytes(), "control %s" % loc)
		assert_eq(back.get_region(loc).color_bytes(), doc.get_region(loc).color_bytes(), "color %s" % loc)
	assert_true(back.scatter.equals(doc.scatter) and back.scatter.count() == 4, "scatter")
	assert_true(back.rules.equals(doc.rules), "rules")
	for id in doc.sorted_path_ids():
		assert_true(back.get_path_record(id).equals(doc.get_path_record(id)), "path")
	assert_eq(_import_tmp_count(), before, "temporary import directory removed")


func test_export_without_catalog_verifies_hashes() -> void:
	var out := _dir.path_join("plain.worldpoc")
	assert_empty_string(WorldPackage.export_package(_gen(_doc()), out))
	assert_true(FileAccess.file_exists(out))


func test_export_refuses_invalid_generation() -> void:
	var gen := _gen(_doc())
	DirAccess.remove_absolute(gen.path_join("objects.json"))
	var out := _dir.path_join("bad.worldpoc")
	assert_error_contains(WorldPackage.export_package(gen, out, _catalog), "cannot export invalid generation")
	assert_false(FileAccess.file_exists(out))


func test_import_rejects_malicious_package_before_extraction() -> void:
	var path := _dir.path_join("evil.worldpoc")
	ZipTestBuilder.valid_layout().add("../../escape.txt", "x".to_utf8_buffer()).save(path)
	var before := _import_tmp_count()
	var r := WorldPackage.import_package(path, _catalog, _tmp_root())
	assert_eq(r[0], null)
	assert_error_contains(r[1], "package rejected")
	assert_error_contains(r[1], "'..' path segment")
	assert_eq(_import_tmp_count(), before, "nothing extracted")
	# Extraction happens in <tmp_root>/<random>/, so '../../escape.txt' would land in _dir.
	assert_false(FileAccess.file_exists(_dir.path_join("escape.txt")), "no escape")
	assert_false(FileAccess.file_exists(_tmp_root().path_join("escape.txt")), "no escape")


func test_import_rejects_wrong_catalog() -> void:
	var other := _doc()
	other.catalog_sha256 = "cd".repeat(32)
	var out := _dir.path_join("other.worldpoc")
	assert_empty_string(WorldPackage.export_package(_gen(other), out))
	var package_bytes := FileAccess.get_file_as_bytes(out)
	var before := _import_tmp_count()
	var r := WorldPackage.import_package(out, _catalog, _tmp_root())
	assert_eq(r[0], null, "IO-07 rejection")
	assert_error_contains(r[1], "incompatible catalog")
	assert_eq(FileAccess.get_file_as_bytes(out), package_bytes, "package left as it was")
	assert_eq(_import_tmp_count(), before, "temporary import directory removed on failure")


## A real export with a second, oversized directory hidden in its comment (the directory
## ZIPReader would use) is rejected by inspection, before any decompression.
func test_import_rejects_directory_hidden_in_comment() -> void:
	var out := _dir.path_join("real.worldpoc")
	if not assert_empty_string(WorldPackage.export_package(_gen(_doc()), out), "export"):
		return
	var real := FileAccess.get_file_as_bytes(out)
	for inner_comment_len in [5, 0]:
		var evil := _dir.path_join("hidden_%d.worldpoc" % inner_comment_len)
		var f := FileAccess.open(evil, FileAccess.WRITE)
		f.store_buffer(ZipTestBuilder.hide_directory_in_comment(real, "objects.json", 5 * 1024 * 1024, inner_comment_len))
		f.close()
		var r := WorldPackage.import_package(evil, _catalog, _tmp_root())
		assert_eq(r[0], null)
		# Inner length 0: the hidden directory is the one inspected; its size disagrees with the
		# entry's local header, so it is rejected before the size limits are even reached.
		var expected := "comments are not allowed" if inner_comment_len != 0 \
			else "'objects.json' local header CRC or sizes differ"
		assert_error_contains(r[1], expected, "inner comment length %d" % inner_comment_len)
		assert_eq(_import_tmp_count(), 0, "nothing extracted")


## Inspection passes (CRC is not in the directory); extraction then fails the CRC check and the
## post-decompression size check rejects the entry.
func test_import_rejects_entry_whose_extracted_size_differs() -> void:
	allow_logged_errors()  # ZIPReader logs the CRC error it hits
	var path := _dir.path_join("bad_crc.worldpoc")
	ZipTestBuilder.valid_layout().save(path)
	assert_true(ZipInspector.inspect(path).ok, "central directory alone looks valid")
	var r := WorldPackage.import_package(path, _catalog, _tmp_root())
	assert_eq(r[0], null)
	assert_error_contains(r[1], "'manifest.json' decompressed to 0 bytes, central directory says 2")
	assert_eq(_import_tmp_count(), 0, "temporary import directory removed")


func test_import_rejects_non_zip() -> void:
	var path := _dir.path_join("junk.worldpoc")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("PK but not really")
	f.close()
	assert_error_contains(WorldPackage.import_package(path, _catalog)[1], "not a ZIP")
