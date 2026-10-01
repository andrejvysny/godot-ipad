extends TestCase
## RenderAssetDescriptor (docs/render-assets.md §2-§4): strict parse, hashes, helpers.

# Shared with scripts/tests/test_render_assets.py: both implementations must produce these values.
const VECTOR_SOURCE_HASH := "964a07c16f495345ab854358837f5be1d46082436febc868489dd903fa2d7be2"
const VECTOR_DERIVATIVE_HASH := "2d2e133ad1b476248bd99428c6f8b10fd52299648ca90bda4346bdda39414e79"


func _parse(mutate: Callable = Callable()) -> Array:
	var d := RenderAssetFixture.vector_descriptor()
	if mutate.is_valid():
		mutate.call(d)
	return RenderAssetDescriptor.parse(d, "res://assets/render_assets/vec")


func _reason(mutate: Callable) -> String:
	var r := _parse(mutate)
	if r[0] != null:
		return "(accepted)"
	return RenderAssetDescriptor.error_reason(r[1])


func test_hash_vectors_match_python() -> void:
	assert_eq(RenderAssetDescriptor.source_content_hash_of("vec.asset", 3, CanonicalEncoder.sha256("preview".to_utf8_buffer()),
		CanonicalEncoder.sha256("scatter".to_utf8_buffer())), VECTOR_SOURCE_HASH, "source hash")
	assert_ne(RenderAssetDescriptor.source_content_hash_of("vec.asset", 3, CanonicalEncoder.sha256("preview".to_utf8_buffer()),
		PackedByteArray()), VECTOR_SOURCE_HASH, "scatter mesh participates")
	var r := _parse()
	if not assert_empty_string(r[1], "vector descriptor parses"):
		return
	assert_eq((r[0] as RenderAssetDescriptor).compute_derivative_hash(), VECTOR_DERIVATIVE_HASH, "derivative hash")


func test_parse_fields_and_alias_resolution() -> void:
	var r := _parse()
	if not assert_empty_string(r[1], "parse"):
		return
	var d: RenderAssetDescriptor = r[0]
	assert_eq(d.asset_id, "vec.asset")
	assert_eq(d.asset_version, 3)
	assert_eq(d.category, "tree")
	assert_true(d.vegetation)
	assert_false(d.decorative)
	assert_eq(d.bounds, AABB(Vector3(-1, 0, -1), Vector3(2, 4, 2)))
	assert_eq(d.alias_of("near"), "selected")
	assert_eq(d.alias_of("selected"), "")
	assert_eq(d.resolve_role("ghost"), "mesh_far")
	assert_eq(d.resolve_role("mid"), "mesh_sel")
	assert_eq(d.resolve_role("nope"), "")
	assert_eq(d.roles.ghost.triangles, 44)
	assert_eq(d.roles.near.aabb, AABB(Vector3(-1, 0, -1), Vector3(2, 4, 2)))
	assert_eq(d.dependency("mesh_far").path, "res://assets/render_assets/vec/far.tres")
	assert_eq(d.dependency("mesh_far").rel_path, "far.tres")
	assert_true(d.dependency("missing").is_empty())
	assert_eq(d.materials.leaf.texture, "leaf_tex")
	assert_eq(d.overview.kind, "canopy")


func test_total_gpu_bytes_counts_shared_dependencies_once() -> void:
	var d: RenderAssetDescriptor = _parse()[0]
	assert_eq(d.total_gpu_bytes(["selected", "near", "mid"], "low"), 90000 + 43690, "selected aliases one mesh")
	assert_eq(d.total_gpu_bytes(["selected", "far", "ghost"], "low"), 90000 + 600 + 43690)
	assert_eq(d.total_gpu_bytes(["far"], "preview"), 600 + 699050)
	assert_eq(d.total_gpu_bytes([], "low"), 43690, "textures of the materials are always required")


func test_schema_failures() -> void:
	var cases := {
		"unsupported_version": func(d: Dictionary) -> void: d.schema_version = 2,
		"descriptor_invalid_unknown_key": func(d: Dictionary) -> void: d.surprise = 1,
		"descriptor_invalid_missing_key": func(d: Dictionary) -> void: d.erase("license"),
		"descriptor_invalid_float_version": func(d: Dictionary) -> void: d.asset_version = 1.5,
		"descriptor_invalid_bool_version": func(d: Dictionary) -> void: d.asset_version = true,
		"descriptor_invalid_category": func(d: Dictionary) -> void: d.category = "trees",
		"descriptor_invalid_hash": func(d: Dictionary) -> void: d.source_content_hash = "AB".repeat(32),
		"descriptor_invalid_bounds_string": func(d: Dictionary) -> void: d.bounds_max_m = [1.0, "NaN", 1.0],
		"descriptor_invalid_bounds_inf": func(d: Dictionary) -> void: d.bounds_max_m = [1.0, INF, 1.0],
		"descriptor_invalid_bounds_nan": func(d: Dictionary) -> void: d.bounds_min_m = [NAN, 0.0, 0.0],
		"descriptor_invalid_bounds_order": func(d: Dictionary) -> void: d.bounds_min_m = [2.0, 0.0, 0.0],
		"descriptor_invalid_footprint": func(d: Dictionary) -> void: d.footprint_radius_m = 0.0,
		"descriptor_invalid_zero_triangles": func(d: Dictionary) -> void: d.representations.far.triangles = 0,
		"descriptor_invalid_fraction_triangles": func(d: Dictionary) -> void: d.representations.far.triangles = 4.5,
		"descriptor_invalid_surfaces": func(d: Dictionary) -> void: d.representations.far.surfaces = 9,
		"descriptor_invalid_aabb": func(d: Dictionary) -> void: d.representations.far.aabb_max_m = [-5.0, 4.0, 1.0],
		"descriptor_invalid_overview": func(d: Dictionary) -> void: d.overview.height_m = 0.0,
		"descriptor_invalid_color": func(d: Dictionary) -> void: d.overview.color = [0.1, 1.2, 0.0],
		"descriptor_invalid_npot": func(d: Dictionary) -> void: d.textures.leaf_tex.low.width = 100,
		"descriptor_invalid_low_too_big": func(d: Dictionary) -> void: d.textures.leaf_tex.low.width = 1024,
		"descriptor_invalid_no_mipmaps": func(d: Dictionary) -> void: d.textures.leaf_tex.low.mipmaps = false,
		"descriptor_invalid_alpha": func(d: Dictionary) -> void: d.materials.leaf.alpha_mode = "blend",
		"descriptor_invalid_unlisted_material": func(d: Dictionary) -> void: d.materials = {},
		"descriptor_invalid_unsorted_deps": func(d: Dictionary) -> void: d.dependencies.reverse(),
		"descriptor_invalid_dup_path": func(d: Dictionary) -> void: d.dependencies[1].path = "a.tres",
		"descriptor_invalid_dep_bytes": func(d: Dictionary) -> void: d.dependencies[0].bytes = 0,
		"descriptor_invalid_dep_sha": func(d: Dictionary) -> void: d.dependencies[0].sha256 = "abc",
	}
	for name: String in cases:
		var want := "unsupported_version" if name.begins_with("unsupported_version") else "descriptor_invalid"
		assert_eq(_reason(cases[name]), want, name)
	assert_eq(_reason(func(d: Dictionary) -> void:
		d.schema_version = 2
		d.surprise = 1), "unsupported_version", "a newer schema may carry other keys")


func test_alias_rules() -> void:
	assert_eq(_reason(func(d: Dictionary) -> void:
		d.representations.selected = {"alias": "near"}
		d.representations.near = {"alias": "selected"}), "descriptor_invalid", "cycle")
	assert_eq(_reason(func(d: Dictionary) -> void: d.representations.selected = {"alias": "selected"}), "descriptor_invalid", "self alias")
	assert_eq(_reason(func(d: Dictionary) -> void:
		d.representations.ghost = {"alias": "mid"}
		d.representations.mid = {"alias": "near"}
		d.representations.near = {"alias": "far"}), "descriptor_invalid", "chain of 3")
	assert_eq(_reason(func(d: Dictionary) -> void:
		d.representations.ghost = {"alias": "near"}
		d.representations.near = {"alias": "far"}), "(accepted)", "chain of 2")
	assert_eq(_reason(func(d: Dictionary) -> void: d.representations.erase("mid")), "descriptor_invalid", "missing role")
	assert_eq(_reason(func(d: Dictionary) -> void: d.representations.extra = {"alias": "far"}), "descriptor_invalid", "extra role")
	assert_eq(_reason(func(d: Dictionary) -> void: d.representations.far.mesh = "nope"), "descriptor_invalid", "unknown key")
	assert_eq(_reason(func(d: Dictionary) -> void: d.representations.far.mesh = "mat_a"), "descriptor_invalid", "wrong dependency type")
	assert_eq(_reason(func(d: Dictionary) -> void: d.representations.near = {"alias": "bogus"}), "descriptor_invalid", "unknown role")


func test_path_rules_reject_unsafe_dependencies() -> void:
	for bad: String in ["../x.tres", "a/../x.tres", "/abs/x.tres", "res://x.tres", "user://x.tres", "a\\b.tres",
			"a//b.tres", "./x.tres", "", "x.tscn", "x.tres.tscn", "c:x.tres"]:
		assert_eq(_reason(func(d: Dictionary) -> void: d.dependencies[0].path = bad), "path_rejected", "path '%s'" % bad)
	assert_eq(_reason(func(d: Dictionary) -> void:
		d.dependencies[0].type = "mesh"
		d.dependencies[0].path = "scene.tscn"), "path_rejected", "scene dependency (ASSET-06)")
	assert_eq(_reason(func(d: Dictionary) -> void: d.dependencies[3].path = "low.tres"), "path_rejected", "texture must be png")
	assert_eq(_reason(func(d: Dictionary) -> void: d.dependencies[0].path = "a.png"), "path_rejected", "material must be tres")
	assert_eq(_reason(func(d: Dictionary) -> void: d.dependencies[0].path = 5), "path_rejected", "non-string path")
	assert_eq(_reason(func(d: Dictionary) -> void: d.dependencies[0].type = "scene"), "descriptor_invalid", "unknown type")


func test_parse_is_pure_and_error_free() -> void:
	# Hostile shapes must produce error strings, never script errors (the runner fails on logged errors).
	for bad: Variant in [null, 5, "x", [], {}, {"schema_version": "1"}, {"schema_version": 1}]:
		var r := RenderAssetDescriptor.parse(bad, "res://x")
		assert_true(r[0] == null and r[1] != "", "rejects %s" % str(bad))
	var d := RenderAssetFixture.vector_descriptor()
	d.dependencies = "none"
	assert_eq(RenderAssetDescriptor.error_reason(RenderAssetDescriptor.parse(d, "x")[1]), "descriptor_invalid")
	d = RenderAssetFixture.vector_descriptor()
	d.representations.far = 7
	assert_eq(RenderAssetDescriptor.error_reason(RenderAssetDescriptor.parse(d, "x")[1]), "descriptor_invalid")
	d = RenderAssetFixture.vector_descriptor()
	d.textures.leaf_tex = {"low": null, "preview": null}
	assert_eq(RenderAssetDescriptor.error_reason(RenderAssetDescriptor.parse(d, "x")[1]), "descriptor_invalid")


func test_derivative_hash_changes_with_every_hashed_field() -> void:
	var base: String = (_parse()[0] as RenderAssetDescriptor).compute_derivative_hash()
	var changes := [
		func(d: Dictionary) -> void: d.asset_version = 4,
		func(d: Dictionary) -> void: d.vegetation = false,
		func(d: Dictionary) -> void: d.representations.far.triangles = 45,
		func(d: Dictionary) -> void: d.representations.ghost = {"alias": "selected"},
		func(d: Dictionary) -> void: d.dependencies[0].bytes = 11,
		func(d: Dictionary) -> void: d.dependencies[0].sha256 = "9".repeat(64),
		func(d: Dictionary) -> void: d.materials.leaf.alpha_mode = "opaque",
		func(d: Dictionary) -> void: d.textures.leaf_tex.preview = null,
		func(d: Dictionary) -> void: d.textures.leaf_tex.low.width = 128,
	]
	for i in changes.size():
		var r := _parse(changes[i])
		if assert_empty_string(r[1], "mutation %d parses" % i):
			assert_ne((r[0] as RenderAssetDescriptor).compute_derivative_hash(), base, "mutation %d" % i)
