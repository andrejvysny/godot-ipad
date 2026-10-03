extends TestCase
## AssetBinding (ADR 0014 D3-D6): canonical decimals, content-addressed ids, strict parsing.

const CanonicalJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const DESCRIPTOR := "fixtures/descriptors/primitive_prop.json"

var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func _bundled(asset_id: String = "nature.tree.spruce_a") -> AssetBinding:
	return AssetBinding.bundled_default(_catalog, _catalog.get_asset(asset_id))


## An AssetStudio binding of the contract's primitive_prop descriptor.
func _remote() -> AssetBinding:
	var text := FileAccess.get_file_as_string(ContractFiles.path(DESCRIPTOR))
	var ref: Dictionary = JSON.parse_string(text).asset_ref
	var b := AssetBinding.new()
	b.provider = AssetBinding.PROVIDER_ASSETSTUDIO
	b.asset_ref = ref
	b.asset_key = Canonical.asset_key(ref.server_id, ref.library_id, ref.asset_id, ref.version_id)
	b.descriptor_json = text
	b.descriptor_sha256 = Canonical.sha256_hex(text.to_utf8_buffer())
	b.deliveries = {"portable_glb_v1": {"delivery_id": "dlv_00000000000000d1", "manifest_sha256": "9c0dd8d75427b0681def1818d9e51ae95b8cb5275440f85d7d12e73d13c5831e",
		"profile_id": "portable-default", "profile_version": "1.0.0"}}
	b.set_policy(false, "0.5", "2", "-0.1", "0.5")
	b.finalize()
	return b


func test_dec_cases() -> void:
	var cases := [[0.8, "0.8"], [1.25, "1.25"], [-0.2, "-0.2"], [0.0, "0"], [-0.0, "0"], [1e-7, "0"], [-1e-7, "0"],
		[0.1, "0.1"], [2.5000004, "2.5"], [1e-6, "0.000001"], [123.4567891, "123.456789"], [3.0, "3"], [100.0, "100"],
		[-0.75, "-0.75"], [0.30000000000000004, "0.3"]]
	for c: Array in cases:
		assert_eq(AssetBinding.dec(c[0]), c[1], str(c[0]))
		assert_true(Canonical.is_canonical_decimal(AssetBinding.dec(c[0])), "grammar of " + str(c[0]))


func test_default_bundled_binding_follows_the_catalog_entry() -> void:
	var b := _bundled()
	assert_eq(b.provider, "bundled")
	assert_eq([b.catalog_id, b.catalog_version, b.catalog_sha256], [_catalog.catalog_id, _catalog.catalog_version, _catalog.sha256])
	assert_eq([b.asset_id, b.asset_version], ["nature.tree.spruce_a", 1])
	assert_eq(b.scale_range, PackedStringArray(["0.5", "2"]))
	assert_eq(b.height_offset_range_m, PackedStringArray(["-1", "2"]))
	assert_true(b.scatter_allowed, "spruce has a scatter mesh")
	assert_false(_bundled("built.lodge.cabin_a").scatter_allowed, "the cabin has none")
	assert_eq([b.scale_min, b.scale_max, b.height_offset_min_m, b.height_offset_max_m], [0.5, 2.0, -1.0, 2.0])


func test_ids_are_deterministic_and_match_the_contract() -> void:
	assert_eq(_bundled().binding_id, _bundled().binding_id)
	assert_eq(_bundled().compute_id(), _bundled().binding_id)
	var expected := {"built.lodge.cabin_a": "be63ee86cd162608b8f8fce144f394532", "nature.rock.boulder_a": "b6bf600adb790dba1818bf55de70dc9b5",
		"nature.tree.spruce_a": "be3491d6eb49612448a6500223bf6de3c", "nature.cover.grass_tuft_a": "b1e8a3f2b9a523fd94cf6718a3b26814e",
		"nature.cover.fern_a": "b8a20ee3f3d953293625723c773bf5043", "nature.cover.wildflowers_a": "bdeb1b5a3d909ff38eafcd2c34d7d469e",
		"nature.rock.pebbles_a": "b5423d62356e37d31394747f4bbf1f073"}
	for asset_id: String in expected:
		assert_eq(_bundled(asset_id).binding_id, expected[asset_id], asset_id)
	assert_true(AssetBinding.is_valid_id(_bundled().binding_id))


func test_every_field_changes_the_id() -> void:
	var base := _bundled().binding_id
	var edits := {
		"version": func(b: AssetBinding) -> void: b.asset_version = 2,
		"asset": func(b: AssetBinding) -> void: b.asset_id = "nature.tree.spruce_b",
		"catalog sha": func(b: AssetBinding) -> void: b.catalog_sha256 = "ab".repeat(32),
		"catalog version": func(b: AssetBinding) -> void: b.catalog_version = 3,
		"scatter": func(b: AssetBinding) -> void: b.scatter_allowed = false,
		"scale": func(b: AssetBinding) -> void: b.set_policy(true, "0.5", "1.5", "-1", "2"),
		"height": func(b: AssetBinding) -> void: b.set_policy(true, "0.5", "2", "-1", "1"),
	}
	for key in edits:
		var b := _bundled()
		edits[key].call(b)
		assert_ne(b.compute_id(), base, key)


func test_from_dict_round_trip_and_id_mismatch() -> void:
	var b := _bundled()
	var parsed := AssetBinding.from_dict(JSON.parse_string(JSON.stringify(b.to_dict())))
	assert_empty_string(parsed[1])
	assert_eq((parsed[0] as AssetBinding).binding_id, b.binding_id)
	assert_eq((parsed[0] as AssetBinding).to_dict(), b.to_dict())
	var bad := b.to_dict()
	bad.binding_id = "b" + "0".repeat(32)
	assert_error_contains(AssetBinding.from_dict(bad)[1], "binding_id mismatch")
	bad = b.to_dict()
	bad.policy.scale_range = ["0.5", "2.5"]
	assert_error_contains(AssetBinding.from_dict(bad)[1], "binding_id mismatch", "an edited policy no longer matches its id")
	bad = b.to_dict()
	bad.binding_id = "nature.tree.spruce_a"
	assert_error_contains(AssetBinding.from_dict(bad)[1], "binding_id is not b + 32 hex digits")


func test_from_dict_is_strict() -> void:
	var cases := {
		"missing field policy": func(d: Dictionary) -> void: d.erase("policy"),
		"unknown field extra": func(d: Dictionary) -> void: d["extra"] = 1,
		"unknown binding provider": func(d: Dictionary) -> void: d.provider = "remote",
		"binding catalog.id": func(d: Dictionary) -> void: d.catalog.id = "Poc Nature",
		"binding catalog.sha256": func(d: Dictionary) -> void: d.catalog.sha256 = "xyz",
		"binding catalog.version": func(d: Dictionary) -> void: d.catalog.version = 0,
		"binding asset_id": func(d: Dictionary) -> void: d.asset_id = "Nature/Tree",
		"binding asset_version": func(d: Dictionary) -> void: d.asset_version = 1.5,
		"policy.scatter_allowed": func(d: Dictionary) -> void: d.policy.scatter_allowed = "yes",
		"policy.scale_range": func(d: Dictionary) -> void: d.policy.scale_range = ["0.50", "2"],
		"policy.scale_range ": func(d: Dictionary) -> void: d.policy.scale_range = ["0", "2"],
		"policy.height_offset_range_m": func(d: Dictionary) -> void: d.policy.height_offset_range_m = ["-0", "2"],
		"minimum exceeds": func(d: Dictionary) -> void: d.policy.scale_range = ["3", "2"],
		"binding policy must be an object": func(d: Dictionary) -> void: d.policy = [],
	}
	for key in cases:
		var d := _bundled().to_dict()
		cases[key].call(d)
		var r := AssetBinding.from_dict(d)
		assert_eq(r[0], null, key)
		assert_error_contains(r[1], String(key).strip_edges(), key)
	assert_error_contains(AssetBinding.from_dict(5)[1], "not an object")


func test_policy_comparisons_use_the_documented_epsilon() -> void:
	var b := _bundled()  # scale [0.5, 2], height offset [-1, 2]
	assert_true(b.in_scale(0.5) and b.in_scale(2.0))
	assert_true(b.in_scale(2.0 + 1e-6 * 2.0 - 1e-9), "within eps of the maximum")
	assert_false(b.in_scale(2.0 + 1e-5))
	assert_false(b.in_scale(0.5 - 1e-5))
	assert_true(b.in_scale(PackedFloat32Array([0.5]).to_byte_array().decode_float(0)), "float32 values")
	assert_false(b.in_scale(NAN) or b.in_scale(INF) or b.in_scale(0.0) or b.in_scale(-1.0))
	assert_true(b.in_height_offset(-1.0) and b.in_height_offset(2.0) and b.in_height_offset(0.0))
	assert_false(b.in_height_offset(2.001) or b.in_height_offset(NAN))
	assert_eq(AssetBinding.eps_of(0.0), 1e-6)
	assert_near(AssetBinding.eps_of(-200.0), 2e-4, 1e-12)


func test_assetstudio_binding_round_trip() -> void:
	var b := _remote()
	var parsed := AssetBinding.from_dict(b.to_dict())
	assert_empty_string(parsed[1])
	assert_eq((parsed[0] as AssetBinding).binding_id, b.binding_id)
	assert_eq(b.binding_id, "b578d00de924b0531126134a4a31acb4d", "the contract's one_remote_object binding")
	assert_false(b.is_bundled())
	var enc: RefCounted = CanonicalJson.encode(b.to_dict())
	assert_true(enc.ok and CanonicalJson.is_canonical(enc.value), "canonical bytes")


func test_assetstudio_binding_validation() -> void:
	var cases := {
		"asset_key does not match asset_ref": func(d: Dictionary) -> void: d.asset_key = "ab".repeat(32),
		"descriptor_sha256 mismatch": func(d: Dictionary) -> void: d.descriptor_sha256 = "ab".repeat(32),
		"descriptor_json must be a string": func(d: Dictionary) -> void: d.descriptor_json = "x",
		"missing field portable_glb_v1": func(d: Dictionary) -> void: d.deliveries = {},
		"deliveries.portable_glb_v1.manifest_sha256": func(d: Dictionary) -> void: d.deliveries.portable_glb_v1.manifest_sha256 = "zz",
		"unknown field mobile_glb_v1": func(d: Dictionary) -> void: d.deliveries["mobile_glb_v1"] = d.deliveries.portable_glb_v1.duplicate(),
		"lies outside the descriptor": func(d: Dictionary) -> void: d.policy.scale_range = ["0.5", "2.5"],
		"lies outside the descriptor ": func(d: Dictionary) -> void: d.policy.height_offset_range_m = ["-0.2", "0.5"],
		"asset_ref": func(d: Dictionary) -> void: d.asset_ref.version_id = "ver_1",
	}
	for key in cases:
		var d := _remote().to_dict()
		cases[key].call(d)
		var r := AssetBinding.from_dict(d)
		assert_eq(r[0], null, key)
		assert_error_contains(r[1], String(key).strip_edges(), key)
