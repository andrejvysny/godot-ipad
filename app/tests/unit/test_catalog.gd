extends TestCase
## Trusted asset catalog: strict loading, content hash (docs/world-format.md §6).

var _dir := ""


func before_each() -> void:
	_dir = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]
	DirAccess.make_dir_recursive_absolute(_dir)


func after_each() -> void:
	StorageFs.remove_tree(_dir)


func _bundled() -> Dictionary:
	var f := FileAccess.open("res://assets/catalog.json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func _load_mutated(mutate: Callable) -> Array:
	var data := _bundled()
	mutate.call(data)
	var sub := _dir.path_join(StorageFs.random_hex(4))
	DirAccess.make_dir_recursive_absolute(sub)
	var f := FileAccess.open(sub.path_join("catalog.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return AssetCatalog.load_from(sub)


func test_bundled_catalog_loads() -> void:
	var r := AssetCatalog.load_from()
	if not assert_empty_string(r[1], "bundled catalog"):
		return
	var cat: AssetCatalog = r[0]
	assert_eq(cat.catalog_id, "poc_nature")
	assert_eq(cat.catalog_version, 2)
	assert_eq(cat.sorted_ids(), PackedStringArray(["built.lodge.cabin_a", "nature.cover.fern_a", "nature.cover.grass_tuft_a",
		"nature.cover.wildflowers_a", "nature.rock.boulder_a", "nature.rock.pebbles_a", "nature.tree.spruce_a"]))
	assert_true(WorldManifest.is_hex64(cat.sha256), "sha256 hex")
	var boulder := cat.get_asset("nature.rock.boulder_a")
	assert_eq(boulder.anchor_local, Vector3(0.25, 0.3, -0.15), "nonzero anchor")
	assert_eq(boulder.default_grounding, WorldConstants.GROUNDING_FOLLOW)
	assert_eq(cat.get_asset("built.lodge.cabin_a").default_grounding, WorldConstants.GROUNDING_FIXED)
	assert_eq(cat.get_asset("built.lodge.cabin_a").scatter_mesh, "", "null scatter mesh")
	assert_true(cat.get_asset("nature.tree.spruce_a").scatter_allowed)
	assert_true(cat.get_asset("nature.rock.boulder_a").scatter_allowed)
	assert_false(cat.get_asset("built.lodge.cabin_a").scatter_allowed)
	assert_eq(cat.get_asset("nature.cover.fern_a").scatter_mesh, "res://assets/models/fern_a_scatter.tres")
	assert_true(cat.get_asset("nature.tree.spruce_a").bounds.has_volume(), "bounds")
	assert_eq(cat.get_asset("unknown"), null)
	assert_true(cat.has_compatible("nature.tree.spruce_a", 1))
	assert_false(cat.has_compatible("nature.tree.spruce_a", 2))


func test_hash_is_stable_and_matches_documented_stream() -> void:
	var a: AssetCatalog = AssetCatalog.load_from()[0]
	var b: AssetCatalog = AssetCatalog.load_from()[0]
	assert_eq(a.sha256, b.sha256, "stable across loads")
	# Independent recomputation of the §6 stream.
	var e := CanonicalEncoder.new()
	e.put_raw("WPOC-CATALOG-V1\n".to_ascii_buffer())
	e.put_str("catalog.json")
	e.put_raw(CanonicalEncoder.sha256(FileAccess.get_file_as_bytes("res://assets/catalog.json")))
	var paths := ["res://assets/models/boulder_a.tscn", "res://assets/models/boulder_a_scatter.tres",
		"res://assets/models/cabin_a.tscn", "res://assets/models/fern_a.tscn", "res://assets/models/fern_a_scatter.tres",
		"res://assets/models/grass_tuft_a.tscn", "res://assets/models/grass_tuft_a_scatter.tres",
		"res://assets/models/pebbles_a.tscn", "res://assets/models/pebbles_a_scatter.tres",
		"res://assets/models/spruce_a.tscn", "res://assets/models/spruce_a_scatter.tres",
		"res://assets/models/wildflowers_a.tscn", "res://assets/models/wildflowers_a_scatter.tres"]
	e.put_u32(paths.size())
	for p in paths:
		e.put_str(p)
		e.put_raw(CanonicalEncoder.sha256(FileAccess.get_file_as_bytes(p)))
	assert_eq(a.sha256, CanonicalEncoder.sha256_hex(e.bytes()), "documented stream")


func test_catalog_bytes_change_changes_hash() -> void:
	var bundled: AssetCatalog = AssetCatalog.load_from()[0]
	var same := _load_mutated(func(_d: Dictionary) -> void: pass)
	if not assert_empty_string(same[1]):
		return
	# Re-serialized JSON has different bytes -> different hash, even with equal content.
	assert_ne((same[0] as AssetCatalog).sha256, bundled.sha256)
	var moved := _load_mutated(func(d: Dictionary) -> void: d.assets[0].placement_anchor_local = [0.0, 0.6, 0.0])
	assert_ne((moved[0] as AssetCatalog).sha256, (same[0] as AssetCatalog).sha256, "changed pivot changes hash")


func test_rejects_invalid_catalogs() -> void:
	var cases := {
		"scale bounds must be positive": func(d: Dictionary) -> void: d.assets[0].scale_min = -1.0,
		"scale_min exceeds scale_max": func(d: Dictionary) -> void: d.assets[0].scale_min = 5.0,
		"height_offset_min_m exceeds": func(d: Dictionary) -> void: d.assets[1].height_offset_min_m = 9.0,
		"bounds_min must be below": func(d: Dictionary) -> void: d.assets[0].bounds_min = [0, 8, 0],
		"default_grounding": func(d: Dictionary) -> void: d.assets[2].default_grounding = "FLOATING",
		"duplicate asset_id": func(d: Dictionary) -> void: d.assets[1].asset_id = d.assets[0].asset_id,
		"not under res://assets/": func(d: Dictionary) -> void: d.assets[0].preview_scene = "res://scenes/editor_main.tscn",
		"does not exist": func(d: Dictionary) -> void: d.assets[0].preview_scene = "res://assets/models/missing.tscn",
		"unknown field": func(d: Dictionary) -> void: d.assets[0]["script"] = "res://evil.gd",
		"missing field 'license'": func(d: Dictionary) -> void: d.assets[0].erase("license"),
		"version must be a positive integer": func(d: Dictionary) -> void: d.assets[0].version = 1.5,
		"catalog_version": func(d: Dictionary) -> void: d.catalog_version = "1",
		"scatter_allowed must be a boolean": func(d: Dictionary) -> void: d.assets[0].scatter_allowed = 1,
		"placement_anchor_local": func(d: Dictionary) -> void: d.assets[0].placement_anchor_local = [0, 1],
		"footprint_radius_m must be positive": func(d: Dictionary) -> void: d.assets[0].footprint_radius_m = 0,
		"scatter_mesh must be null": func(d: Dictionary) -> void: d.assets[0].scatter_mesh = 3,
		"non-empty array": func(d: Dictionary) -> void: d.assets = [],
	}
	for needle in cases:
		var r := _load_mutated(cases[needle])
		assert_eq(r[0], null, needle)
		assert_error_contains(r[1], needle, needle)
	var traversal := _load_mutated(func(d: Dictionary) -> void: d.assets[0].thumbnail = "res://assets/../project.godot")
	assert_error_contains(traversal[1], "not under res://assets/", "traversal")


func test_rejects_missing_and_malformed_files() -> void:
	var missing := AssetCatalog.load_from(_dir.path_join("nothing_here"))
	assert_error_contains(missing[1], "cannot read")
	var f := FileAccess.open(_dir.path_join("catalog.json"), FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	assert_error_contains(AssetCatalog.load_from(_dir)[1], "not valid JSON")


func test_scene_must_be_self_contained() -> void:
	assert_empty_string(AssetCatalog.self_contained_error("a.tscn", "[gd_scene format=3]\n[node name=\"A\" type=\"Node3D\"]"))
	assert_error_contains(AssetCatalog.self_contained_error("a.tscn", "[ext_resource type=\"Script\" path=\"res://x.gd\" id=\"1\"]"), "self-contained")


func test_instantiate_preview() -> void:
	var cat: AssetCatalog = AssetCatalog.load_from()[0]
	var node := cat.instantiate_preview("nature.rock.boulder_a")
	assert_true(node is Node3D, "preview instance")
	if node:
		node.free()
	assert_eq(cat.instantiate_preview("nope"), null)


## The storage worker rebuilds its own catalog from plain values; it must be field-identical.
func test_plain_round_trip() -> void:
	var cat: AssetCatalog = AssetCatalog.load_from()[0]
	var plain := cat.to_plain()
	var copy := AssetCatalog.from_plain(plain.duplicate(true))
	assert_eq([copy.catalog_id, copy.catalog_version, copy.sha256], [cat.catalog_id, cat.catalog_version, cat.sha256])
	assert_eq(copy.sorted_ids(), cat.sorted_ids())
	for id in cat.sorted_ids():
		var a := cat.get_asset(id)
		var b := copy.get_asset(id)
		assert_true(b != a, "copy does not share definitions")
		for p in a.get_property_list():
			if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				assert_eq(b.get(p.name), a.get(p.name), "%s.%s" % [id, p.name])
	assert_eq(copy.to_plain(), plain)
