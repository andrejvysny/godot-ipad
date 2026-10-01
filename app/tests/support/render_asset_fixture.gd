class_name RenderAssetFixture
extends RefCounted
## Writes a one-asset logical catalog, its source files, a descriptor, dependency files and an
## index under a scratch directory, so registry tests can mutate any layer. Mirrors RegistryBuilder
## in scripts/tests/test_render_assets.py.

const ASSET_ID := "nature.tree.pine"

var dir: String
var files: Dictionary = {}  # dependency file name -> bytes
var preview := "[gd_scene]\nscene".to_utf8_buffer()
var scatter := "[gd_resource]\nscatter".to_utf8_buffer()
var catalog_version := 2
var asset_version := 1
var index_path: String


func _init(scratch: String) -> void:
	dir = scratch
	index_path = dir.path_join("render_assets/index.json")
	files = {"sel.tres": "mesh-sel".to_utf8_buffer(), "far.tres": "mesh-far".to_utf8_buffer(),
		"mat.tres": "material".to_utf8_buffer(), "low.png": "png-low".to_utf8_buffer(),
		"prev.png": "png-prev".to_utf8_buffer()}


## The same descriptor as scripts/tests/test_render_assets.py vector_descriptor() (hash vector).
static func vector_descriptor() -> Dictionary:
	var aabb := {"aabb_min_m": [-1.0, 0.0, -1.0], "aabb_max_m": [1.0, 4.0, 1.0]}
	var sel := {"mesh": "mesh_sel", "triangles": 1536, "surfaces": 2}
	var far := {"mesh": "mesh_far", "triangles": 44, "surfaces": 1}
	sel.merge(aabb)
	far.merge(aabb)
	return {
		"format": "world-painter-render-asset", "schema_version": 1, "asset_id": "vec.asset", "asset_version": 3,
		"source_content_hash": "ab".repeat(32), "derivative_hash": "cd".repeat(32), "category": "tree",
		"vegetation": true, "decorative": false,
		"anchor_local_m": [0.0, 0.0, 0.0], "bounds_min_m": [-1.0, 0.0, -1.0], "bounds_max_m": [1.0, 4.0, 1.0],
		"footprint_radius_m": 1.0,
		"representations": {"selected": sel, "near": {"alias": "selected"}, "mid": {"alias": "selected"},
			"far": far, "ghost": {"alias": "far"}},
		"overview": {"kind": "canopy", "shape": "cone", "base_y_m": 1.0, "height_m": 3.0, "radius_m": 1.0,
			"color": [0.1, 0.3, 0.2]},
		"materials": {"leaf": {"dependency": "mat_a", "alpha_mode": "cutout", "texture": "leaf_tex"}},
		"textures": {"leaf_tex": {
			"low": {"dependency": "tex_low", "width": 256, "height": 128, "mipmaps": true},
			"preview": {"dependency": "tex_prev", "width": 1024, "height": 512, "mipmaps": true}}},
		"dependencies": [
			_dep("mat_a", "material", "a.tres", 10, "1", 0, 0),
			_dep("mesh_far", "mesh", "far.tres", 20, "2", 600, 600),
			_dep("mesh_sel", "mesh", "sel.tres", 30, "3", 90000, 90000),
			_dep("tex_low", "texture", "low.png", 40, "4", 43690, 131072),
			_dep("tex_prev", "texture", "prev.png", 50, "5", 699050, 2097152)],
		"provenance": "vector", "license": "CC0-1.0"}


static func _dep(key: String, type: String, path: String, size: int, fill: String, gpu: int, staging: int) -> Dictionary:
	return {"key": key, "type": type, "path": path, "bytes": size, "sha256": fill.repeat(64),
		"gpu_bytes": gpu, "staging_bytes": staging}


func descriptor_dict() -> Dictionary:
	var d := vector_descriptor()
	d.asset_id = ASSET_ID
	d.asset_version = asset_version
	d.anchor_local_m = [0.0, 0.1, 0.0]
	d.source_content_hash = RenderAssetDescriptor.source_content_hash_of(ASSET_ID, asset_version,
		CanonicalEncoder.sha256(preview), CanonicalEncoder.sha256(scatter))
	var names := {"mat_a": "mat.tres", "mesh_far": "far.tres", "mesh_sel": "sel.tres", "tex_low": "low.png",
		"tex_prev": "prev.png"}
	for dep: Dictionary in d.dependencies:
		dep.path = names[dep.key]
		var raw: PackedByteArray = files[dep.path]
		dep.bytes = raw.size()
		dep.sha256 = CanonicalEncoder.sha256_hex(raw)
	d.textures.leaf_tex.low.width = 8
	d.textures.leaf_tex.low.height = 4
	d.textures.leaf_tex.preview.width = 16
	d.textures.leaf_tex.preview.height = 8
	return d


func dep_path(name: String) -> String:
	return dir.path_join("render_assets/pine").path_join(name)


func catalog() -> AssetCatalog:
	var fields := {"asset_id": ASSET_ID, "version": asset_version, "category": "trees",
		"preview_scene": dir.path_join("models/pine.tscn"), "scatter_mesh": dir.path_join("models/pine_scatter.tres"),
		"bounds": AABB(Vector3(-1, 0, -1), Vector3(2, 4, 2)), "anchor_local": Vector3(0, 0.1, 0),
		"footprint_radius_m": 1.0}
	return AssetCatalog.from_plain({"catalog_id": "test_cat", "catalog_version": catalog_version, "sha256": "0".repeat(64),
		"assets": {ASSET_ID: fields}})


## Writes everything; mutators edit the dictionaries in place before they are serialised.
func write(mutate_desc: Callable = Callable(), mutate_index: Callable = Callable(), fix_hashes: bool = true) -> void:
	DirAccess.make_dir_recursive_absolute(dir.path_join("models"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("render_assets/pine"))
	_store(dir.path_join("models/pine.tscn"), preview)
	_store(dir.path_join("models/pine_scatter.tres"), scatter)
	for name: String in files:
		_store(dep_path(name), files[name])
	var d := descriptor_dict()
	if mutate_desc.is_valid():
		mutate_desc.call(d)
	if fix_hashes:
		var parsed := RenderAssetDescriptor.parse(d, "x")
		if parsed[0] != null:
			d.derivative_hash = (parsed[0] as RenderAssetDescriptor).compute_derivative_hash()
	var raw := JSON.stringify(d, "\t").to_utf8_buffer()
	_store(dep_path("descriptor.json"), raw)
	var index := {"format": "world-painter-render-assets", "schema_version": 1, "catalog_id": "test_cat",
		"catalog_version": catalog_version, "prepared_for": {"godot": "4.7.2", "renderer": "mobile",
		"texture_formats": ["etc2_astc"]}, "assets": [{"asset_id": ASSET_ID, "asset_version": asset_version,
		"descriptor": "pine/descriptor.json", "descriptor_sha256": CanonicalEncoder.sha256_hex(raw)}]}
	if mutate_index.is_valid():
		mutate_index.call(index)
	_store(index_path, JSON.stringify(index, "\t").to_utf8_buffer())


func load_registry() -> RenderAssetRegistry:
	return RenderAssetRegistry.load_from(index_path, catalog())


func _store(path: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
