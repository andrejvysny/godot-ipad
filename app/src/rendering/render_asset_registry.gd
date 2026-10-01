class_name RenderAssetRegistry
extends RefCounted
## Validated render-asset index for one logical catalog (docs/render-assets.md §1-§4).
## load_from() never throws and never logs: whole-index problems make every catalog asset
## NOT_READY, per-asset problems only that asset. A NOT_READY asset never triggers a resource
## load (only FileAccess reads and ResourceLoader.exists are used here).

const FORMAT := "world-painter-render-assets"
const SCHEMA_VERSION := 1
const TOP_KEYS := ["format", "schema_version", "catalog_id", "catalog_version", "prepared_for", "assets"]
const PREPARED_KEYS := ["godot", "renderer", "texture_formats"]
const ENTRY_KEYS := ["asset_id", "asset_version", "descriptor", "descriptor_sha256"]
const TOLERANCE := 1e-6

var _catalog_id: String = ""
var _error: String = ""
var _status: Dictionary = {}  # asset_id -> {"state", "reason", "detail"}
var _descriptors: Dictionary = {}  # asset_id -> RenderAssetDescriptor (READY only)
var _file_sha: Dictionary = {}  # res path -> raw sha256 (empty when unreadable)


static func empty_for(catalog: AssetCatalog) -> RenderAssetRegistry:
	var r := RenderAssetRegistry.new()
	r._catalog_id = catalog.catalog_id
	r._error = "no registry"
	r._fail_all(catalog, "no_registry", r._error)
	return r


static func load_from(index_path: String, catalog: AssetCatalog) -> RenderAssetRegistry:
	var r := RenderAssetRegistry.new()
	r._catalog_id = catalog.catalog_id
	r._load(index_path, catalog)
	return r


func status(asset_id: String) -> Dictionary:
	return _status.get(asset_id, {"state": "NOT_READY", "reason": "no_derivative", "detail": "unknown asset"})


func is_ready(asset_id: String) -> bool:
	return _descriptors.has(asset_id)


## Null unless the asset is READY.
func descriptor(asset_id: String) -> RenderAssetDescriptor:
	return _descriptors.get(asset_id)


func ready_ids() -> PackedStringArray:
	var ids := PackedStringArray(_descriptors.keys())
	ids.sort()
	return ids


func catalog_id() -> String:
	return _catalog_id


## Index-level problem ("" when the index itself was accepted).
func error() -> String:
	return _error


func _fail_all(catalog: AssetCatalog, reason: String, detail: String) -> void:
	for id in catalog.sorted_ids():
		_set_not_ready(id, reason, detail)


func _set_not_ready(id: String, reason: String, detail: String) -> void:
	_descriptors.erase(id)
	_status[id] = {"state": "NOT_READY", "reason": reason, "detail": detail}


func _load(index_path: String, catalog: AssetCatalog) -> void:
	_fail_all(catalog, "no_derivative", "no index entry")
	var read := RenderAssetJson.read_bytes(index_path)
	if read[1] != "":
		_reject_index(catalog, "no_registry", read[1])
		return
	var json := JSON.new()
	if json.parse((read[0] as PackedByteArray).get_string_from_utf8()) != OK:
		_reject_index(catalog, "no_registry", "index is not valid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()])
		return
	var idx := _check_index(json.data, catalog)
	if idx[0] != "":
		_reject_index(catalog, idx[0], idx[1])
		return
	var index_dir := index_path.get_base_dir()
	for entry in json.data.assets:
		_load_asset(entry, index_dir, catalog)


func _reject_index(catalog: AssetCatalog, reason: String, detail: String) -> void:
	_error = detail
	_fail_all(catalog, reason, detail)


## Returns [reason, detail]; reason is "" when the index is acceptable.
func _check_index(data: Variant, catalog: AssetCatalog) -> Array:
	if typeof(data) != TYPE_DICTIONARY:
		return ["no_registry", "index root is not an object"]
	var d: Dictionary = data
	if d.has("schema_version") and RenderAssetJson.is_number(d.schema_version) and float(d.schema_version) != SCHEMA_VERSION:
		return ["unsupported_version", "index schema_version %s is not supported" % str(d.schema_version)]
	var err := RenderAssetJson.check_keys(d, TOP_KEYS, "index")
	if err == "":
		err = _check_index_fields(d)
	if err != "":
		return ["no_registry", err]
	if d.catalog_id != catalog.catalog_id or int(d.catalog_version) != catalog.catalog_version:
		return ["catalog_mismatch", "index is for catalog %s v%s, expected %s v%d" % [
			str(d.catalog_id), str(d.catalog_version), catalog.catalog_id, catalog.catalog_version]]
	return ["", ""]


func _check_index_fields(d: Dictionary) -> String:
	if d.format != FORMAT or not RenderAssetJson.is_int(d.schema_version):
		return "index format must be '%s'" % FORMAT
	if not RenderAssetJson.is_str(d.catalog_id) or not RenderAssetJson.is_int_in(d.catalog_version, 1, 4294967295):
		return "catalog_id/catalog_version are invalid"
	var p: Variant = d.prepared_for
	if typeof(p) != TYPE_DICTIONARY:
		return "prepared_for must be an object"
	var err := RenderAssetJson.check_keys(p, PREPARED_KEYS, "prepared_for")
	if err != "":
		return err
	if not RenderAssetJson.is_str(p.godot) or not RenderAssetJson.is_str(p.renderer) or typeof(p.texture_formats) != TYPE_ARRAY:
		return "prepared_for fields are invalid"
	if typeof(d.assets) != TYPE_ARRAY:
		return "assets must be an array"
	var prev := ""
	for entry in d.assets:
		if typeof(entry) != TYPE_DICTIONARY:
			return "asset entry is not an object"
		err = RenderAssetJson.check_keys(entry, ENTRY_KEYS, "asset entry")
		if err != "":
			return err
		if not RenderAssetJson.is_str(entry.asset_id) or not RenderAssetJson.is_int_in(entry.asset_version, 1, 4294967295) \
				or not RenderAssetJson.is_hex64(entry.descriptor_sha256) or typeof(entry.descriptor) != TYPE_STRING:
			return "asset entry fields are invalid"
		if entry.asset_id <= prev:
			return "assets must be sorted by asset_id with unique ids ('%s')" % entry.asset_id
		prev = entry.asset_id
	return ""


func _load_asset(entry: Dictionary, index_dir: String, catalog: AssetCatalog) -> void:
	var id: String = entry.asset_id
	var res: Variant = _check_asset(entry, index_dir, catalog)
	if res is RenderAssetDescriptor:
		_descriptors[id] = res
		_status[id] = {"state": "READY", "reason": "", "detail": ""}
	else:
		_set_not_ready(id, res[0], res[1])


## Returns the validated RenderAssetDescriptor or [reason, detail].
func _check_asset(entry: Dictionary, index_dir: String, catalog: AssetCatalog) -> Variant:
	var id: String = entry.asset_id
	var perr := RenderAssetJson.path_error(entry.descriptor)
	if perr != "":
		return ["path_rejected", perr]
	var dpath := index_dir.path_join(entry.descriptor)
	var read := RenderAssetJson.read_bytes(dpath)
	if read[1] != "":
		return ["no_derivative", read[1]]
	var raw: PackedByteArray = read[0]
	if CanonicalEncoder.sha256_hex(raw) != entry.descriptor_sha256:
		return ["descriptor_hash_mismatch", "descriptor %s does not match descriptor_sha256" % entry.descriptor]
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		return ["descriptor_invalid", "descriptor %s is not valid JSON" % entry.descriptor]
	var parsed := RenderAssetDescriptor.parse(json.data, dpath.get_base_dir())
	if parsed[1] != "":
		return [RenderAssetDescriptor.error_reason(parsed[1]), (parsed[1] as String).get_slice(": ", 1)]
	var desc: RenderAssetDescriptor = parsed[0]
	var err := _check_identity(desc, entry, catalog)
	if err.is_empty():
		err = _check_hashes(desc)
	if err.is_empty():
		err = _check_dependencies(desc)
	return err if not err.is_empty() else desc


func _check_identity(desc: RenderAssetDescriptor, entry: Dictionary, catalog: AssetCatalog) -> Array:
	if desc.asset_id != entry.asset_id or desc.asset_version != int(entry.asset_version):
		return ["logical_mismatch", "descriptor identity differs from its index entry"]
	var a := catalog.get_asset(desc.asset_id)
	if a == null or a.version != desc.asset_version:
		return ["logical_mismatch", "asset %s v%d is not in the catalog" % [desc.asset_id, desc.asset_version]]
	var src := _source_hash(a)
	if src != desc.source_content_hash:
		return ["source_changed", "source files changed since the derivative was prepared" if src != "" else "source files unreadable"]
	if desc.anchor_local.distance_to(a.anchor_local) > TOLERANCE:
		return ["logical_mismatch", "anchor differs from the catalog"]
	if desc.bounds.position.distance_to(a.bounds.position) > TOLERANCE or desc.bounds.end.distance_to(a.bounds.end) > TOLERANCE:
		return ["logical_mismatch", "bounds differ from the catalog"]
	if absf(desc.footprint_radius_m - a.footprint_radius_m) > TOLERANCE:
		return ["logical_mismatch", "footprint_radius_m differs from the catalog"]
	return []


func _check_hashes(desc: RenderAssetDescriptor) -> Array:
	if desc.compute_derivative_hash() != desc.derivative_hash:
		return ["derivative_hash_mismatch", "derivative_hash does not match the descriptor content"]
	return []


func _check_dependencies(desc: RenderAssetDescriptor) -> Array:
	for dep in desc.dependencies:
		var path: String = dep.path
		if not _dependency_exists(path):
			return ["dependency_missing", "dependency '%s' (%s) does not exist" % [dep.key, dep.rel_path]]
		if (dep.path as String).ends_with(".tres"):
			var read := RenderAssetJson.read_bytes(path)
			var raw: PackedByteArray = read[0]
			if read[1] != "" or raw.size() != int(dep.bytes) or CanonicalEncoder.sha256_hex(raw) != dep.sha256:
				return ["dependency_hash_mismatch", "dependency '%s' (%s) does not match its descriptor entry" % [dep.key, dep.rel_path]]
	return []


## Imported textures are only visible to ResourceLoader under res://; other roots (test scratch
## directories) fall back to a plain file check.
static func _dependency_exists(path: String) -> bool:
	return ResourceLoader.exists(path) or (not path.begins_with("res://") and FileAccess.file_exists(path))


## Hex sha256 of the source files (§3.1), "" when a file cannot be read.
func _source_hash(a: AssetDefinition) -> String:
	var preview := _raw_sha(a.preview_scene)
	var scatter := _raw_sha(a.scatter_mesh) if a.scatter_mesh != "" else PackedByteArray()
	if preview.is_empty() or (a.scatter_mesh != "" and scatter.is_empty()):
		return ""
	return RenderAssetDescriptor.source_content_hash_of(a.asset_id, a.version, preview, scatter)


func _raw_sha(path: String) -> PackedByteArray:
	if not _file_sha.has(path):
		var read := RenderAssetJson.read_bytes(path)
		_file_sha[path] = CanonicalEncoder.sha256(read[0]) if read[1] == "" else PackedByteArray()
	return _file_sha[path]
