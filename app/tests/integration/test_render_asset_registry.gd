extends TestCase
## RenderAssetRegistry (docs/render-assets.md §1-§4): real files in a scratch directory.

const ID := RenderAssetFixture.ASSET_ID


func _reason(fx: RenderAssetFixture, mutate_desc: Callable = Callable(), mutate_index: Callable = Callable(),
		fix_hashes: bool = true) -> String:
	fx.write(mutate_desc, mutate_index, fix_hashes)
	return fx.load_registry().status(ID).reason


func test_valid_registry_is_ready() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	fx.write()
	var reg := fx.load_registry()
	assert_eq(reg.error(), "")
	assert_eq(reg.catalog_id(), "test_cat")
	assert_eq(reg.status(ID).state, "READY", str(reg.status(ID)))
	assert_true(reg.is_ready(ID))
	assert_eq(reg.ready_ids(), PackedStringArray([ID]))
	var d := reg.descriptor(ID)
	assert_true(d != null)
	assert_eq(d.dependency("mesh_sel").path, fx.dep_path("sel.tres"))
	assert_eq(reg.descriptor("unknown"), null)
	assert_eq(reg.status("unknown").state, "NOT_READY")


func test_empty_registry_marks_everything_not_ready() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	var reg := RenderAssetRegistry.empty_for(fx.catalog())
	assert_eq(reg.status(ID).state, "NOT_READY")
	assert_eq(reg.status(ID).reason, "no_registry")
	assert_false(reg.is_ready(ID))
	assert_eq(reg.ready_ids().size(), 0)


func test_index_level_failures_make_every_asset_not_ready() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	assert_eq(fx.load_registry().status(ID).reason, "no_registry", "missing index file")
	var cases := [
		["catalog_mismatch", func(i: Dictionary) -> void: i.catalog_version = 3],
		["catalog_mismatch", func(i: Dictionary) -> void: i.catalog_id = "other"],
		["unsupported_version", func(i: Dictionary) -> void: i.schema_version = 2],
		["no_registry", func(i: Dictionary) -> void: i.extra = 1],
		["no_registry", func(i: Dictionary) -> void: i.assets.append(i.assets[0].duplicate())],
		["no_registry", func(i: Dictionary) -> void: i.assets[0].erase("descriptor_sha256")],
		["no_registry", func(i: Dictionary) -> void: i.format = "nope"],
	]
	for i in cases.size():
		fx.write(Callable(), cases[i][1])
		var reg := fx.load_registry()
		assert_eq(reg.status(ID).reason, cases[i][0], "index case %d" % i)
		assert_false(reg.is_ready(ID), "index case %d" % i)
		assert_true(reg.error() != "", "index case %d" % i)


func test_bad_json_index() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	fx.write()
	var f := FileAccess.open(fx.index_path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var reg := fx.load_registry()
	assert_eq(reg.status(ID).reason, "no_registry")
	assert_true(reg.error().contains("JSON"))


func test_asset_without_entry_is_no_derivative() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	assert_eq(_reason(fx, Callable(), func(i: Dictionary) -> void: i.assets = []), "no_derivative")


static func _scene_dependency(d: Dictionary) -> void:
	d.dependencies[0].type = "mesh"
	d.dependencies[0].path = "x.tscn"


static func _alias_cycle(d: Dictionary) -> void:
	d.representations.selected = {"alias": "near"}
	d.representations.near = {"alias": "selected"}


func test_descriptor_level_reasons() -> void:
	var cases := [
		["descriptor_invalid", func(d: Dictionary) -> void: d.surprise = 1],
		["unsupported_version", func(d: Dictionary) -> void: d.schema_version = 2],
		["path_rejected", func(d: Dictionary) -> void: d.dependencies[0].path = "../x.tres"],
		["path_rejected", func(d: Dictionary) -> void: d.dependencies[0].path = "/etc/x.tres"],
		["path_rejected", _scene_dependency],
		["descriptor_invalid", func(d: Dictionary) -> void: d.representations.far.triangles = 0],
		["descriptor_invalid", func(d: Dictionary) -> void: d.bounds_max_m = [1.0, "NaN", 1.0]],
		["logical_mismatch", func(d: Dictionary) -> void: d.bounds_max_m = [1.0, 1.0e30, 1.0]],
		["descriptor_invalid", _alias_cycle],
		["descriptor_invalid", func(d: Dictionary) -> void: d.representations.erase("mid")],
		["descriptor_invalid", func(d: Dictionary) -> void: d.representations.far.mesh = "nope"],
		["source_changed", func(d: Dictionary) -> void: d.source_content_hash = "0".repeat(64)],
		["logical_mismatch", func(d: Dictionary) -> void: d.anchor_local_m = [0.0, 0.101, 0.0]],
		["logical_mismatch", func(d: Dictionary) -> void: d.bounds_max_m = [1.0, 4.001, 1.0]],
		["logical_mismatch", func(d: Dictionary) -> void: d.footprint_radius_m = 1.5],
		["logical_mismatch", func(d: Dictionary) -> void: d.asset_id = "nature.tree.other"],
	]
	for i in cases.size():
		var fx := RenderAssetFixture.new(scratch_dir().path_join("c%d" % i))
		assert_eq(_reason(fx, cases[i][1]), cases[i][0], "descriptor case %d" % i)
		assert_false(fx.load_registry().is_ready(ID), "descriptor case %d" % i)


func test_small_anchor_difference_is_tolerated() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	assert_eq(_reason(fx, func(d: Dictionary) -> void: d.anchor_local_m = [0.0, 0.1 + 1e-8, 0.0]), "", "within 1e-6")


func test_hash_failures() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	assert_eq(_reason(fx, func(d: Dictionary) -> void: d.derivative_hash = "0".repeat(64), Callable(), false),
		"derivative_hash_mismatch")
	assert_eq(_reason(fx, Callable(), func(i: Dictionary) -> void: i.assets[0].descriptor_sha256 = "0".repeat(64)),
		"descriptor_hash_mismatch")
	assert_eq(_reason(fx, Callable(), func(i: Dictionary) -> void: i.assets[0].descriptor = "../descriptor.json"),
		"path_rejected")
	assert_eq(_reason(fx, Callable(), func(i: Dictionary) -> void: i.assets[0].descriptor = "pine/missing.json"),
		"no_derivative")


func test_catalog_identity_failures() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	fx.write()
	fx.asset_version = 2
	var reg := RenderAssetRegistry.load_from(fx.index_path, fx.catalog())
	assert_eq(reg.status(ID).reason, "logical_mismatch", "catalog has another asset version")
	fx.asset_version = 1
	fx.write()
	fx.preview = "changed scene".to_utf8_buffer()
	var f := FileAccess.open(fx.dir.path_join("models/pine.tscn"), FileAccess.WRITE)
	f.store_buffer(fx.preview)
	f.close()
	assert_eq(RenderAssetRegistry.load_from(fx.index_path, fx.catalog()).status(ID).reason, "source_changed")


func test_dependency_failures() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	fx.write()
	var f := FileAccess.open(fx.dep_path("far.tres"), FileAccess.WRITE)
	f.store_string("tampered")
	f.close()
	assert_eq(fx.load_registry().status(ID).reason, "dependency_hash_mismatch")
	fx.write()
	DirAccess.remove_absolute(fx.dep_path("low.png"))
	assert_eq(fx.load_registry().status(ID).reason, "dependency_missing")
	fx.write()
	DirAccess.remove_absolute(fx.dep_path("sel.tres"))
	assert_eq(fx.load_registry().status(ID).reason, "dependency_missing")


func test_not_ready_asset_never_loads_a_resource() -> void:
	# ASSET-01: a broken derivative must not trigger any ResourceLoader load of its files.
	var fx := RenderAssetFixture.new(scratch_dir())
	fx.write(func(d: Dictionary) -> void: d.dependencies[2].sha256 = "0".repeat(64))
	var reg := fx.load_registry()
	assert_false(reg.is_ready(ID))
	for name: String in fx.files:
		assert_false(ResourceLoader.has_cached(fx.dep_path(name)), name)
	assert_false(ResourceLoader.has_cached(fx.dir.path_join("models/pine.tscn")), "source scene is never loaded")
	fx.write(func(d: Dictionary) -> void: d.dependencies[0].path = "../x.tres")
	reg = fx.load_registry()
	for name: String in fx.files:
		assert_false(ResourceLoader.has_cached(fx.dep_path(name)), name)
	assert_eq(reg.descriptor(ID), null)


func test_unreadable_source_is_source_changed() -> void:
	var fx := RenderAssetFixture.new(scratch_dir())
	fx.write()
	DirAccess.remove_absolute(fx.dir.path_join("models/pine_scatter.tres"))
	assert_eq(fx.load_registry().status(ID).reason, "source_changed")
