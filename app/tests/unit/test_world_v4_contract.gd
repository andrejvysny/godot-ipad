extends TestCase
## Cross-language contract (contracts/world-painter/world-v4/): every entry of fixtures/INDEX.json and the
## canonical lock vectors, produced by the Python reference, must give the same results in GDScript.

const CanonicalJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const FIXTURE_DIR := "fixtures"

var _catalog: AssetCatalog
var _tmp := ""


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_tmp = "user://wp_contract_tests/%s" % StorageFs.random_hex(4)


func after_each() -> void:
	StorageFs.remove_tree(_tmp)


func _abs(rel: String) -> String:
	return ContractFiles.path(rel)


## Repo paths (app/fixtures/...) sit next to the contracts directory's repo root.
func _repo(rel: String) -> String:
	return ContractFiles.path().path_join("../../../" + rel).simplify_path()


func _json(rel: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(_abs(rel)))


func _index() -> Array:
	return _json(FIXTURE_DIR + "/INDEX.json").fixtures


## The hash the file stores: V2/V3 for a legacy source, V4 otherwise.
func _stored_hash(doc: WorldDocument) -> String:
	if doc.source_schema < WorldConstants.SCHEMA_VERSION_V4:
		return CanonicalEncoder.legacy_authored_hash(doc)[0]
	return CanonicalEncoder.authored_hash(doc)


func test_every_valid_fixture_imports_with_the_recorded_hash() -> void:
	var checked := 0
	for entry: Dictionary in _index():
		if entry.expected != "valid" or entry.path == null or entry.kind == "vectors":
			continue
		var imported := WorldPackage.import_package(_abs(FIXTURE_DIR + "/" + entry.path), _catalog, _tmp)
		if not assert_empty_string(imported[1], entry.name):
			continue
		assert_eq(_stored_hash(imported[0]), entry.authored_hash, entry.name)
		assert_eq(WorldValidator.validate(imported[0], _catalog), PackedStringArray(), entry.name)
		checked += 1
	assert_true(checked >= 10, "the index lists at least ten valid packages (%d)" % checked)


func test_every_invalid_fixture_is_rejected() -> void:
	var checked := 0
	for entry: Dictionary in _index():
		if entry.expected != "invalid":
			continue
		var imported := WorldPackage.import_package(_abs(FIXTURE_DIR + "/" + entry.path), _catalog, _tmp)
		assert_eq(imported[0], null, "%s must be rejected" % entry.name)
		assert_error_contains(imported[1], str(entry.error_substring), entry.name)
		checked += 1
	assert_true(checked >= 10, "the index lists at least ten invalid packages (%d)" % checked)


func test_procedural_and_app_fixture_vectors() -> void:
	for entry: Dictionary in _index():
		match entry.name:
			"km1_flat_empty":
				var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, WorldLayout.km1(), _catalog)
				assert_eq(CanonicalEncoder.authored_hash(doc), entry.authored_hash, entry.name)
			"migrate_v2_app_flat", "migrate_v2_app_gentle_hills":
				var loaded := WorldCodec.read_generation(_repo(str(entry.source)), _catalog)
				assert_empty_string(loaded[1], entry.name)
				assert_eq(CanonicalEncoder.authored_hash(loaded[0]), entry.authored_hash, entry.name)


## The migration pairs: terrain bytes, object ids and transform bits, scatter order and records are identical.
func test_migration_pairs_preserve_content() -> void:
	for entry: Dictionary in _index():
		if entry.kind != "migration":
			continue
		var source := WorldPackage.import_package(_abs(FIXTURE_DIR + "/" + str(entry.source)), _catalog, _tmp)
		var dest := WorldPackage.import_package(_abs(FIXTURE_DIR + "/" + str(entry.path)), _catalog, _tmp)
		assert_empty_string(source[1], entry.name)
		assert_empty_string(dest[1], entry.name)
		if source[0] == null or dest[0] == null:
			continue
		var a: WorldDocument = source[0]
		var b: WorldDocument = dest[0]
		assert_true(a.source_schema < 4 and b.source_schema == 4, entry.name)
		assert_eq(CanonicalEncoder.legacy_authored_hash(a)[0], entry.source_authored_hash, entry.name)
		for loc in a.layout.region_locations():
			assert_eq(b.get_region(loc).height_bytes(), a.get_region(loc).height_bytes(), "%s heights" % entry.name)
			assert_eq(b.get_region(loc).control_bytes(), a.get_region(loc).control_bytes(), "%s control" % entry.name)
			assert_eq(b.get_region(loc).color_bytes(), a.get_region(loc).color_bytes(), "%s color" % entry.name)
		assert_eq(b.sorted_object_ids(), a.sorted_object_ids(), entry.name)
		for id in a.sorted_object_ids():
			assert_true(a.get_object(id).equals(b.get_object(id)), "%s %s" % [entry.name, id])
		assert_true(a.scatter.equals(b.scatter), "%s scatter" % entry.name)
		assert_eq(CanonicalEncoder.authored_hash(a), entry.authored_hash, "converting the source in memory gives the v4 hash")


func test_canonical_vectors() -> void:
	var v: Dictionary = _json(FIXTURE_DIR + "/canonical-lock-vectors.json")
	for c: Dictionary in v.canonical:
		if c.name == "scalars":
			continue  # holds 2^53 + 1, which Godot's JSON parser (all numbers are floats) cannot represent
		var enc: RefCounted = CanonicalJson.encode(c.input)
		assert_true(enc.ok, c.name)
		if enc.ok:
			assert_eq((enc.value as PackedByteArray).hex_encode(), c.canonical_hex, c.name)
			assert_true(CanonicalJson.is_canonical(enc.value), c.name)
	for c: Dictionary in v.non_canonical_lock_bytes:
		assert_false(CanonicalJson.is_canonical(String(c.bytes_hex).hex_decode()), c.name)
	for c: Dictionary in v.reject_inputs:
		var parsed: Variant = JSON.parse_string(c.json)
		var enc: RefCounted = CanonicalJson.encode(parsed)
		var rejected: bool = not enc.ok or not CanonicalJson.is_canonical(c.json.to_utf8_buffer())
		assert_true(rejected, c.name)


func test_dec_and_asset_key_vectors() -> void:
	var v: Dictionary = _json(FIXTURE_DIR + "/canonical-lock-vectors.json")
	for c: Dictionary in v.dec:
		assert_eq(AssetBinding.dec(float(JSON.parse_string(c.input_json))), c.expected, c.input_json)
	for c: Dictionary in v.asset_keys:
		var r: Dictionary = c.asset_ref
		assert_eq(Canonical.asset_key(r.server_id, r.library_id, r.asset_id, r.version_id), c.asset_key)


func test_bundled_binding_vectors() -> void:
	var v: Dictionary = _json(FIXTURE_DIR + "/canonical-lock-vectors.json")
	var lock := WorldAssetLock.new(_catalog)
	for c: Dictionary in v.binding_ids:
		var parsed := AssetBinding.from_dict(c.binding)
		assert_empty_string(parsed[1], c.name)
		if parsed[0] == null:
			continue
		var b: AssetBinding = parsed[0]
		assert_eq(b.binding_id, c.binding_id, c.name)
		assert_eq((CanonicalJson.encode(b.to_dict(false)).value as PackedByteArray).hex_encode(), c.body_canonical_hex, c.name)
		if b.is_bundled() and _catalog.get_asset(b.asset_id) != null and b.catalog_sha256 == _catalog.sha256:
			assert_eq(lock.bundled_binding_for(b.asset_id), c.binding_id, "default binding of %s" % b.asset_id)
