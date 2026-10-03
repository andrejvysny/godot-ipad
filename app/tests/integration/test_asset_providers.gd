extends TestCase
## Provider boundary (IP-03): FakeAssetProvider and AssetStudioProvider (file-backed exact cache, offline_only)
## prepare tiny contract GLBs into render keys that the presenter batches, picks and scatters like bundled assets;
## cancellation, offline gaps and exactness never leave anything half registered.

const BlobCache := preload("res://addons/assetstudio/core/as_blob_cache.gd")

var catalog: AssetCatalog
var registry: RenderAssetRegistry
var cache: RenderAssetCache
var doc: WorldDocument
var presenter: ObjectPresenter
var gate_open := true


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	registry = RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	cache = RenderAssetCache.new(RenderConfig.load_from().section("budgets"))
	doc = WorldDocument.new()
	doc.assets.catalog = catalog


func after_each() -> void:
	if presenter != null and is_instance_valid(presenter):
		tree.root.remove_child(presenter)
		presenter.free()
	presenter = null


func _gate() -> bool:
	return gate_open


func _fake() -> FakeAssetProvider:
	var p := FakeAssetProvider.new()
	p.bind_render(registry, cache, _gate)
	p.attach(doc.assets)
	return p


func _remote(file: String, version: String, glb_path: String, scatter: bool = false) -> Dictionary:
	var item := AssetTestKit.remote(file, version, AssetTestKit.glb(glb_path), scatter)
	doc.assets.add(item.binding)
	return item


func _object(binding_id: String, x: float, z: float) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.binding_id = binding_id
	r.set_position(x, 0.25, z)
	r.uniform_scale = 1.0
	doc.put_object(r)
	return r


func _present() -> void:
	presenter = ObjectPresenter.new()
	presenter.setup(catalog, registry, cache)
	tree.root.add_child(presenter)
	presenter.rebuild(doc)
	presenter.settle_now()


## Prepares `id` and waits for the result: [ok, error] (empty after 600 frames).
func _prepare(p: WPAssetProvider, id: String, token: RefCounted = null) -> Array:
	var result := []
	p.prepared.connect(func(i: String, ok: bool, err: String) -> void:
		if i == id:
			result.assign([ok, err]))
	p.prepare(id, token)
	for i in 600:
		if not result.is_empty():
			break
		await tree.process_frame
	return result


func test_fake_provider_prepares_a_key_that_renders_and_picks() -> void:
	var item := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var id: String = item.binding.binding_id
	var rec := _object(id, 33.0, 41.5)
	_present()
	var world := presenter.render_world()
	assert_false(presenter.is_asset_ready(id), "unprepared bindings are placeholders")
	assert_true(world.batch_of(rec.object_id).multimesh().mesh == world.placeholder_mesh())
	var fake := _fake()
	fake.glb_by_binding[id] = item.glb
	var before := int(cache.stats().resident_bytes)
	var r := await _prepare(fake, id)
	assert_eq(r, [true, ""])
	print("MEASURE FakeAssetProvider prepare primitive_prop %.2f ms (fetch+validate+bake+register)" % fake.last_prepare_ms)
	assert_true(fake.is_prepared(id))
	assert_true(doc.assets.is_prepared(id))
	assert_eq(doc.assets.unavailable_reason(id), "")
	assert_true(registry.is_ready(id) and registry.is_runtime(id))
	assert_true(int(cache.stats().resident_bytes) > before, "runtime meshes count in the cache budget")
	presenter.refresh_asset(doc, id)
	assert_true(presenter.settle_now())
	var mesh := world.batch_of(rec.object_id).multimesh().mesh
	assert_true(mesh != world.placeholder_mesh(), "the batch now draws a prepared tier")
	assert_true(mesh == fake.representation(id, "selected") or mesh == fake.representation(id, "far"))
	assert_true(fake.representation(id, "overview") != null and fake.representation(id, "bogus") == null)
	var anchor := presenter.anchor_position(rec.object_id)
	var hit := presenter.pick(anchor + Vector3(0, 10, 0), Vector3.DOWN)
	assert_eq(hit.id, rec.object_id, "picking uses the frozen descriptor bounds")
	var def := doc.assets.definition(id)
	assert_true(presenter.world_bounds(rec.object_id).is_equal_approx(presenter.applied_transform(rec.object_id) * def.bounds))
	var node := fake.instantiate(id)
	assert_true(node != null and node.get_child(0) is MeshInstance3D)
	node.free()


func test_two_versions_of_one_asset_coexist() -> void:
	var v1 := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var v2 := _remote("primitive_prop_v2.json", AssetTestKit.V2_ID, AssetTestKit.GLB_V2)
	var id1: String = v1.binding.binding_id
	var id2: String = v2.binding.binding_id
	assert_ne(id1, id2)
	var fake := _fake()
	fake.glb_by_binding[id1] = v1.glb
	fake.glb_by_binding[id2] = v2.glb
	assert_eq(await _prepare(fake, id1), [true, ""])
	assert_eq(await _prepare(fake, id2), [true, ""])
	assert_eq(fake.prepared_ids(), PackedStringArray([id1, id2] if id1 < id2 else [id2, id1]))
	assert_eq(registry.descriptor(id1).roles.selected.triangles, 12)
	assert_eq(registry.descriptor(id2).roles.selected.triangles, 24)
	assert_true(fake.representation(id1, "near") != fake.representation(id2, "near"))


func test_corrupt_bytes_fail_without_registering() -> void:
	var item := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var id: String = item.binding.binding_id
	var fake := _fake()
	fake.glb_by_binding[id] = item.glb
	fake.corrupt[id] = true
	var r := await _prepare(fake, id)
	assert_false(r[0])
	assert_false(registry.is_ready(id))
	assert_false(doc.assets.is_prepared(id))
	assert_true(doc.assets.unavailable_reason(id).contains(str(r[1])), "the failure is the visible reason")
	fake.corrupt.clear()
	fake.fail_with[id] = "temporarily_unavailable: server down"
	r = await _prepare(fake, id)
	assert_error_contains(str(r[1]), "server down")


func test_cancel_mid_prepare_leaves_nothing_registered() -> void:
	var item := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var id: String = item.binding.binding_id
	var fake := _fake()
	fake.glb_by_binding[id] = item.glb
	fake.delay_frames = 10
	var baseline := int(cache.stats().resident_bytes)
	var result := []
	fake.prepared.connect(func(i: String, ok: bool, err: String) -> void: result.assign([i, ok, err]))
	fake.prepare(id)
	await tree.process_frame
	await tree.process_frame
	assert_eq(fake.pending_count(), 1)
	fake.cancel_all()
	for i in 30:
		await tree.process_frame
	assert_eq(result, [id, false, "cancelled"])
	assert_eq(fake.pending_count(), 0)
	assert_false(registry.is_ready(id))
	assert_false(doc.assets.is_prepared(id))
	assert_eq(doc.assets.unavailable_reason(id), WorldAssetLock.REMOTE_UNAVAILABLE, "availability is unchanged")
	assert_eq(int(cache.stats().resident_bytes), baseline)
	fake.delay_frames = 0
	fake.cancel_during_fetch = true
	assert_eq(await _prepare(fake, id), [false, "cancelled"])
	fake.cancel_during_fetch = false
	assert_eq(await _prepare(fake, id), [true, ""], "a later prepare of the same binding works")


func test_cancel_while_waiting_for_the_heavy_gate_registers_nothing() -> void:
	var item := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var id: String = item.binding.binding_id
	var fake := _fake()
	fake.glb_by_binding[id] = item.glb
	gate_open = false
	var result := []
	fake.prepared.connect(func(i: String, ok: bool, err: String) -> void: result.assign([ok, err]))
	fake.prepare(id)
	for i in 5:
		await tree.process_frame
	assert_true(result.is_empty() and not fake.is_prepared(id), "no GLTFDocument while an operation is active")
	fake.cancel(id)
	for i in 5:
		await tree.process_frame
	assert_eq(result, [false, "cancelled"])
	assert_false(registry.is_ready(id))
	gate_open = true
	assert_eq(await _prepare(fake, id), [true, ""])


func test_assetstudio_provider_prepares_from_the_exact_cache_offline() -> void:
	var item := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var id: String = item.binding.binding_id
	var blobs := BlobCache.new(scratch_dir() + "/cache")
	AssetTestKit.seed(blobs, item)
	var p := AssetStudioProvider.new(blobs)
	p.bind_render(registry, cache, _gate)
	p.attach(doc.assets)
	var sha := CanonicalEncoder.sha256_hex(item.glb)
	p.pin("world:a", PackedStringArray([id]))
	var r := await _prepare(p, id)
	assert_eq(r, [true, ""])
	print("MEASURE AssetStudioProvider prepare primitive_prop (offline exact cache) %.2f ms" % p.last_prepare_ms)
	assert_true(registry.is_ready(id) and doc.assets.is_prepared(id))
	assert_true(blobs.is_pinned(sha), "the delivered bytes are pinned for the owner")
	p.pin("world:b", PackedStringArray([id]))
	p.unpin("world:a")
	assert_true(p.is_prepared(id), "another owner still pins it")
	p.unpin("world:b")
	assert_false(p.is_prepared(id))
	assert_false(registry.is_ready(id), "released tiers leave the registry")
	assert_false(blobs.is_pinned(sha))
	assert_false(doc.assets.is_prepared(id))
	assert_eq(int(cache.stats().by_kind.mesh), 0, "and the cache")
	p.shutdown()


func test_offline_missing_bytes_stay_unavailable_and_never_substitute() -> void:
	var v1 := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var v2 := _remote("primitive_prop_v2.json", AssetTestKit.V2_ID, AssetTestKit.GLB_V2)
	var blobs := BlobCache.new(scratch_dir() + "/cache")
	AssetTestKit.seed(blobs, v1)
	var p := AssetStudioProvider.new(blobs)
	p.bind_render(registry, cache, _gate)
	p.attach(doc.assets)
	var id2: String = v2.binding.binding_id
	var r := await _prepare(p, id2)
	assert_false(r[0])
	assert_error_contains(str(r[1]), "temporarily_unavailable")
	assert_false(registry.is_ready(id2), "the cached v1 is never offered for v2")
	assert_true(doc.assets.unavailable_reason(id2).begins_with(WorldAssetLock.REMOTE_UNAVAILABLE))
	assert_error_contains(doc.assets.unavailable_reason(id2), "temporarily_unavailable")
	assert_eq(await _prepare(p, v1.binding.binding_id), [true, ""])
	p.shutdown()


func test_a_manifest_that_differs_from_the_lock_is_refused() -> void:
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	var b: AssetBinding = item.binding
	b.deliveries.portable_glb_v1.manifest_sha256 = "ab".repeat(32)
	b.finalize()
	doc.assets.add(b)
	var blobs := BlobCache.new(scratch_dir() + "/cache")
	AssetTestKit.seed(blobs, item)
	var p := AssetStudioProvider.new(blobs)
	p.bind_render(registry, cache, _gate)
	p.attach(doc.assets)
	var r := await _prepare(p, b.binding_id)
	assert_false(r[0])
	assert_error_contains(str(r[1]), "integrity_mismatch")
	assert_false(registry.is_ready(b.binding_id))
	p.shutdown()


func test_router_dispatches_by_binding_provider() -> void:
	var item := _remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.GLB_V1)
	var id: String = item.binding.binding_id
	var bundled_id := doc.assets.bundled_binding_for("nature.tree.spruce_a")
	_object(id, 10.0, 10.0)
	_object(bundled_id, 20.0, 20.0)
	var router := WorldAssetProviders.new()
	var bundled := BundledProvider.new(registry, cache)
	var fake := FakeAssetProvider.new()
	fake.glb_by_binding[id] = item.glb
	fake.bind_render(registry, cache, _gate)
	router.add_provider(bundled)
	router.add_provider(fake)
	router.attach(doc.assets)
	assert_true(router.provider_of(bundled_id) == bundled and router.provider_of(id) == fake)
	assert_true(router.is_prepared(bundled_id), "bundled bindings are always prepared")
	assert_false(router.is_prepared(id))
	assert_eq(router.describe(id).render_key, id)
	assert_eq(router.describe(bundled_id).render_key, "nature.tree.spruce_a")
	assert_true((router.describe(id).bounds as AABB).is_equal_approx(AABB(Vector3(-0.5, 0, -1), Vector3(1, 0.5, 2))))
	var done := []
	router.prepared.connect(func(i: String, ok: bool, _e: String) -> void: done.append([i, ok]))
	var started := router.prepare_referenced(doc, "world:a")
	assert_eq(started, PackedStringArray([id]), "only the AssetStudio binding needs preparing")
	for i in 60:
		if router.is_prepared(id):
			break
		await tree.process_frame
	assert_true(router.is_prepared(id) and done.has([id, true]))
	router.unpin("world:a")
	assert_false(router.is_prepared(id))
	assert_true(router.is_prepared(bundled_id))
	var lost := []
	router.prepared.connect(func(i: String, ok: bool, e: String) -> void: lost.assign([i, ok, e]))
	router.prepare("b" + "0".repeat(32))
	await tree.process_frame
	assert_eq(lost[1], false)


func _scatter_doc(glb: PackedByteArray) -> Array:
	var imported := WorldPackage.import_package(ContractFiles.path("fixtures/remote_scatter.worldpoc"), catalog, scratch_dir() + "/pkg")
	assert_empty_string(imported[1])
	var d: WorldDocument = imported[0]
	var id: String = d.assets.ids()[0]
	var fake := FakeAssetProvider.new()
	fake.bind_render(registry, cache, _gate)
	fake.attach(d.assets)
	fake.glb_by_binding[id] = glb
	return [d, fake, id]


func _scatter_renderer(d: WorldDocument) -> ScatterRenderer:
	var renderer := ScatterRenderer.new()
	renderer.setup(catalog, registry, cache)
	renderer.set_lod_profile(ScatterTestCase.full_profile())
	renderer.rebuild_all(d)
	assert_true(renderer.settle_now(), "scatter settles")
	return renderer


func test_remote_scatter_renders_prepared_tiers_when_eligible() -> void:
	var s := _scatter_doc(AssetTestKit.glb(AssetTestKit.GLB_V1))
	var d: WorldDocument = s[0]
	var fake: FakeAssetProvider = s[1]
	var id: String = s[2]
	var renderer := _scatter_renderer(d)
	assert_eq(int(renderer.stats().authored), 3)
	assert_true(int(renderer.stats().placeholder_batches) > 0, "unprepared instances are placeholders")
	assert_eq(await _prepare(fake, id), [true, ""])
	assert_true(registry.is_scatter_eligible(id))
	renderer.asset_registered(id)
	assert_true(renderer.settle_now())
	var stats := renderer.stats()
	assert_eq(int(stats.placeholder_batches), 0, "prepared tiers replace the placeholders")
	assert_eq(int(stats.instances), 3)
	renderer.free()


func test_remote_scatter_over_budget_stays_placeholder_and_refuses_new_placement() -> void:
	var s := _scatter_doc(AssetTestKit.sphere_glb(64, 32))
	var d: WorldDocument = s[0]
	var fake: FakeAssetProvider = s[1]
	var id: String = s[2]
	assert_true(d.assets.definition(id).scatter_allowed, "policy allows scatter before the structural check")
	var renderer := _scatter_renderer(d)
	assert_eq(await _prepare(fake, id), [true, ""])
	assert_true(registry.is_ready(id))
	assert_false(registry.is_scatter_eligible(id))
	assert_false(d.assets.definition(id).scatter_allowed, "new scatter placement with it is refused")
	renderer.asset_registered(id)
	assert_true(renderer.settle_now())
	assert_true(int(renderer.stats().placeholder_batches) > 0, "existing instances stay placeholders")
	assert_eq(int(renderer.stats().instances), 3)
	renderer.free()
