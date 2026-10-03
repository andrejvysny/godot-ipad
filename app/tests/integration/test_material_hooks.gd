extends ApplyTestCase
## Consumer hooks of ADR 0016 P4 / ADR 0017 A4: the material mapper (preview meshes, render cache, Apply bake) keeps
## unknown materials and calls the hook once per (binding, slot); the consumer terrain material replaces the World
## Painter shader material in the preview adapter and the bake; both opt-ins are part of the consumer-profile hash.

const MapperFixture := preload("res://tests/fixtures/material_mapper_fixture.gd")
const MAPPER_PATH := "res://tests/fixtures/material_mapper_fixture.gd"
const TERRAIN_MATERIAL := "res://tests/fixtures/terrain_custom.tres"

var catalog: AssetCatalog
var doc: WorldDocument
var base := ""


class Host extends Node:
	var slots: Array[String] = []

	func map_material(slot_id: String, material: Material) -> Material:
		slots.append(slot_id)
		if slot_id == "keep":
			return null
		var out := StandardMaterial3D.new()
		out.resource_name = "mapped:" + slot_id
		return out


class AssetHost extends Node:
	var seen: Array[String] = []

	func map_material_for(asset_id: String, slot_id: String, material: Material) -> Material:
		seen.append("%s/%s" % [asset_id, slot_id])
		return null


func before_each() -> void:
	super()
	catalog = AssetCatalog.load_from()[0]
	doc = ApplyTestKit.make_doc(catalog)
	base = "user://test_scratch/%s/bake" % current_test.replace("::", "_")
	MapperFixture.calls.clear()


func after_each() -> void:
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, null)
	ProjectSettings.set_setting(TerrainMaterials.SETTING, null)
	super()


func _ctx() -> BakeContext:
	var deliveries := ApplyDeliveries.new()
	deliveries.catalog = catalog
	var ctx := BakeContext.new(doc, base, deliveries)
	ctx.identity = {"world_id": doc.world_id}
	return ctx


func _mesh(names: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for i in names.size():
		var box := BoxMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
		var m := StandardMaterial3D.new()
		m.resource_name = names[i]
		mesh.surface_set_material(i, m)
	return mesh


func test_mapper_calls_once_per_binding_slot_and_preserves_declined_and_unnamed_surfaces() -> void:
	var host := Host.new()
	var mapper := WPMaterialMapper.new(host)
	var mesh := _mesh(["m_solid", "keep", "m_solid", ""])
	var keep := mesh.surface_get_material(1)
	assert_eq(mapper.map_mesh("b1", mesh), 3, "three surfaces replaced")
	assert_eq(mesh.surface_get_material(0).resource_name, "mapped:m_solid")
	assert_eq(mesh.surface_get_material(0), mesh.surface_get_material(2), "one result per slot")
	assert_eq(mesh.surface_get_material(1), keep, "declined slot preserved")
	assert_eq(mesh.surface_get_material(3).resource_name, "mapped:surface_3", "unnamed surface gets a positional slot")
	assert_eq(host.slots, ["m_solid", "keep", "surface_3"] as Array[String], "hook called once per slot")
	mapper.map_mesh("b1", _mesh(["m_solid"]))
	assert_eq(host.slots.size(), 3, "cached per (binding, slot)")
	mapper.map_mesh("b2", _mesh(["m_solid"]))
	assert_eq(host.slots.size(), 4, "another binding asks again")
	host.free()


func test_mapper_contract_and_setting_loading() -> void:
	var plain := Node.new()
	assert_false(WPMaterialMapper.supports(plain), "no hook")
	assert_false(WPMaterialMapper.supports(null))
	plain.free()
	assert_eq(WPMaterialMapper.from_setting(), [null, ""], "unset is not an error")
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, MAPPER_PATH)
	var loaded := WPMaterialMapper.from_setting()
	assert_eq(loaded[1], "")
	assert_true(loaded[0] != null, "script mapper")
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, "res://tests/support/session_stub.gd")
	assert_error_contains(WPMaterialMapper.from_setting()[1], "no static map_material")
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, "../x.gd")
	assert_error_contains(WPMaterialMapper.from_setting()[1], "not a res:// script")


func test_render_cache_maps_loaded_meshes_once() -> void:
	var host := Host.new()
	var cache := RenderAssetCache.new()
	cache.mesh_mapper = WPMaterialMapper.new(host)
	var path := "user://test_scratch/%s/box.res" % current_test
	StorageFs.make_dir(ProjectSettings.globalize_path(path.get_base_dir()))
	assert_eq(ResourceSaver.save(_mesh(["m_solid", "other"]), path), OK)
	assert_eq(cache.request("asset.a|v1|h|dep", path, "mesh", 1, 100, "t").status, "queued")
	var t0 := Time.get_ticks_msec()
	while cache.state("asset.a|v1|h|dep") != "READY" and Time.get_ticks_msec() - t0 < 5000:
		cache.poll(5.0)
		await tree.process_frame
	var mesh := cache.get_resource("asset.a|v1|h|dep") as Mesh
	assert_true(mesh != null, "loaded")
	assert_eq(mesh.surface_get_material(0).resource_name, "mapped:m_solid")
	assert_eq(mesh.surface_get_material(1).resource_name, "mapped:other")
	assert_eq(host.slots.size(), 2)
	host.free()


func test_bake_maps_object_and_scatter_materials_and_keeps_declined_ones() -> void:
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, MAPPER_PATH)
	var ctx := _ctx()
	ctx.use_profile(SnapshotIdentity.consumer_profile())
	assert_empty_string(ctx.mapper_error)
	assert_empty_string(WorldBaker.bake(ctx), "bake")
	assert_true(MapperFixture.calls.size() > 0, "the hook ran")
	var packed := ResourceLoader.load(ctx.scene_res(), "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	var inst := packed.instantiate()
	var mapped := 0
	for node in inst.get_node("Objects").find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			mapped += 1 if m != null and m.resource_name.begins_with("mapped:") else 0
	var scatter_mapped := 0
	for node in inst.get_node("Scatter").get_children():
		var mm := (node as MultiMeshInstance3D).multimesh.mesh
		for s in mm.get_surface_count():
			scatter_mapped += 1 if mm.surface_get_material(s).resource_name.begins_with("mapped:") else 0
	assert_true(mapped > 0, "object surfaces carry mapped materials (%d)" % mapped)
	assert_true(scatter_mapped > 0, "scatter surfaces carry mapped materials (%d)" % scatter_mapped)
	inst.free()


func test_bake_without_a_mapper_keeps_every_material() -> void:
	var ctx := _ctx()
	ctx.use_profile(SnapshotIdentity.consumer_profile())
	assert_true(ctx.mapper == null)
	assert_empty_string(WorldBaker.bake(ctx))
	assert_true(MapperFixture.calls.is_empty(), "no hook call")
	assert_false(FileAccess.get_file_as_string(ctx.scene_res()).contains("mapped:"))


func test_a_broken_mapper_setting_fails_the_bake() -> void:
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, "res://tests/fixtures/missing_mapper.gd")
	var ctx := _ctx()
	ctx.use_profile(SnapshotIdentity.consumer_profile())
	assert_error_contains(WorldBaker.bake(ctx), "material mapper")


func test_consumer_terrain_material_replaces_the_default_in_adapter_and_bake() -> void:
	var default_shader := TerrainAdapter.create_material().shader_override.resource_path
	assert_eq(default_shader, TerrainAdapter.SHADER_PATH)
	ProjectSettings.set_setting(TerrainMaterials.SETTING, TERRAIN_MATERIAL)
	var custom := TerrainAdapter.create_material()
	assert_eq(custom.shader_override.resource_path, "res://tests/fixtures/terrain_custom.gdshader", "adapter uses it")
	assert_true(custom != (load(TERRAIN_MATERIAL) as Terrain3DMaterial), "a copy: the shared resource is never mutated")
	var ctx := _ctx()
	assert_empty_string(WorldBaker.bake(ctx), "bake")
	var text := FileAccess.get_file_as_string(ctx.generated_res().path_join("terrain/material.tres"))
	assert_true(text.contains("terrain_custom.gdshader"), "the bake saves the consumer shader")
	assert_false(text.contains("world_terrain.gdshader"), "not the default one")
	ProjectSettings.set_setting(TerrainMaterials.SETTING, "res://tests/fixtures/terrain_custom.gdshader")
	assert_error_contains(TerrainMaterials.load_custom()[1], "not a Terrain3DMaterial")
	assert_error_contains(WorldBaker.bake(_ctx()), "not a Terrain3DMaterial")


func test_profile_hash_covers_mapper_and_terrain_material_only_when_set() -> void:
	var plain := SnapshotIdentity.consumer_profile()
	assert_false(plain.has("material_mapper") or plain.has("terrain_material"), "default profile keys unchanged")
	ProjectSettings.set_setting(WPMaterialMapper.SETTING, MAPPER_PATH)
	var with_mapper := SnapshotIdentity.consumer_profile()
	assert_eq(with_mapper.material_mapper.path, MAPPER_PATH)
	assert_eq(with_mapper.material_mapper.sha256, SnapshotIdentity.closure_hash([MAPPER_PATH]), "script file hash")
	assert_true(SnapshotIdentity.profile_hash(with_mapper) != SnapshotIdentity.profile_hash(plain))
	ProjectSettings.set_setting(TerrainMaterials.SETTING, TERRAIN_MATERIAL)
	var with_both := SnapshotIdentity.consumer_profile()
	assert_true(with_both.has("terrain_material"))
	assert_true(SnapshotIdentity.profile_hash(with_both) != SnapshotIdentity.profile_hash(with_mapper))
	var closure := SnapshotIdentity.closure_hash([TERRAIN_MATERIAL], true)
	assert_eq(with_both.terrain_material.sha256, closure)
	assert_true(closure != SnapshotIdentity.closure_hash([TERRAIN_MATERIAL]), "the shader is part of the closure")


func test_runtime_provider_maps_the_baked_mesh_before_registering_tiers() -> void:
	var registry := RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	var cache := RenderAssetCache.new(RenderConfig.load_from().section("budgets"))
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	doc.assets.add(item.binding)
	var id: String = item.binding.binding_id
	var host := Host.new()
	var fake := FakeAssetProvider.new()
	fake.bind_render(registry, cache)
	fake.attach(doc.assets)
	fake.material_mapper = WPMaterialMapper.new(host)
	fake.glb_by_binding[id] = item.glb
	var result := []
	fake.prepared.connect(func(i: String, ok: bool, err: String) -> void:
		if i == id:
			result.assign([ok, err]))
	fake.prepare(id)
	for i in 600:
		if not result.is_empty():
			break
		await tree.process_frame
	assert_eq(result, [true, ""])
	assert_true(host.slots.size() > 0, "the hook ran for the binding's slots: %s" % host.slots)
	var mesh := fake.representation(id, WPAssetProvider.TIER_SELECTED)
	for s in mesh.get_surface_count():
		assert_true(mesh.surface_get_material(s).resource_name.begins_with("mapped:"), "surface %d mapped" % s)
	var far := fake.representation(id, WPAssetProvider.TIER_FAR)
	assert_false(far.surface_get_material(0).resource_name.begins_with("mapped:"), "the far box keeps its grey")
	host.free()


func test_preview_assets_wire_the_mapper_into_cache_and_provider() -> void:
	var client := PreviewBrokerClient.new()
	var assets := PreviewAssets.new(catalog, client, "")
	var host := Host.new()
	var mapper := WPMaterialMapper.new(host)
	assets.set_material_mapper(mapper)
	assert_true(assets.cache.mesh_mapper == mapper and assets.assetstudio.material_mapper == mapper)
	assets.shutdown()
	client.free()
	host.free()


func test_asset_aware_hook_is_preferred_and_sees_the_asset_identity() -> void:
	var host := AssetHost.new()
	var mapper := WPMaterialMapper.new(host)
	assert_true(WPMaterialMapper.supports(host))
	var mesh := _mesh(["m_solid"])
	assert_eq(mapper.map_mesh("b1", mesh, "ast_1"), 0, "declined")
	mapper.map_mesh("b2", _mesh(["m_solid"]))
	assert_eq(host.seen, ["ast_1/m_solid", "b2/m_solid"] as Array[String], "asset id, else the binding id")
	var remote := AssetBinding.new()
	remote.provider = AssetBinding.PROVIDER_ASSETSTUDIO
	remote.asset_ref = {"asset_id": "ast_9"}
	assert_eq(WPMaterialMapper.asset_id_of(remote), "ast_9")
	var bundled := doc.assets.get_binding(doc.assets.bundled_binding_for(ApplyTestKit.SPRUCE))
	assert_eq(WPMaterialMapper.asset_id_of(bundled), ApplyTestKit.SPRUCE)
	host.free()
