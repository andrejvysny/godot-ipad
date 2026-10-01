class_name AssetCatalog
extends RefCounted
## Trusted bundled asset catalog (spec §3.3, §10.3). Loaded strictly: any malformed entry
## rejects the whole catalog. `sha256` is the catalog content hash of docs/world-format.md §6,
## computed over raw file bytes so JSON float parsing never affects it.

const CATALOG_FILE := "catalog.json"
const CATALOG_MAGIC := "WPOC-CATALOG-V1\n"
const TRUSTED_PREFIX := "res://assets/"
const TOP_KEYS := ["catalog_id", "catalog_version", "assets"]
const ASSET_KEYS := ["asset_id", "version", "display_name", "category", "preview_scene",
	"scatter_mesh", "thumbnail", "bounds_min", "bounds_max", "placement_anchor_local",
	"footprint_radius_m", "scale_min", "scale_max", "height_offset_min_m",
	"height_offset_max_m", "default_grounding", "scatter_allowed", "provenance", "license"]

var catalog_id: String = ""
var catalog_version: int = 0
var sha256: String = ""
var _assets: Dictionary = {}  # asset_id -> AssetDefinition


## Returns [AssetCatalog, ""] or [null, error].
static func load_from(res_dir: String = "res://assets") -> Array:
	var path := res_dir.path_join(CATALOG_FILE)
	var read := _read_bytes(path)
	if read[1] != "":
		return [null, read[1]]
	var raw: PackedByteArray = read[0]
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		return [null, "catalog %s is not valid JSON (line %d: %s)" % [path, json.get_error_line(), json.get_error_message()]]
	var cat := AssetCatalog.new()
	var err := cat._parse(json.data)
	if err != "":
		return [null, "catalog %s: %s" % [path, err]]
	var h := cat._compute_hash(raw)
	if h[1] != "":
		return [null, "catalog %s: %s" % [path, h[1]]]
	cat.sha256 = h[0]
	return [cat, ""]


## Plain-value copy (Strings, numbers, Vector3/AABB, Dictionaries) so the storage worker can
## rebuild its own private catalog instead of sharing this object across threads.
func to_plain() -> Dictionary:
	var assets := {}
	for id in _assets:
		var a: AssetDefinition = _assets[id]
		var fields := {}
		for p in a.get_property_list():
			if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				fields[p.name] = a.get(p.name)
		assets[id] = fields
	return {"catalog_id": catalog_id, "catalog_version": catalog_version, "sha256": sha256, "assets": assets}


## Inverse of to_plain(). The input must come from to_plain() (it is not re-validated).
static func from_plain(d: Dictionary) -> AssetCatalog:
	var cat := AssetCatalog.new()
	cat.catalog_id = d.catalog_id
	cat.catalog_version = d.catalog_version
	cat.sha256 = d.sha256
	for id in d.assets:
		var a := AssetDefinition.new()
		for key in d.assets[id]:
			a.set(key, d.assets[id][key])
		cat._assets[id] = a
	return cat


func get_asset(id: String) -> AssetDefinition:
	return _assets.get(id)


func sorted_ids() -> PackedStringArray:
	var ids := PackedStringArray(_assets.keys())
	ids.sort()
	return ids


func has_compatible(asset_id: String, version: int) -> bool:
	var a := get_asset(asset_id)
	return a != null and a.version == version


## Returns null for an unknown id. Main thread only (instantiates scene nodes).
func instantiate_preview(id: String) -> Node3D:
	var a := get_asset(id)
	if a == null:
		return null
	var scene := load(a.preview_scene) as PackedScene
	if scene == null:
		return null
	return scene.instantiate() as Node3D


func _parse(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "root is not an object"
	var key_err := _check_keys(data, TOP_KEYS, "catalog")
	if key_err != "":
		return key_err
	if typeof(data.catalog_id) != TYPE_STRING or data.catalog_id == "":
		return "catalog_id must be a non-empty string"
	if not _is_int(data.catalog_version) or int(data.catalog_version) < 1:
		return "catalog_version must be a positive integer"
	catalog_id = data.catalog_id
	catalog_version = int(data.catalog_version)
	if typeof(data.assets) != TYPE_ARRAY or data.assets.is_empty():
		return "assets must be a non-empty array"
	for entry in data.assets:
		var parsed := _parse_asset(entry)
		if parsed[1] != "":
			return parsed[1]
		var a: AssetDefinition = parsed[0]
		if _assets.has(a.asset_id):
			return "duplicate asset_id '%s'" % a.asset_id
		_assets[a.asset_id] = a
	return ""


static func _parse_asset(d: Variant) -> Array:
	if typeof(d) != TYPE_DICTIONARY:
		return [null, "asset entry is not an object"]
	var key_err := _check_keys(d, ASSET_KEYS, "asset")
	if key_err != "":
		return [null, key_err]
	if typeof(d.asset_id) != TYPE_STRING or d.asset_id == "":
		return [null, "asset_id must be a non-empty string"]
	var a := AssetDefinition.new()
	a.asset_id = d.asset_id
	var tag := " (asset %s)" % a.asset_id
	var err := _parse_scalars(a, d)
	if err == "":
		err = _parse_geometry(a, d)
	if err == "":
		err = _parse_limits(a, d)
	if err == "":
		err = _check_paths(a)
	return [null, err + tag] if err != "" else [a, ""]


static func _parse_scalars(a: AssetDefinition, d: Dictionary) -> String:
	if not _is_int(d.version) or int(d.version) < 1:
		return "version must be a positive integer"
	a.version = int(d.version)
	for key in ["display_name", "category", "preview_scene", "thumbnail", "provenance", "license"]:
		if typeof(d[key]) != TYPE_STRING or d[key] == "":
			return "%s must be a non-empty string" % key
	a.display_name = d.display_name
	a.category = d.category
	a.preview_scene = d.preview_scene
	a.thumbnail = d.thumbnail
	a.provenance = d.provenance
	a.license = d.license
	if d.scatter_mesh == null:
		a.scatter_mesh = ""
	elif typeof(d.scatter_mesh) == TYPE_STRING and d.scatter_mesh != "":
		a.scatter_mesh = d.scatter_mesh
	else:
		return "scatter_mesh must be null or a non-empty string"
	if typeof(d.default_grounding) != TYPE_STRING or (d.default_grounding != WorldConstants.GROUNDING_FOLLOW \
			and d.default_grounding != WorldConstants.GROUNDING_FIXED):
		return "default_grounding '%s' is not allowed" % str(d.default_grounding)
	a.default_grounding = d.default_grounding
	if typeof(d.scatter_allowed) != TYPE_BOOL:
		return "scatter_allowed must be a boolean"
	a.scatter_allowed = d.scatter_allowed
	return ""


static func _parse_geometry(a: AssetDefinition, d: Dictionary) -> String:
	var bmin: Variant = _vec3(d.bounds_min)
	var bmax: Variant = _vec3(d.bounds_max)
	if bmin == null or bmax == null:
		return "bounds_min/bounds_max must be 3 finite numbers"
	if not (bmin.x < bmax.x and bmin.y < bmax.y and bmin.z < bmax.z):
		return "bounds_min must be below bounds_max on every axis"
	a.bounds = AABB(bmin, bmax - bmin)
	var anchor: Variant = _vec3(d.placement_anchor_local)
	if anchor == null:
		return "placement_anchor_local must be 3 finite numbers"
	a.anchor_local = anchor
	return ""


static func _parse_limits(a: AssetDefinition, d: Dictionary) -> String:
	for key in ["footprint_radius_m", "scale_min", "scale_max", "height_offset_min_m", "height_offset_max_m"]:
		if not _is_number(d[key]):
			return "%s must be a finite number" % key
	a.footprint_radius_m = float(d.footprint_radius_m)
	a.scale_min = float(d.scale_min)
	a.scale_max = float(d.scale_max)
	a.height_offset_min_m = float(d.height_offset_min_m)
	a.height_offset_max_m = float(d.height_offset_max_m)
	if a.footprint_radius_m <= 0.0:
		return "footprint_radius_m must be positive"
	if a.scale_min <= 0.0 or a.scale_max <= 0.0:
		return "scale bounds must be positive"
	if a.scale_min > a.scale_max:
		return "scale_min exceeds scale_max"
	if a.height_offset_min_m > a.height_offset_max_m:
		return "height_offset_min_m exceeds height_offset_max_m"
	return ""


static func _check_paths(a: AssetDefinition) -> String:
	for p in [a.preview_scene, a.thumbnail, a.scatter_mesh]:
		if p != "" and not _is_trusted_path(p):
			return "path '%s' is not under %s" % [p, TRUSTED_PREFIX]
	for p in _geometry_paths_of(a):
		if not ResourceLoader.exists(p):
			return "geometry file '%s' does not exist" % p
		var read := _read_bytes(p)
		if read[1] != "":
			return read[1]
		var err := self_contained_error(p, (read[0] as PackedByteArray).get_string_from_utf8())
		if err != "":
			return err
	return ""


## Model scenes must be self-contained text resources (docs/world-format.md §6).
static func self_contained_error(path: String, text: String) -> String:
	if text.contains("[ext_resource"):
		return "geometry file '%s' is not self-contained (ext_resource)" % path
	return ""


static func _geometry_paths_of(a: AssetDefinition) -> PackedStringArray:
	var out := PackedStringArray([a.preview_scene])
	if a.scatter_mesh != "":
		out.append(a.scatter_mesh)
	return out


func _compute_hash(catalog_bytes: PackedByteArray) -> Array:
	var paths := PackedStringArray()
	for id in _assets:
		for p in _geometry_paths_of(_assets[id]):
			if not paths.has(p):
				paths.append(p)
	paths.sort()
	var e := CanonicalEncoder.new()
	e.put_raw(CATALOG_MAGIC.to_ascii_buffer())
	e.put_str(CATALOG_FILE)
	e.put_raw(CanonicalEncoder.sha256(catalog_bytes))
	e.put_u32(paths.size())
	for p in paths:
		var read := _read_bytes(p)
		if read[1] != "":
			return ["", read[1]]
		e.put_str(p)
		e.put_raw(CanonicalEncoder.sha256(read[0]))
	return [CanonicalEncoder.sha256_hex(e.bytes()), ""]


static func _is_trusted_path(p: String) -> bool:
	return p.begins_with(TRUSTED_PREFIX) and not p.contains("\\") \
		and not p.substr(TRUSTED_PREFIX.length()).split("/").has("..")


static func _check_keys(d: Dictionary, keys: Array, what: String) -> String:
	for k in keys:
		if not d.has(k):
			return "%s missing field '%s'" % [what, k]
	for k in d:
		if not keys.has(k):
			return "%s has unknown field '%s'" % [what, str(k)]
	return ""


static func _read_bytes(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [PackedByteArray(), "cannot read '%s' (error %d)" % [path, FileAccess.get_open_error()]]
	return [f.get_buffer(f.get_length()), ""]


static func _is_number(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func _is_int(v: Variant) -> bool:
	return _is_number(v) and float(v) == floorf(float(v))


static func _vec3(v: Variant) -> Variant:
	if typeof(v) != TYPE_ARRAY or v.size() != 3:
		return null
	for x in v:
		if not _is_number(x):
			return null
	return Vector3(v[0], v[1], v[2])
