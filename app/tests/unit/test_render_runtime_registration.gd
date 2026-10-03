extends TestCase
## Runtime-registered render assets: RenderAssetRegistry.register_runtime and RenderAssetCache.put_runtime keep
## derived tiers of AssetStudio bindings resident, budgeted and pinned, apart from the committed bundled index.

const KEY := "b11111111111111111111111111111111"
const OWNER := "runtime-assets"


func _cache(ceiling_mib: float = 512.0) -> RenderAssetCache:
	return RenderAssetCache.new({"managed_soft_mib": ceiling_mib * 0.75, "managed_ceiling_mib": ceiling_mib})


func test_put_runtime_is_resident_counted_and_not_evictable_while_pinned() -> void:
	var cache := _cache()
	var mesh := BoxMesh.new()
	var r := cache.put_runtime("k1", mesh, "mesh", 4096, OWNER)
	assert_eq(r.status, "ready")
	assert_eq(cache.state("k1"), "READY")
	assert_true(cache.get_resource("k1") == mesh)
	assert_eq(int(cache.stats().resident_bytes), 4096)
	assert_eq(int(cache.stats().by_kind.mesh), 4096)
	cache.trim(0)
	assert_eq(cache.state("k1"), "READY", "pinned entries are never trimmed")
	assert_eq(cache.put_runtime("k1", mesh, "mesh", 4096, "other").status, "ready")
	assert_eq(int(cache.stats().resident_bytes), 4096, "the same key counts once")
	assert_false(cache.release_runtime("k1", OWNER), "another owner still pins it")
	assert_true(cache.release_runtime("k1", "other"))
	assert_eq(cache.state("k1"), "UNLOADED")
	assert_eq(int(cache.stats().resident_bytes), 0)


func test_put_runtime_respects_the_budget_and_rejects_bad_requests() -> void:
	var cache := _cache(1.0)
	var over := cache.put_runtime("big", BoxMesh.new(), "mesh", 4 * RenderAssetCache.MIB, OWNER)
	assert_eq(over.status, "rejected")
	assert_eq(cache.state("big"), "UNLOADED")
	assert_eq(cache.put_runtime("x", null, "mesh", 10, OWNER).status, "rejected")
	assert_eq(cache.put_runtime("x", BoxMesh.new(), "bogus", 10, OWNER).status, "rejected")
	assert_eq(cache.put_runtime("x", BoxMesh.new(), "mesh", 10, "").status, "rejected")


func test_registry_runtime_descriptors_stay_apart_from_bundled_ones() -> void:
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var registry := RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	var bundled := registry.ready_ids()
	var def := AssetDefinition.new()
	def.asset_id = KEY
	def.bounds = AABB(Vector3(-1, 0, -1), Vector3(2, 3, 2))
	def.footprint_radius_m = 1.0
	var baked := RuntimeGlbLoader.Result.new()
	baked.mesh = ArrayMesh.new()
	baked.triangles = 12
	baked.surfaces = 1
	baked.aabb = def.bounds
	baked.gpu_bytes = 1000
	var tiers := RuntimeAssetTiers.build(def, baked, true, "test")
	var cache := _cache()
	assert_eq(RuntimeAssetTiers.register(tiers, registry, cache, OWNER), "")
	assert_true(registry.is_ready(KEY) and registry.is_runtime(KEY))
	assert_eq(registry.ready_ids(), bundled, "runtime keys are not bundled ready ids")
	assert_eq(registry.runtime_ids(), PackedStringArray([KEY]))
	assert_true(registry.is_scatter_eligible(KEY))
	assert_true(registry.is_scatter_eligible("nature.tree.spruce_a"), "bundled keys are always eligible")
	var d := registry.descriptor(KEY)
	assert_eq(d.roles.far.triangles, 12)
	assert_eq(d.resolve_role("ghost"), RuntimeAssetTiers.FAR_DEP)
	assert_eq(d.overview.kind, "solid")
	assert_true(d.roles.far.aabb.is_equal_approx(def.bounds))
	assert_true(cache.get_resource(RuntimeAssetTiers.cache_key(KEY, RuntimeAssetTiers.FAR_DEP)) is Mesh)
	RuntimeAssetTiers.unregister(KEY, registry, cache, OWNER)
	assert_false(registry.is_ready(KEY))
	assert_eq(int(cache.stats().resident_bytes), 0)
	registry.register_runtime(d, false)
	assert_false(registry.is_scatter_eligible(KEY))
