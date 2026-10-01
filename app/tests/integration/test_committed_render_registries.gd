extends TestCase
## The committed editor and benchmark registries pass the runtime validation (docs/render-assets.md)
## and every role resolves to a loadable ArrayMesh whose measured counts match its descriptor.

const ROLES := ["selected", "near", "mid", "far", "ghost"]


func _registry(catalog_dir: String) -> Array:
	var loaded := AssetCatalog.load_from(catalog_dir)
	if not assert_empty_string(str(loaded[1])):
		return [null, null]
	var catalog: AssetCatalog = loaded[0]
	return [catalog, RenderAssetRegistry.load_from(catalog_dir.path_join("render_assets/index.json"), catalog)]


func test_editor_registry_covers_every_catalog_asset() -> void:
	var pair := _registry("res://assets")
	var catalog: AssetCatalog = pair[0]
	var reg: RenderAssetRegistry = pair[1]
	if reg == null:
		return
	assert_eq(reg.error(), "")
	for id in catalog.sorted_ids():
		assert_true(reg.is_ready(id), "%s: %s" % [id, str(reg.status(id))])
		_check_roles(reg.descriptor(id))


func test_bench_registry_gates_the_unprepared_asset() -> void:
	var pair := _registry("res://assets/bench")
	var catalog: AssetCatalog = pair[0]
	var reg: RenderAssetRegistry = pair[1]
	if reg == null:
		return
	assert_eq(reg.error(), "")
	for id in catalog.sorted_ids():
		if id == "bench.tree.heavy_unprepared":
			assert_eq(reg.status(id).reason, "no_derivative")
			assert_false(ResourceLoader.has_cached(catalog.get_asset(id).preview_scene), "source never loaded")
		else:
			assert_true(reg.is_ready(id), "%s: %s" % [id, str(reg.status(id))])
			_check_roles(reg.descriptor(id))


func _check_roles(d: RenderAssetDescriptor) -> void:
	if not assert_true(d != null):
		return
	for role: String in ROLES:
		var entry: Dictionary = d.roles[role]
		var dep := d.dependency(d.resolve_role(role))
		var mesh := load(str(dep.path)) as ArrayMesh
		if not assert_true(mesh != null, "%s %s mesh loads" % [d.asset_id, role]):
			continue
		assert_eq(mesh.get_surface_count(), int(entry.surfaces), "%s %s surfaces" % [d.asset_id, role])
		var triangles := 0
		for s in mesh.get_surface_count():
			assert_true(mesh.surface_get_material(s) is StandardMaterial3D, "%s %s material" % [d.asset_id, role])
			triangles += mesh.surface_get_array_index_len(s) / 3 if mesh.surface_get_array_index_len(s) > 0 \
					else mesh.surface_get_array_len(s) / 3
		assert_eq(triangles, int(entry.triangles), "%s %s triangles" % [d.asset_id, role])
