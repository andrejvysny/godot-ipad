extends TestCase
## Committed render-asset registries (editor poc_nature and benchmark bench_nature): index/descriptor
## integrity, tier budgets, anchor preservation (ASSET-02) and the unchanged editor catalog.

const Writer := preload("res://devtools/render_prep/descriptor_writer.gd")
const SceneReader := preload("res://devtools/render_prep/scene_reader.gd")
const MeshBaker := preload("res://devtools/render_prep/mesh_baker.gd")
const TexturePrep := preload("res://devtools/render_prep/texture_prep.gd")

const ROLES: Array[String] = ["selected", "near", "mid", "far", "ghost"]
const EDITOR_DIR := "res://assets"
const BENCH_DIR := "res://assets/bench"
const EDITOR_IDS := ["built.lodge.cabin_a", "nature.cover.fern_a", "nature.cover.grass_tuft_a", "nature.cover.wildflowers_a",
	"nature.rock.boulder_a", "nature.rock.pebbles_a", "nature.tree.spruce_a"]
const BENCH_IDS := ["bench.cover.grass_cards", "bench.rock.slab_a", "bench.shrub.bush_cards", "bench.structure.tower_a",
	"bench.tree.broadleaf_geo", "bench.tree.pine_cards"]
const BENCH_HEAVY := "bench.tree.heavy_unprepared"
## [min, max] triangles per mesh role; roles not listed alias another role.
const RANGES := {
	"bench.tree.broadleaf_geo": {"selected": [8000, 14000], "near": [2000, 5000], "mid": [500, 2000], "far": [200, 800]},
	"bench.tree.pine_cards": {"selected": [3000, 5000], "near": [1500, 2500], "mid": [600, 1200], "far": [150, 400]},
	"bench.shrub.bush_cards": {"selected": [1000, 1500], "mid": [300, 500], "far": [60, 150]},
	"bench.rock.slab_a": {"selected": [1500, 2500], "mid": [400, 600], "far": [80, 160]},
	"bench.structure.tower_a": {"selected": [1500, 2500], "mid": [400, 800], "far": [50, 120]},
	"bench.cover.grass_cards": {"selected": [56, 72], "far": [12, 20]},
}


func _json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _sha(path: String) -> String:
	return Writer.HashStream.sha256(FileAccess.get_file_as_bytes(path)).hex_encode()


func _registries() -> Array:
	return [
		{"dir": EDITOR_DIR, "registry": EDITOR_DIR + "/render_assets", "ids": EDITOR_IDS},
		{"dir": BENCH_DIR, "registry": BENCH_DIR + "/render_assets", "ids": BENCH_IDS},
	]


func _descriptor(reg: Dictionary, asset_id: String) -> Dictionary:
	var index := _json(reg.registry + "/index.json")
	for e: Dictionary in index.assets:
		if e.asset_id == asset_id:
			return _json(String(reg.registry).path_join(e.descriptor))
	return {}


func test_editor_catalog_is_unchanged() -> void:
	var r := AssetCatalog.load_from(EDITOR_DIR)
	if not assert_empty_string(r[1], "editor catalog loads"):
		return
	var cat: AssetCatalog = r[0]
	var fixture := _json("res://fixtures/flat/manifest.json")
	assert_eq(cat.sha256, fixture.catalog.sha256, "catalog hash referenced by the world fixtures")
	assert_eq(cat.sorted_ids(), PackedStringArray(EDITOR_IDS))


func test_indexes_list_the_expected_assets() -> void:
	for reg: Dictionary in _registries():
		var index := _json(reg.registry + "/index.json")
		assert_eq(index.format, "world-painter-render-assets", reg.dir)
		assert_eq(int(index.schema_version), 1)
		var cat: AssetCatalog = AssetCatalog.load_from(reg.dir)[0]
		assert_eq(index.catalog_id, cat.catalog_id, "catalog id")
		assert_eq(int(index.catalog_version), cat.catalog_version, "catalog version")
		var ids: Array = index.assets.map(func(e: Dictionary) -> String: return e.asset_id)
		assert_eq(ids, Array(reg.ids), "%s index assets (sorted)" % reg.dir)
		for e: Dictionary in index.assets:
			assert_eq(e.descriptor_sha256, _sha(String(reg.registry).path_join(e.descriptor)), "%s descriptor hash" % e.asset_id)
	var bench: AssetCatalog = AssetCatalog.load_from(BENCH_DIR)[0]
	assert_true(bench.get_asset(BENCH_HEAVY) != null, "heavy asset is in the bench catalog")
	assert_eq(bench.sorted_ids().size(), BENCH_IDS.size() + 1)
	assert_false(Array(BENCH_IDS).has(BENCH_HEAVY), "heavy asset has no registry entry")


func test_descriptors_are_complete_and_consistent_with_the_catalog() -> void:
	for reg: Dictionary in _registries():
		var cat: AssetCatalog = AssetCatalog.load_from(reg.dir)[0]
		for id: String in reg.ids:
			var d := _descriptor(reg, id)
			if not assert_false(d.is_empty(), "%s has a descriptor" % id):
				continue
			var a := cat.get_asset(id)
			var preview := FileAccess.get_file_as_bytes(a.preview_scene)
			var scatter: Variant = FileAccess.get_file_as_bytes(a.scatter_mesh) if a.scatter_mesh != "" else null
			assert_eq(d.source_content_hash, Writer.source_hash(id, a.version, preview, scatter), "%s source hash" % id)
			assert_eq(d.derivative_hash, Writer.derivative_hash(d), "%s derivative hash" % id)
			assert_eq(d.representations.keys(), Array(ROLES), "%s roles" % id)
			assert_vec_near(_v3(d.anchor_local_m), a.anchor_local, 1e-6, "%s anchor" % id)
			assert_vec_near(_v3(d.bounds_min_m), a.bounds.position, 1e-6, "%s bounds min" % id)
			assert_vec_near(_v3(d.bounds_max_m), a.bounds.end, 1e-6, "%s bounds max" % id)
			_check_dependencies(reg, id, d)
			for role in ROLES:
				var r: Dictionary = d.representations[role]
				if r.has("alias"):
					var target: Dictionary = d.representations[r.alias]
					assert_true(target.has("mesh") or d.representations[target.alias].has("mesh"), "%s %s alias resolves in 2 steps" % [id, role])
				else:
					assert_true(int(r.triangles) >= 1 and int(r.surfaces) >= 1 and int(r.surfaces) <= 8, "%s %s counts" % [id, role])


func _check_dependencies(reg: Dictionary, id: String, d: Dictionary) -> void:
	var keys: Array = d.dependencies.map(func(x: Dictionary) -> String: return x.key)
	var sorted_keys := keys.duplicate()
	sorted_keys.sort()
	assert_eq(keys, sorted_keys, "%s dependencies sorted" % id)
	var dir := String(reg.registry).path_join(id.get_slice(".", id.count(".")))
	for dep: Dictionary in d.dependencies:
		var path := dir.path_join(dep.path)
		assert_true(FileAccess.file_exists(path), "%s %s exists" % [id, dep.path])
		assert_eq(int(dep.bytes), FileAccess.get_file_as_bytes(path).size(), "%s %s bytes" % [id, dep.path])
		assert_eq(dep.sha256, _sha(path), "%s %s sha256" % [id, dep.path])
		if dep.type == "mesh":
			assert_true(ResourceLoader.load(path) is ArrayMesh, "%s %s loads as ArrayMesh" % [id, dep.path])
		elif dep.type == "material":
			assert_eq(ResourceLoader.load(path).get_class(), "StandardMaterial3D", "%s %s class" % [id, dep.path])
	for mk: String in d.materials:
		assert_true(keys.has(d.materials[mk].dependency), "%s material %s dependency listed" % [id, mk])


func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func test_bench_vegetation_triangle_budgets() -> void:
	var reg: Dictionary = _registries()[1]
	for id: String in RANGES:
		var d := _descriptor(reg, id)
		var want: Dictionary = RANGES[id]
		for role in ROLES:
			var r: Dictionary = d.representations[role]
			if want.has(role):
				var tris := int(r.get("triangles", -1))
				assert_true(tris >= want[role][0] and tris <= want[role][1], "%s %s: %d triangles outside %s" % [id, role, tris, str(want[role])])
			else:
				assert_true(r.has("alias"), "%s %s aliases another role" % [id, role])
		assert_eq(d.representations.ghost.alias, "far", "%s ghost aliases far" % id)


func _source_triangles(path: String) -> int:
	var scene := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var baked := MeshBaker.bake(SceneReader.read(scene, path).parts, func(_m: Material) -> String: return "k")
	return int(baked.triangles)


func test_bench_sources_are_much_heavier_than_their_tiers() -> void:
	var ranges := {"broadleaf_geo": [40000, 50000], "pine_cards": [5000, 8000], "heavy_unprepared": [55000, 65000]}
	for short: String in ranges:
		var path := "res://assets/bench/models/%s.tscn" % short
		var tris := _source_triangles(path)
		assert_true(tris >= ranges[short][0] and tris <= ranges[short][1], "%s source: %d triangles" % [short, tris])
		assert_true(FileAccess.get_file_as_bytes(path).size() < 3 * 1024 * 1024, "%s source file is under 3 MiB" % short)
	var broadleaf := _descriptor(_registries()[1], "bench.tree.broadleaf_geo")
	assert_true(_source_triangles("res://assets/bench/models/broadleaf_geo.tscn") > 3 * int(broadleaf.representations.selected.triangles),
		"the source is much heavier than the selected tier")


func test_tiers_keep_the_catalog_anchor_and_bounds() -> void:
	var cases := [[0, "nature.tree.spruce_a"], [0, "nature.rock.boulder_a"], [0, "built.lodge.cabin_a"],
		[1, "bench.tree.broadleaf_geo"], [1, "bench.tree.pine_cards"], [1, "bench.structure.tower_a"],
		[1, "bench.rock.slab_a"], [1, "bench.shrub.bush_cards"], [1, "bench.cover.grass_cards"]]
	for c: Array in cases:
		var reg: Dictionary = _registries()[c[0]]
		var id: String = c[1]
		var cat: AssetCatalog = AssetCatalog.load_from(reg.dir)[0]
		var a := cat.get_asset(id)
		var rec := ObjectRecord.new()
		rec.set_position(120.0, 7.5, -40.0)
		rec.set_yaw(0.8)
		rec.uniform_scale = 1.7
		var xf := rec.node_transform(a.anchor_local)
		assert_vec_near(xf * a.anchor_local, rec.get_position_v3(), 1e-4, "%s: node_transform keeps the anchor at the record position" % id)
		var grown := a.bounds.grow(maxf(maxf(a.bounds.size.x, a.bounds.size.y), a.bounds.size.z) * 0.05)
		var d := _descriptor(reg, id)
		var dir := String(reg.registry).path_join(id.get_slice(".", id.count(".")))
		for role in ROLES:
			var r: Dictionary = d.representations[role]
			if r.has("alias"):
				continue
			var mesh := ResourceLoader.load(dir.path_join(r.mesh + ".tres")) as ArrayMesh
			var box := mesh.get_aabb()
			assert_vec_near(box.position, _v3(r.aabb_min_m), 1e-3, "%s %s aabb min matches descriptor" % [id, role])
			assert_vec_near(box.end, _v3(r.aabb_max_m), 1e-3, "%s %s aabb max matches descriptor" % [id, role])
			assert_true(grown.encloses(box), "%s %s tier %s exceeds the logical bounds %s grown by 5%%" % [id, role, box, a.bounds])
			var world := xf * box
			assert_true((xf * grown).grow(1e-3).encloses(world), "%s %s tier stays inside the transformed bounds" % [id, role])


func test_prepared_textures_have_mipmaps_and_cutout_coverage() -> void:
	var reg: Dictionary = _registries()[1]
	var cutouts := 0
	for id in ["bench.tree.pine_cards", "bench.shrub.bush_cards", "bench.cover.grass_cards"]:
		var d := _descriptor(reg, id)
		var dir := String(reg.registry).path_join(id.get_slice(".", id.count(".")))
		for tkey: String in d.textures:
			for tier in ["low", "preview"]:
				var t: Variant = d.textures[tkey][tier]
				if t == null:
					continue
				var dep: Dictionary = d.dependencies.filter(func(x: Dictionary) -> bool: return x.key == t.dependency)[0]
				var path := dir.path_join(dep.path)
				var import_text := FileAccess.get_file_as_string(path + ".import")
				for line in TexturePrep.REQUIRED_PARAMS:
					assert_true(import_text.contains("\n" + line + "\n"), "%s: %s" % [path, line])
				var tex := ResourceLoader.load(path) as Texture2D
				if not assert_true(tex != null, "%s imports" % path):
					continue
				assert_eq([tex.get_width(), tex.get_height()], [int(t.width), int(t.height)], "%s size" % path)
				assert_true(tex.get_image().has_mipmaps(), "%s has mipmaps" % path)
				var img := Image.new()
				assert_eq(img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)), OK, "%s decodes" % path)
				if d.materials.values().any(func(m: Dictionary) -> bool: return m.texture == tkey and m.alpha_mode == "cutout"):
					cutouts += 1
					var cov := TexturePrep.coverage(img)
					assert_eq(cov.error, "", "%s cutout coverage across mips" % path)
	assert_eq(cutouts, 5, "foliage low/preview, bush low, grass low/preview")


func test_material_set_is_whitelisted_and_cutouts_use_the_low_texture() -> void:
	var reg: Dictionary = _registries()[1]
	var d := _descriptor(reg, "bench.tree.pine_cards")
	var dir := String(reg.registry).path_join("pine_cards")
	assert_eq(d.materials.foliage.alpha_mode, "cutout")
	assert_eq(d.materials.bark.alpha_mode, "opaque")
	var foliage := ResourceLoader.load(dir.path_join("foliage.tres")) as StandardMaterial3D
	assert_eq(foliage.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)
	assert_eq(foliage.albedo_texture.resource_path, dir.path_join("foliage_low.png"), "cutout material references the low texture")
	assert_eq(foliage.cull_mode, BaseMaterial3D.CULL_DISABLED)
