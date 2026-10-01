extends TestCase
## IO-08: malicious archives are rejected from the central directory, before extraction.

const REGION := "regions/r_0_0.height.f32le"


func _inspect(b: ZipTestBuilder, archive: Dictionary = {}) -> Dictionary:
	return ZipInspector.inspect_bytes(b.build(archive), ZipInspector.default_limits())


func _expect(b: ZipTestBuilder, needle: String, archive: Dictionary = {}) -> void:
	var r := _inspect(b, archive)
	assert_false(r.ok, "expected rejection: " + needle)
	assert_error_contains(r.error, needle, needle)
	assert_eq(r.entries, [], "no entries on rejection")


func _region() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(WorldConstants.REGION_MAP_BYTES)
	return b


func test_valid_layout_passes() -> void:
	var r := _inspect(ZipTestBuilder.valid_layout())
	assert_true(r.ok, str(r.error))
	assert_eq(r.entries.size(), 11)
	var names: Array = []
	for e in r.entries:
		names.append(e.name)
	assert_true(names.has("regions/"), "dir entry tolerated")
	assert_eq(r.entries[0].method, 0)
	assert_eq(r.entries[3].uncompressed, WorldConstants.REGION_MAP_BYTES)


func test_rejects_unsafe_names() -> void:
	_expect(ZipTestBuilder.valid_layout().add("../evil.json"), "'..' path segment")
	_expect(ZipTestBuilder.valid_layout().add("regions/../../x"), "'..' path segment")
	_expect(ZipTestBuilder.valid_layout().add("/etc/passwd"), "absolute")
	_expect(ZipTestBuilder.valid_layout().add("C:/x.json"), "absolute")
	_expect(ZipTestBuilder.valid_layout().add("regions\\r_0_0.height.f32le"), "absolute or non-portable")
	_expect(ZipTestBuilder.valid_layout().add("regions//x"), "path segment")
	_expect(ZipTestBuilder.valid_layout().add("./manifest.json"), "'.' path segment")


func test_rejects_duplicates_unknown_and_missing() -> void:
	_expect(ZipTestBuilder.valid_layout().add("manifest.json", "{}".to_utf8_buffer()), "duplicate")
	_expect(ZipTestBuilder.valid_layout().add("regions/", PackedByteArray()), "duplicate")
	_expect(ZipTestBuilder.valid_layout().add("payload.gd", "x".to_utf8_buffer()), "unknown archive entry")
	_expect(ZipTestBuilder.valid_layout().add("regions/r_1_1.height.f32le", _region()), "unknown archive entry")
	_expect(ZipTestBuilder.valid_layout().add("scripts/"), "unexpected archive directory")
	var missing := ZipTestBuilder.new().add("manifest.json", "{}".to_utf8_buffer()).add("objects.json", "{}".to_utf8_buffer())
	_expect(missing, "missing 'regions/")


func test_rejects_symlink() -> void:
	var b := ZipTestBuilder.new()
	b.add("manifest.json", "/etc/passwd".to_utf8_buffer(), {"external_attr": 0xA1FF << 16})
	_expect(b, "symbolic link")


func test_rejects_oversize_declared() -> void:
	_expect(_layout_with(REGION, {"declared_uncompressed": 262145, "method": 8}), "exactly 262144")
	_expect(_layout_with("manifest.json", {"declared_uncompressed": 64 * 1024 + 1, "method": 8}), "manifest.json declares")
	_expect(_layout_with("objects.json", {"declared_uncompressed": 4 * 1024 * 1024 + 1, "method": 8}), "objects.json declares")
	var limits := ZipInspector.default_limits()
	limits.max_total_uncompressed = 1024
	var r := ZipInspector.inspect_bytes(ZipTestBuilder.valid_layout().build(), limits)
	assert_error_contains(r.error, "expands to", "total limit")
	var many := ZipTestBuilder.valid_layout()
	for i in 6:
		many.add("extra_%d" % i)
	_expect(many, "entries, allowed")


func test_rejects_zip64_multidisk_and_encryption() -> void:
	_expect(_layout_with(REGION, {"declared_uncompressed": 0xFFFFFFFF, "declared_compressed": 0xFFFFFFFF}), "ZIP64")
	var extra := PackedByteArray([1, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	_expect(_layout_with(REGION, {"extra": extra}), "ZIP64")
	_expect(ZipTestBuilder.valid_layout(), "ZIP64", {"total_entries": 0xFFFF})
	_expect(ZipTestBuilder.valid_layout(), "ZIP64", {"zip64_locator": true})
	_expect(ZipTestBuilder.valid_layout(), "multi-disk", {"disk": 1})
	_expect(ZipTestBuilder.valid_layout(), "multi-disk", {"entries_here": 3})
	_expect(_layout_with("objects.json", {"flags": 0x1}), "encrypted")
	_expect(_layout_with("objects.json", {"flags": 0x41}), "encrypted")


func test_rejects_bad_method_and_structure() -> void:
	_expect(_layout_with("objects.json", {"method": 12}), "compression method 12")
	_expect(_layout_with("objects.json", {"method": 99}), "compression method 99")
	_expect(_layout_with("objects.json", {"declared_uncompressed": 100}), "mismatched sizes")
	_expect(ZipTestBuilder.valid_layout(), "outside the archive", {"cd_offset": 0x7FFFFFF0})
	_expect(ZipTestBuilder.valid_layout(), "central directory", {"cd_size": 10})
	var r := ZipInspector.inspect_bytes("not a zip at all".to_utf8_buffer(), ZipInspector.default_limits())
	assert_error_contains(r.error, "not a ZIP")
	r = ZipInspector.inspect_bytes(PackedByteArray(), ZipInspector.default_limits())
	assert_error_contains(r.error, "not a ZIP")


## The inspected directory must be the one minizip (ZIPReader) extracts from.
func test_rejects_layouts_where_readers_disagree() -> void:
	var plain := ZipTestBuilder.valid_layout().build()
	var lim := ZipInspector.default_limits()
	var hidden := ZipTestBuilder.hide_directory_in_comment(plain, "objects.json", 5 * 1024 * 1024, 5)
	assert_error_contains(ZipInspector.inspect_bytes(hidden, lim).error, "comments are not allowed", "hidden directory")
	# With a zero-length inner comment the hidden directory IS the last one, so it is inspected.
	hidden = ZipTestBuilder.hide_directory_in_comment(plain, "objects.json", 5 * 1024 * 1024, 0)
	assert_error_contains(ZipInspector.inspect_bytes(hidden, lim).error, "objects.json", "hidden directory inspected")
	_expect(ZipTestBuilder.valid_layout(), "data after its end-of-central-directory", {"comment": "hi".to_utf8_buffer()})
	_expect(ZipTestBuilder.valid_layout(), "data after its end-of-central-directory", {"trailer": "xy".to_utf8_buffer()})
	var late_sig := PackedByteArray([0x50, 0x4B, 0x05, 0x06, 0x61, 0x62])
	_expect(ZipTestBuilder.valid_layout(), "data after its end-of-central-directory", {"comment_len": 0, "trailer": late_sig})
	_expect(ZipTestBuilder.valid_layout(), "not immediately followed", {"gap": PackedByteArray([0, 0, 0, 0])})
	# minizip honours a ZIP64 locator anywhere in the last 64 KiB, not only before the end record.
	_expect(_layout_with("manifest.json", {"data": ZipTestBuilder.zip64_locator()}), "ZIP64")


func test_local_header_must_match_central_record() -> void:
	_expect(_layout_with("objects.json", {"local_name": "objects.jsoX"}), "names a different file")
	_expect(_layout_with("objects.json", {"local_method": 8}), "flags or method differ")
	_expect(_layout_with("objects.json", {"local_flags": 0x800}), "flags or method differ")
	_expect(_layout_with("objects.json", {"local_crc": 0x1234}), "CRC or sizes differ")
	_expect(_layout_with("objects.json", {"local_compressed": 1}), "CRC or sizes differ")
	_expect(_layout_with("objects.json", {"local_uncompressed": 0xFFFFFFFF}), "CRC or sizes differ")
	var descriptor := {"flags": 0x8, "crc": 0x1234, "local_crc": 0, "local_compressed": 0, "local_uncompressed": 0}
	var r := ZipInspector.inspect_bytes(_layout_with("objects.json", descriptor).build(), ZipInspector.default_limits())
	assert_true(r.ok, "data-descriptor entries may leave local CRC/sizes zero: %s" % r.error)


func test_rejects_huge_file_before_reading() -> void:
	var dir := "user://wp_storage_tests/zip_%s" % StorageFs.random_hex(4)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("big.worldpoc")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.seek(16 * 1024 * 1024)
	f.store_8(0)
	f.close()
	assert_error_contains(ZipInspector.inspect(path).error, "limit")
	assert_error_contains(ZipInspector.inspect(dir.path_join("missing.worldpoc")).error, "cannot open")
	StorageFs.remove_tree(dir)


func _layout_with(name: String, overrides: Dictionary) -> ZipTestBuilder:
	var b := ZipTestBuilder.new()
	var region := _region()
	for path in WorldCodec.payload_paths() + PackedStringArray(["manifest.json"]):
		var data := region if WorldCodec.is_region_path(path) else "{}".to_utf8_buffer()
		b.add(path, data, overrides if path == name else {})
	return b
