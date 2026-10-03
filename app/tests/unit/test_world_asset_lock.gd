extends TestCase
## WorldAssetLock (ADR 0014 D2, D6, D8, D10): content-addressed registry, derived canonical lock bytes,
## strict decoding, availability and effective definitions.

const CanonicalJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const DESCRIPTOR := "fixtures/descriptors/primitive_prop.json"
const OBJ_A := "11111111-1111-4111-8111-111111111111"
const OBJ_B := "22222222-2222-4222-8222-222222222222"
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"

var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func _doc() -> WorldDocument:
	return WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, null, _catalog)


func _put(doc: WorldDocument, id: String, binding_id: String) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = id
	r.binding_id = binding_id
	r.set_position(1.0, 0.0, 2.0)
	doc.put_object(r)
	return r


func _remote_binding() -> AssetBinding:
	var text := FileAccess.get_file_as_string(ContractFiles.path(DESCRIPTOR))
	var ref: Dictionary = JSON.parse_string(text).asset_ref
	var b := AssetBinding.new()
	b.provider = AssetBinding.PROVIDER_ASSETSTUDIO
	b.asset_ref = ref
	b.asset_key = Canonical.asset_key(ref.server_id, ref.library_id, ref.asset_id, ref.version_id)
	b.descriptor_json = text
	b.descriptor_sha256 = Canonical.sha256_hex(text.to_utf8_buffer())
	var pin := {"delivery_id": "dlv_00000000000000d1", "manifest_sha256": "9c0dd8d75427b0681def1818d9e51ae95b8cb5275440f85d7d12e73d13c5831e",
		"profile_id": "portable-default", "profile_version": "1.0.0"}
	b.deliveries = {"portable_glb_v1": pin}
	b.dependencies = {b.asset_key: {"asset_ref": ref.duplicate(), "descriptor_sha256": b.descriptor_sha256,
		"deliveries": {"portable_glb_v1": pin.duplicate()}, "requires": []}}
	b.set_policy(false, "0.5", "2", "-0.1", "0.5")
	b.finalize()
	return b


func test_add_is_idempotent_and_bundled_binding_for_is_cached() -> void:
	var lock := WorldAssetLock.new(_catalog)
	var a := lock.bundled_binding_for(SPRUCE)
	assert_eq(lock.bundled_binding_for(SPRUCE), a)
	assert_eq(lock.add(AssetBinding.bundled_default(_catalog, _catalog.get_asset(SPRUCE))), a, "same content, same id")
	assert_eq(lock.size(), 1)
	assert_eq(lock.bundled_binding_for("no.such.asset"), "")
	assert_eq(WorldAssetLock.new().bundled_binding_for(SPRUCE), "", "without a catalog nothing resolves")
	assert_true(lock.get_binding(a) != null and lock.get_binding("b" + "0".repeat(32)) == null)


func test_serialized_lock_holds_only_referenced_bindings_sorted() -> void:
	var doc := _doc()
	var spruce := doc.assets.bundled_binding_for(SPRUCE)
	var boulder := doc.assets.bundled_binding_for(BOULDER)
	doc.assets.bundled_binding_for("built.lodge.cabin_a")  # registered, never referenced
	_put(doc, OBJ_A, spruce)
	doc.scatter.add(boulder, 1.0, 1.0, 0.0, 1.0, 0)
	var ids := doc.assets.referenced_ids(doc)
	var sorted := PackedStringArray([spruce, boulder])
	sorted.sort()
	assert_eq(ids, sorted)
	var encoded := doc.assets.encode_referenced(doc)
	assert_empty_string(encoded[1])
	var parsed: Dictionary = JSON.parse_string((encoded[0] as PackedByteArray).get_string_from_utf8())
	assert_eq(parsed.bindings.size(), 2)
	assert_eq([parsed.bindings[0].binding_id, parsed.bindings[1].binding_id], Array(sorted))
	assert_eq(parsed.dependencies, {})
	assert_eq(parsed.schema_version, 1.0)
	assert_true(CanonicalJson.is_canonical(encoded[0]), "canonical bytes")
	var empty := _doc().assets.encode_referenced(_doc())
	assert_eq((empty[0] as PackedByteArray).get_string_from_utf8(), '{"bindings":[],"dependencies":{},"schema_version":1}')
	doc.scatter.remove_indices(PackedInt32Array([0]))
	assert_eq(doc.assets.referenced_ids(doc), PackedStringArray([spruce]), "removed instances drop their binding")


func test_unknown_referenced_binding_has_no_lock_bytes() -> void:
	var doc := _doc()
	_put(doc, OBJ_A, "b" + "1".repeat(32))
	assert_error_contains(doc.assets.encode_referenced(doc)[1], "referenced but not in the asset lock")
	assert_eq(CanonicalEncoder.authored_hash(doc), "", "no hash for a broken document")


## The registry is not history data: undo and redo never touch it, and the derived lock keeps the hash stable.
func test_authored_hash_is_stable_across_undo_and_redo() -> void:
	var doc := _doc()
	var before := CanonicalEncoder.authored_hash(doc)
	var history := CommandHistory.new()
	var tx := EditTransaction.new()
	tx.begin(doc, "place", "Place")
	assert_true(tx.capture_object(OBJ_A))
	_put(doc, OBJ_A, doc.assets.bundled_binding_for(SPRUCE))
	var change := tx.finish()
	doc.bump_revision()
	history.push_already_applied(change)
	var placed := CanonicalEncoder.authored_hash(doc)
	assert_ne(placed, before)
	history.undo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), before, "undo restores the hash although the binding stays registered")
	assert_eq(doc.assets.size(), 1, "the registry is append-only")
	history.redo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), placed, "redo restores the hash")
	history.undo(doc)
	var other := _doc()
	assert_eq(CanonicalEncoder.authored_hash(other), before, "an unused registry entry does not affect the hash")


func test_decode_round_trip_and_rejections() -> void:
	var doc := _doc()
	_put(doc, OBJ_A, doc.assets.bundled_binding_for(SPRUCE))
	_put(doc, OBJ_B, doc.assets.bundled_binding_for(BOULDER))
	var bytes: PackedByteArray = doc.assets.encode_referenced(doc)[0]
	var decoded := WorldAssetLock.decode(bytes, _catalog)
	assert_empty_string(decoded[1])
	assert_eq((decoded[0] as WorldAssetLock).ids(), doc.assets.referenced_ids(doc))
	var parsed: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
	var pretty := JSON.stringify(parsed, "  ", true).to_utf8_buffer()
	assert_error_contains(WorldAssetLock.decode(pretty, _catalog)[1], "not canonical")
	var unsorted := parsed.duplicate(true)
	unsorted.bindings.reverse()
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(unsorted).value, _catalog)[1], "not sorted and unique")
	var duplicate := parsed.duplicate(true)
	duplicate.bindings[1] = duplicate.bindings[0].duplicate(true)
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(duplicate).value, _catalog)[1], "not sorted and unique")
	var extra_key := parsed.duplicate(true)
	extra_key["extra"] = 1
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(extra_key).value, _catalog)[1], "unknown field")
	var wrong_schema := parsed.duplicate(true)
	wrong_schema.schema_version = 2
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(wrong_schema).value, _catalog)[1], "schema_version")
	var float_value := '{"bindings":[],"dependencies":{},"schema_version":1.0}'.to_utf8_buffer()
	assert_error_contains(WorldAssetLock.decode(float_value, _catalog)[1], "not canonical")
	var stray := parsed.duplicate(true)
	stray.dependencies = {"ab".repeat(32): {}}
	assert_false(WorldAssetLock.decode(CanonicalJson.encode(stray).value, _catalog)[1].is_empty(), "a dependency outside any closure")


func test_remote_bindings_carry_their_dependency_closure() -> void:
	var doc := _doc()
	var remote := _remote_binding()
	_put(doc, OBJ_A, doc.assets.add(remote))
	var encoded := doc.assets.encode_referenced(doc)
	assert_empty_string(encoded[1])
	var parsed: Dictionary = JSON.parse_string((encoded[0] as PackedByteArray).get_string_from_utf8())
	assert_eq(parsed.dependencies.keys(), [remote.asset_key])
	var decoded := WorldAssetLock.decode(encoded[0], _catalog)
	assert_empty_string(decoded[1])
	var back: AssetBinding = (decoded[0] as WorldAssetLock).get_binding(remote.binding_id)
	assert_eq(back.dependencies, remote.dependencies, "each binding gets its own closure back")
	var missing := parsed.duplicate(true)
	missing.dependencies = {}
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(missing).value, _catalog)[1], "dependencies are missing the entry")
	var cyclic := parsed.duplicate(true)
	cyclic.dependencies[remote.asset_key].requires = [remote.asset_key]
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(cyclic).value, _catalog)[1], "cycle")
	var dangling := parsed.duplicate(true)
	dangling.dependencies[remote.asset_key].requires = ["ab".repeat(32)]
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(dangling).value, _catalog)[1], "is missing")
	var pin_mismatch := parsed.duplicate(true)
	pin_mismatch.dependencies[remote.asset_key].deliveries.portable_glb_v1.profile_version = "2.0.0"
	assert_error_contains(WorldAssetLock.decode(CanonicalJson.encode(pin_mismatch).value, _catalog)[1], "lacks the portable_glb_v1 pin")


func test_availability_reports_without_rejecting() -> void:
	var doc := _doc()
	var good := doc.assets.bundled_binding_for(SPRUCE)
	_put(doc, OBJ_A, good)
	assert_eq(doc.assets.availability(doc).unavailable, {})
	var foreign := AssetBinding.bundled_default(_catalog, _catalog.get_asset(BOULDER))
	foreign.catalog_sha256 = "ab".repeat(32)
	foreign.finalize()
	var missing := AssetBinding.bundled_default(_catalog, _catalog.get_asset(BOULDER))
	missing.asset_id = "nature.tree.baobab"
	missing.finalize()
	var old_version := AssetBinding.bundled_default(_catalog, _catalog.get_asset(BOULDER))
	old_version.asset_version = 7
	old_version.finalize()
	var remote := _remote_binding()
	var reasons := {}
	for b: AssetBinding in [foreign, missing, old_version, remote]:
		_put(doc, ObjectRecord.new_uuid_v4(), doc.assets.add(b))
		reasons[b.binding_id] = doc.assets.unavailable_reason(b.binding_id)
	var unavailable: Dictionary = doc.assets.availability(doc).unavailable
	assert_eq(unavailable.size(), 4)
	assert_false(unavailable.has(good))
	assert_error_contains(reasons[foreign.binding_id], "is not the trusted catalog")
	assert_error_contains(reasons[missing.binding_id], "is not in the trusted catalog")
	assert_error_contains(reasons[old_version.binding_id], "is not the trusted v1")
	assert_error_contains(reasons[remote.binding_id], "not resolved on this device")
	assert_eq(WorldAssetLock.new().unavailable_reason("b" + "0".repeat(32)), "binding is not in the asset lock")
	var no_catalog := WorldAssetLock.new()
	no_catalog.add(foreign)
	assert_error_contains(no_catalog.unavailable_reason(foreign.binding_id), "no trusted catalog")


func test_definitions_are_effective_and_keyed_by_render_key() -> void:
	var lock := WorldAssetLock.new(_catalog)
	var spruce := lock.bundled_binding_for(SPRUCE)
	var def := lock.definition(spruce)
	assert_eq(def.asset_id, SPRUCE, "available bundled: the catalog asset id is the render key")
	assert_eq([def.scale_min, def.scale_max, def.height_offset_min_m, def.height_offset_max_m], [0.5, 2.0, -1.0, 2.0])
	assert_eq(def.scatter_mesh, _catalog.get_asset(SPRUCE).scatter_mesh)
	assert_eq(def.bounds, _catalog.get_asset(SPRUCE).bounds)
	assert_true(lock.definition(spruce) == def, "cached per binding")
	assert_true(def != _catalog.get_asset(SPRUCE), "a copy, the catalog entry stays untouched")
	var narrow := AssetBinding.bundled_default(_catalog, _catalog.get_asset(SPRUCE))
	narrow.set_policy(false, "1", "1.5", "0", "0")
	narrow.finalize()
	var narrow_def := lock.definition(lock.add(narrow))
	assert_eq([narrow_def.scale_min, narrow_def.scale_max, narrow_def.scatter_allowed], [1.0, 1.5, false], "policy replaces the catalog limits")
	var foreign := AssetBinding.bundled_default(_catalog, _catalog.get_asset(SPRUCE))
	foreign.catalog_sha256 = "ab".repeat(32)
	foreign.finalize()
	var foreign_def := lock.definition(lock.add(foreign))
	assert_eq(foreign_def.asset_id, foreign.binding_id, "unavailable: the binding id is the render key")
	assert_eq(foreign_def.bounds, AABB(), "empty bounds")
	assert_eq(foreign_def.scale_max, 2.0, "limits still come from the policy")
	var remote := _remote_binding()
	var remote_def := lock.definition(lock.add(remote))
	assert_eq(remote_def.asset_id, remote.binding_id)
	assert_eq(remote_def.bounds, AABB(Vector3(-0.5, 0.0, -1.0), Vector3(1.0, 0.5, 2.0)), "frozen descriptor bounds")
	assert_eq(remote_def.anchor_local, Vector3(0.25, 0.0, -0.5))
	assert_near(remote_def.footprint_radius_m, 1.1, 1e-9)
	assert_eq(remote_def.scatter_mesh, "", "no preview scene or scatter mesh")
	assert_eq(lock.definition("b" + "0".repeat(32)), null)
	var swapped := WorldAssetLock.new(_catalog)
	var id := swapped.add(AssetBinding.bundled_default(_catalog, _catalog.get_asset(SPRUCE)))
	assert_eq(swapped.definition(id).asset_id, SPRUCE)
	swapped.catalog = null
	assert_eq(swapped.definition(id).asset_id, id, "dropping the catalog drops the cached definitions")
