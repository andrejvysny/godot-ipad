extends TestCase
## RemoteBinding: the exact-version binding built from the server's version/resolve answers (IP-04), its refusals,
## and the scatter variant that needs a prepared, in-budget asset.

const LIB := FakeLibraryClient.LIBRARY
const SERVER := AssetTestKit.SERVER

var client: FakeLibraryClient


func before_each() -> void:
	client = FakeLibraryClient.new()
	client.add_version(AssetTestKit.V1_ID, AssetTestKit.descriptor_text("primitive_prop.json"))


func _ref(version: String = AssetTestKit.V1_ID) -> Dictionary:
	return client.ref_of(LIB, AssetTestKit.ASSET, version)


func test_builds_a_valid_exact_binding_with_descriptor_policy_and_dependency_entry() -> void:
	var r := await RemoteBinding.build(client, _ref())
	assert_true(r.ok, str(r.error))
	var b: AssetBinding = r.binding
	assert_true(AssetBinding.is_valid_id(b.binding_id))
	assert_eq(b.asset_ref, _ref())
	assert_eq(b.asset_key, AssetBinding.Canonical.asset_key(SERVER, LIB, AssetTestKit.ASSET, AssetTestKit.V1_ID))
	assert_false(b.scatter_allowed, "scatter is off by default")
	assert_eq([b.scale_min, b.scale_max, b.height_offset_min_m, b.height_offset_max_m], [0.5, 2.0, -0.1, 0.5], "default policy = descriptor ranges")
	assert_eq(b.deliveries.portable_glb_v1.delivery_id, AssetTestKit.DELIVERY)
	assert_true(b.dependencies.has(b.asset_key), "its own lock dependency entry")
	assert_eq(AssetBinding.from_dict(b.to_dict())[1], "")
	assert_true(client.calls.has("version:" + AssetTestKit.V1_ID) and client.calls.has("resolve:" + AssetTestKit.V1_ID))
	var again := await RemoteBinding.build(client, _ref())
	assert_eq(again.binding.binding_id, b.binding_id, "content-addressed: the same selection is the same binding")


func test_refuses_unknown_versions_tampered_descriptors_and_missing_deliveries() -> void:
	var missing := await RemoteBinding.build(client, _ref(AssetTestKit.V2_ID))
	assert_false(missing.ok)
	assert_error_contains(missing.error, "version_unavailable")
	var entry := {"asset_ref": _ref(), "state": "ready", "error": null, "descriptor_json": client.versions[AssetTestKit.V1_ID],
			"descriptor_sha256": "0".repeat(64), "deliveries": [], "dependencies": []}
	assert_error_contains(RemoteBinding.from_entry(_ref(), [entry]).error, "integrity_mismatch")
	entry.descriptor_sha256 = CanonicalEncoder.sha256_hex(str(entry.descriptor_json).to_utf8_buffer())
	assert_error_contains(RemoteBinding.from_entry(_ref(), [entry]).error, "no portable GLB delivery")
	entry.deliveries = [{"delivery_id": AssetTestKit.DELIVERY, "representation": "portable_glb_v1", "profile_id": "portable-default",
			"profile_version": "1.0.0", "manifest_sha256": "1".repeat(64)}]
	assert_true(RemoteBinding.from_entry(_ref(), [entry]).ok)
	entry.dependencies = [{"asset_key": "x"}]
	assert_error_contains(RemoteBinding.from_entry(_ref(), [entry]).error, "unsupported_dependency")
	entry.dependencies = []
	entry.asset_ref = _ref(AssetTestKit.V2_ID)
	assert_error_contains(RemoteBinding.from_entry(_ref(), [entry]).error, "different version", "an answer for another version is never accepted")
	entry.asset_ref = _ref()
	entry.state = "not_found"
	assert_false(RemoteBinding.from_entry(_ref(), [entry]).ok)
	entry.state = "ready"
	entry.representations = {"portable_glb_v1": {"state": "unsupported", "error": null}}
	assert_error_contains(RemoteBinding.from_entry(_ref(), [entry]).error, "unsupported_representation")


func test_scatter_variant_needs_a_prepared_in_budget_binding() -> void:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var registry := RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	var cache := RenderAssetCache.new(RenderConfig.load_from().section("budgets"))
	var doc := WorldDocument.new()
	doc.assets.catalog = catalog
	var b: AssetBinding = (await RemoteBinding.build(client, _ref())).binding
	doc.assets.add(b)
	var refused := RemoteBinding.with_scatter(doc.assets, b)
	assert_false(refused.ok)
	assert_error_contains(refused.error, "downloaded first")
	var fake := FakeAssetProvider.new()
	fake.default_glb = AssetTestKit.glb(AssetTestKit.GLB_V1)
	fake.bind_render(registry, cache)
	fake.attach(doc.assets)
	var done := []
	fake.prepared.connect(func(_i: String, ok: bool, _e: String) -> void: done.append(ok))
	fake.prepare(b.binding_id)
	for i in 300:
		if not done.is_empty():
			break
		await tree.process_frame
	assert_eq(done, [true])
	var scatter := RemoteBinding.with_scatter(doc.assets, b)
	assert_true(scatter.ok, str(scatter.error))
	assert_true(scatter.binding.scatter_allowed)
	assert_ne(scatter.binding.binding_id, b.binding_id, "scatter policy is a different binding")
	assert_eq(AssetBinding.from_dict(scatter.binding.to_dict())[1], "")
