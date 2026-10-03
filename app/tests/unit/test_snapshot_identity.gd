extends TestCase
## Apply identities (ADR 0017 A2) against the Python reference vectors in
## contracts/world-painter/world-v4/fixtures/generation-vectors.json.

func _vectors() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(ContractFiles.path("fixtures/generation-vectors.json")))


func _raw_digests(hex_digests: Dictionary) -> Dictionary:
	var out := {}
	for path: String in hex_digests:
		out[path] = (hex_digests[path] as String).hex_decode()
	return out


func test_snapshot_vectors() -> void:
	var cases: Array = _vectors().snapshots
	assert_true(cases.size() >= 3, "vectors present")
	for c: Dictionary in cases:
		assert_eq(SnapshotIdentity.snapshot_hash_of_digests(_raw_digests(c.digests)), c.source_snapshot_hash, c.name)


func test_profile_vectors() -> void:
	for c: Dictionary in _vectors().profiles:
		assert_eq(SnapshotIdentity.profile_canonical(c.profile).get_string_from_utf8(), c.canonical_json, "canonical json")
		assert_eq(SnapshotIdentity.profile_hash(c.profile), c.consumer_profile_hash, "profile hash")


func test_generation_vectors() -> void:
	var cases: Array = _vectors().generations
	for c: Dictionary in cases:
		var id := SnapshotIdentity.generation_id(c.source_snapshot_hash, c.consumer_profile_hash, c.pins)
		assert_eq(id, c.generation_id, c.name)
		assert_eq(SnapshotIdentity.dir_name(id), c.directory_name, c.name)
	assert_ne(cases[0].generation_id, cases[1].generation_id, "a Godot build change is a new generation")
	assert_ne(cases[0].generation_id, cases[2].generation_id, "a profile change is a new generation")
	assert_ne(cases[0].generation_id, cases[3].generation_id, "a source change is a new generation")


func test_fixture_package_snapshots_match_files_on_disk() -> void:
	for c: Dictionary in _vectors().fixture_snapshots:
		var dir := scratch_dir().path_join(str(c.fixture).get_basename())
		var zr := ZIPReader.new()
		assert_eq(zr.open(ContractFiles.path("fixtures/" + str(c.fixture))), OK, "open " + str(c.fixture))
		var digests := {}
		for name in zr.get_files():
			var data := zr.read_file(name)
			digests[name] = CanonicalEncoder.sha256(data)
			assert_empty_string(StorageFs.make_dir(dir.path_join(name).get_base_dir()))
			assert_empty_string(StorageFs.write_bytes(dir.path_join(name), data))
		zr.close()
		assert_eq(digests.size(), int(c.files), "file count")
		assert_eq(SnapshotIdentity.snapshot_hash_of_digests(digests), c.source_snapshot_hash, "digest vector " + str(c.fixture))
		var from_dir := SnapshotIdentity.source_snapshot_hash(dir)
		assert_empty_string(from_dir[1])
		assert_eq(from_dir[0], c.source_snapshot_hash, "directory hash " + str(c.fixture))


func test_extra_files_and_unsafe_payloads_do_not_change_or_pass() -> void:
	var c: Dictionary = (_vectors().fixture_snapshots as Array)[0]
	var dir := scratch_dir().path_join("extra")
	var zr := ZIPReader.new()
	zr.open(ContractFiles.path("fixtures/" + str(c.fixture)))
	for name in zr.get_files():
		StorageFs.make_dir(dir.path_join(name).get_base_dir())
		StorageFs.write_bytes(dir.path_join(name), zr.read_file(name))
	zr.close()
	StorageFs.write_bytes(dir.path_join("notes.txt"), "not a payload".to_utf8_buffer())
	assert_eq(SnapshotIdentity.source_snapshot_hash(dir)[0], c.source_snapshot_hash, "undeclared files are not hashed")
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("manifest.json")))
	manifest.payload_files[0].path = "../escape.bin"
	StorageFs.write_bytes(dir.path_join("manifest.json"), JSON.stringify(manifest).to_utf8_buffer())
	assert_error_contains(SnapshotIdentity.source_snapshot_hash(dir)[1], "unsafe")


func test_current_pins_and_profile_are_well_formed_and_stable() -> void:
	var pins := SnapshotIdentity.current_pins()
	for key: String in SnapshotIdentity.PIN_KEYS:
		assert_true(str(pins.get(key, "")) != "", "pin " + key)
	assert_true(str(pins.world_painter_pin).begins_with("0.1.0:"), "plugin.cfg version leads the pin")
	assert_eq(SnapshotIdentity.current_pins(), pins, "stable")
	var profile := SnapshotIdentity.consumer_profile()
	assert_eq(profile.accepted_world_root, ApplyLayout.DEFAULT_ROOT)
	assert_eq(SnapshotIdentity.profile_hash(profile).length(), 64)
