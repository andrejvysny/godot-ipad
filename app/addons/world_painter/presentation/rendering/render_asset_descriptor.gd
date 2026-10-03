class_name RenderAssetDescriptor
extends RefCounted
## One validated render-asset descriptor (docs/render-assets.md §2). parse() is pure: no file IO,
## no resource loads. Catalog identity, source hash and dependency files are checked by
## RenderAssetRegistry. Parse errors are "<reason>: detail" with a stable snake_case reason.

const FORMAT := "world-painter-render-asset"
const SCHEMA_VERSION := 1
const SOURCE_MAGIC := "WPRA-SOURCE-V1\n"
const DERIVATIVE_MAGIC := "WPRA-DERIVATIVE-V1\n"
const ROLES := ["selected", "near", "mid", "far", "ghost"]
const CATEGORIES := ["tree", "shrub", "rock", "structure", "ground_cover", "prop"]
const REASONS := ["descriptor_invalid", "unsupported_version", "path_rejected"]
const TOP_KEYS := ["format", "schema_version", "asset_id", "asset_version", "source_content_hash",
	"derivative_hash", "category", "vegetation", "decorative", "anchor_local_m", "bounds_min_m",
	"bounds_max_m", "footprint_radius_m", "representations", "overview", "materials", "textures",
	"dependencies", "provenance", "license"]
const MESH_KEYS := ["mesh", "triangles", "surfaces", "aabb_min_m", "aabb_max_m"]
const OVERVIEW_KEYS := ["kind", "shape", "base_y_m", "height_m", "radius_m", "color"]
const DEP_KEYS := ["key", "type", "path", "bytes", "sha256", "gpu_bytes", "staging_bytes"]
const DEP_TYPES := ["mesh", "material", "texture"]
const TIER_KEYS := ["dependency", "width", "height", "mipmaps"]
const MAX_DEP_BYTES := 64 * 1024 * 1024
const MAX_COST_BYTES := 4294967295
const LOW_MAX_DIM := 512
const PREVIEW_MAX_DIM := 2048

var asset_id: String = ""
var asset_version: int = 0
var source_content_hash: String = ""
var derivative_hash: String = ""
var category: String = ""
var vegetation: bool = false
var decorative: bool = false
var anchor_local := Vector3.ZERO
var bounds := AABB()
var footprint_radius_m: float = 0.0
var roles: Dictionary = {}  # role -> {"mesh", "triangles", "surfaces", "aabb"} after alias resolution
var overview: Dictionary = {}
var materials: Dictionary = {}  # key -> {"dependency", "alpha_mode", "texture" ("" = none)}
var textures: Dictionary = {}  # key -> {"low": tier, "preview": tier or null}; tier {dependency,width,height}
var dependencies: Array = []  # dicts: key, type, rel_path, path (resolved), bytes, sha256, gpu_bytes, staging_bytes
var provenance: String = ""
var license: String = ""
var _aliases: Dictionary = {}  # role -> alias target role ("" for mesh entries)
var _dep_by_key: Dictionary = {}


## Returns [RenderAssetDescriptor, ""] or [null, "<reason>: detail"].
static func parse(data: Variant, descriptor_dir: String) -> Array:
	var d := RenderAssetDescriptor.new()
	var err := d._parse(data, descriptor_dir)
	if err != "":
		return [null, err if _has_reason(err) else "descriptor_invalid: " + err]
	return [d, ""]


static func _has_reason(err: String) -> bool:
	for r in REASONS:
		if err.begins_with(r + ": "):
			return true
	return false


## The stable reason token of a parse() error.
static func error_reason(err: String) -> String:
	return err.get_slice(": ", 0) if _has_reason(err) else "descriptor_invalid"


## §3.1. scatter_sha_raw is empty when the catalog asset has no scatter mesh.
static func source_content_hash_of(asset_id_: String, version: int, preview_scene_sha_raw: PackedByteArray,
		scatter_sha_raw: PackedByteArray) -> String:
	var e := CanonicalEncoder.new()
	e.put_raw(SOURCE_MAGIC.to_ascii_buffer())
	e.put_str(asset_id_)
	e.put_u32(version)
	e.put_raw(preview_scene_sha_raw)
	e.put_u8(0 if scatter_sha_raw.is_empty() else 1)
	e.put_raw(scatter_sha_raw)
	return CanonicalEncoder.sha256_hex(e.bytes())


## Runtime descriptors (RuntimeAssetTiers) add their in-memory dependency entries one by one.
func add_dependency_entry(dep: Dictionary) -> void:
	dependencies.append(dep)
	_dep_by_key[dep.key] = dep


func alias_of(role: String) -> String:
	return _aliases.get(role, "")


## Mesh dependency key of a role ("" for an unknown role).
func resolve_role(role: String) -> String:
	return roles[role].mesh if roles.has(role) else ""


func dependency(key: String) -> Dictionary:
	return _dep_by_key.get(key, {})


## Worst-case GPU bytes to hold the given roles with the textures of "low" or "preview" tier
## (preview falls back to low where a texture has no preview tier). Shared dependencies count once.
func total_gpu_bytes(role_list: Array, texture_tier: String) -> int:
	var keys := {}
	for r in role_list:
		if roles.has(r):
			keys[roles[r].mesh] = true
	for m in materials.values():
		keys[m.dependency] = true
		if m.texture != "":
			var t: Dictionary = textures[m.texture]
			var tier: Variant = t.preview if texture_tier == "preview" and t.preview != null else t.low
			keys[tier.dependency] = true
	var total := 0
	for k in keys:
		total += int(_dep_by_key[k].gpu_bytes)
	return total


## §3.2
func compute_derivative_hash() -> String:
	var e := CanonicalEncoder.new()
	e.put_raw(DERIVATIVE_MAGIC.to_ascii_buffer())
	e.put_str(asset_id)
	e.put_u32(asset_version)
	e.put_raw(source_content_hash.hex_decode())
	e.put_str(category)
	e.put_u8(1 if vegetation else 0)
	e.put_u8(1 if decorative else 0)
	for role in ROLES:
		var alias: String = _aliases[role]
		e.put_str(role)
		e.put_u8(1 if alias != "" else 0)
		e.put_str(alias if alias != "" else roles[role].mesh)
		e.put_u32(0 if alias != "" else int(roles[role].triangles))
		e.put_u32(0 if alias != "" else int(roles[role].surfaces))
	e.put_u32(dependencies.size())
	for dep in dependencies:
		e.put_str(dep.key)
		e.put_str(dep.type)
		e.put_str(dep.rel_path)
		e.put_u64(int(dep.bytes))
		e.put_raw((dep.sha256 as String).hex_decode())
	var mkeys := materials.keys()
	mkeys.sort()
	e.put_u32(mkeys.size())
	for k in mkeys:
		e.put_str(k)
		e.put_str(materials[k].dependency)
		e.put_str(materials[k].alpha_mode)
		e.put_str(materials[k].texture)
	var tkeys := textures.keys()
	tkeys.sort()
	e.put_u32(tkeys.size())
	for k in tkeys:
		var low: Dictionary = textures[k].low
		var prev: Variant = textures[k].preview
		e.put_str(k)
		e.put_str(low.dependency)
		e.put_u32(int(low.width))
		e.put_u32(int(low.height))
		e.put_str(prev.dependency if prev != null else "")
		e.put_u32(int(prev.width) if prev != null else 0)
		e.put_u32(int(prev.height) if prev != null else 0)
	return CanonicalEncoder.sha256_hex(e.bytes())


func _parse(data: Variant, descriptor_dir: String) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "root is not an object"
	var d: Dictionary = data
	if d.has("schema_version") and RenderAssetJson.is_number(d.schema_version) and float(d.schema_version) != SCHEMA_VERSION:
		return "unsupported_version: schema_version %s is not supported (expected %d)" % [str(d.schema_version), SCHEMA_VERSION]
	var err := RenderAssetJson.check_keys(d, TOP_KEYS, "descriptor")
	if err == "":
		err = _parse_scalars(d)
	if err == "":
		err = _parse_geometry(d)
	if err == "":
		err = _parse_dependencies(d.dependencies, descriptor_dir)
	if err == "":
		err = _parse_roles(d.representations)
	if err == "":
		err = _parse_overview(d.overview)
	if err == "":
		err = _parse_materials_and_textures(d.materials, d.textures)
	return err


func _parse_scalars(d: Dictionary) -> String:
	if d.format != FORMAT:
		return "format must be '%s'" % FORMAT
	if not RenderAssetJson.is_int(d.schema_version):
		return "schema_version must be an integer"
	if not RenderAssetJson.is_str(d.asset_id):
		return "asset_id must be a non-empty string"
	if not RenderAssetJson.is_int_in(d.asset_version, 1, MAX_COST_BYTES):
		return "asset_version must be a positive integer"
	for key in ["source_content_hash", "derivative_hash"]:
		if not RenderAssetJson.is_hex64(d[key]):
			return "%s must be 64 lowercase hex characters" % key
	if typeof(d.category) != TYPE_STRING or not CATEGORIES.has(d.category):
		return "category '%s' is not allowed" % str(d.category)
	if typeof(d.vegetation) != TYPE_BOOL or typeof(d.decorative) != TYPE_BOOL:
		return "vegetation and decorative must be booleans"
	for key in ["provenance", "license"]:
		if not RenderAssetJson.is_str(d[key]):
			return "%s must be a non-empty string" % key
	asset_id = d.asset_id
	asset_version = int(d.asset_version)
	source_content_hash = d.source_content_hash
	derivative_hash = d.derivative_hash
	category = d.category
	vegetation = d.vegetation
	decorative = d.decorative
	provenance = d.provenance
	license = d.license
	return ""


func _parse_geometry(d: Dictionary) -> String:
	var anchor: Variant = RenderAssetJson.vec3(d.anchor_local_m)
	var bmin: Variant = RenderAssetJson.vec3(d.bounds_min_m)
	var bmax: Variant = RenderAssetJson.vec3(d.bounds_max_m)
	if anchor == null or bmin == null or bmax == null:
		return "anchor_local_m/bounds_min_m/bounds_max_m must be 3 finite numbers"
	if not _min_below_max(bmin, bmax):
		return "bounds_min_m must be below bounds_max_m on every axis"
	if not RenderAssetJson.is_number(d.footprint_radius_m) or float(d.footprint_radius_m) <= 0.0:
		return "footprint_radius_m must be a positive finite number"
	anchor_local = anchor
	bounds = AABB(bmin, bmax - bmin)
	footprint_radius_m = float(d.footprint_radius_m)
	return ""


static func _min_below_max(a: Vector3, b: Vector3) -> bool:
	return a.x < b.x and a.y < b.y and a.z < b.z


func _parse_dependencies(deps: Variant, descriptor_dir: String) -> String:
	if typeof(deps) != TYPE_ARRAY:
		return "dependencies must be an array"
	var seen_paths := {}
	var prev_key := ""
	for entry in deps:
		if typeof(entry) != TYPE_DICTIONARY:
			return "dependency entry is not an object"
		var err := RenderAssetJson.check_keys(entry, DEP_KEYS, "dependency")
		if err != "":
			return err
		err = _check_dependency(entry, prev_key)
		if err != "":
			return err
		var resolved := descriptor_dir.path_join(entry.path)
		if seen_paths.has(resolved):
			return "duplicate dependency path '%s'" % entry.path
		seen_paths[resolved] = true
		prev_key = entry.key
		var dep := {"key": entry.key, "type": entry.type, "rel_path": entry.path, "path": resolved,
			"bytes": int(entry.bytes), "sha256": entry.sha256, "gpu_bytes": int(entry.gpu_bytes),
			"staging_bytes": int(entry.staging_bytes)}
		dependencies.append(dep)
		_dep_by_key[dep.key] = dep
	return ""


static func _check_dependency(e: Dictionary, prev_key: String) -> String:
	if not RenderAssetJson.is_str(e.key):
		return "dependency key must be a non-empty string"
	if e.key <= prev_key:
		return "dependencies must be sorted by key with unique keys ('%s')" % e.key
	if typeof(e.type) != TYPE_STRING or not DEP_TYPES.has(e.type):
		return "dependency '%s' type '%s' is not allowed" % [e.key, str(e.type)]
	var perr := RenderAssetJson.path_error(e.path)
	if perr != "":
		return "path_rejected: dependency '%s': %s" % [e.key, perr]
	var ext := ".png" if e.type == "texture" else ".tres"
	if not (e.path as String).ends_with(ext):
		return "path_rejected: dependency '%s' (%s) must be a %s file" % [e.key, e.type, ext]
	if not RenderAssetJson.is_int_in(e.bytes, 1, MAX_DEP_BYTES):
		return "dependency '%s' bytes must be 1..%d" % [e.key, MAX_DEP_BYTES]
	if not RenderAssetJson.is_hex64(e.sha256):
		return "dependency '%s' sha256 must be 64 lowercase hex characters" % e.key
	for k in ["gpu_bytes", "staging_bytes"]:
		if not RenderAssetJson.is_int_in(e[k], 0, MAX_COST_BYTES):
			return "dependency '%s' %s must be an integer 0..%d" % [e.key, k, MAX_COST_BYTES]
	return ""


func _parse_roles(reps: Variant) -> String:
	if typeof(reps) != TYPE_DICTIONARY:
		return "representations must be an object"
	var err := RenderAssetJson.check_keys(reps, ROLES, "representations")
	if err != "":
		return err
	for role in ROLES:
		var entry: Variant = reps[role]
		if typeof(entry) != TYPE_DICTIONARY:
			return "role '%s' is not an object" % role
		if (entry as Dictionary).has("alias"):
			err = RenderAssetJson.check_keys(entry, ["alias"], "role '%s'" % role)
			if err == "" and (typeof(entry.alias) != TYPE_STRING or not ROLES.has(entry.alias)):
				err = "role '%s' alias '%s' is not a role" % [role, str(entry.alias)]
			_aliases[role] = entry.alias if err == "" else ""
		else:
			err = _parse_mesh_entry(role, entry)
			_aliases[role] = ""
		if err != "":
			return err
	return _resolve_aliases()


func _parse_mesh_entry(role: String, e: Dictionary) -> String:
	var err := RenderAssetJson.check_keys(e, MESH_KEYS, "role '%s'" % role)
	if err != "":
		return err
	var dep: Dictionary = _dep_by_key.get(e.mesh, {}) if typeof(e.mesh) == TYPE_STRING else {}
	if dep.is_empty() or dep.type != "mesh":
		return "role '%s' mesh '%s' is not a mesh dependency" % [role, str(e.mesh)]
	if not RenderAssetJson.is_int_in(e.triangles, 1, MAX_COST_BYTES):
		return "role '%s' triangles must be an integer >= 1" % role
	if not RenderAssetJson.is_int_in(e.surfaces, 1, 8):
		return "role '%s' surfaces must be an integer 1..8" % role
	var amin: Variant = RenderAssetJson.vec3(e.aabb_min_m)
	var amax: Variant = RenderAssetJson.vec3(e.aabb_max_m)
	if amin == null or amax == null or not _min_below_max(amin, amax):
		return "role '%s' aabb must be finite with min below max" % role
	roles[role] = {"mesh": e.mesh, "triangles": int(e.triangles), "surfaces": int(e.surfaces),
		"aabb": AABB(amin, amax - amin)}
	return ""


func _resolve_aliases() -> String:
	for role in ROLES:
		var cur: String = role
		var steps := 0
		while _aliases[cur] != "":
			cur = _aliases[cur]
			steps += 1
			if steps > 2:
				return "role '%s' alias chain is cyclic or longer than 2 steps" % role
		roles[role] = roles[cur].duplicate()
	return ""


func _parse_overview(o: Variant) -> String:
	if typeof(o) != TYPE_DICTIONARY:
		return "overview must be an object"
	var err := RenderAssetJson.check_keys(o, OVERVIEW_KEYS, "overview")
	if err != "":
		return err
	if not ["canopy", "solid", "none"].has(o.kind):
		return "overview kind '%s' is not allowed" % str(o.kind)
	if not ["cone", "ellipsoid", "box"].has(o.shape):
		return "overview shape '%s' is not allowed" % str(o.shape)
	if not RenderAssetJson.is_number(o.base_y_m):
		return "overview base_y_m must be finite"
	for k in ["height_m", "radius_m"]:
		if not RenderAssetJson.is_number(o[k]) or float(o[k]) <= 0.0:
			return "overview %s must be a positive finite number" % k
	var c: Variant = RenderAssetJson.vec3(o.color)
	if c == null or c.x < 0.0 or c.x > 1.0 or c.y < 0.0 or c.y > 1.0 or c.z < 0.0 or c.z > 1.0:
		return "overview color must be 3 numbers in [0, 1]"
	overview = {"kind": o.kind, "shape": o.shape, "base_y_m": float(o.base_y_m),
		"height_m": float(o.height_m), "radius_m": float(o.radius_m), "color": Color(c.x, c.y, c.z)}
	return ""


func _parse_materials_and_textures(mats: Variant, texs: Variant) -> String:
	if typeof(mats) != TYPE_DICTIONARY or typeof(texs) != TYPE_DICTIONARY:
		return "materials and textures must be objects"
	for key in texs:
		var err := _parse_texture(key, texs[key])
		if err != "":
			return err
	for key in mats:
		var m: Variant = mats[key]
		if typeof(key) != TYPE_STRING or key == "" or typeof(m) != TYPE_DICTIONARY:
			return "material entry '%s' is invalid" % str(key)
		var err := RenderAssetJson.check_keys(m, ["dependency", "alpha_mode", "texture"], "material '%s'" % key)
		if err != "":
			return err
		var dep: Dictionary = _dep_by_key.get(m.dependency, {}) if typeof(m.dependency) == TYPE_STRING else {}
		if dep.is_empty() or dep.type != "material":
			return "material '%s' dependency '%s' is not a material dependency" % [key, str(m.dependency)]
		if not ["opaque", "cutout"].has(m.alpha_mode):
			return "material '%s' alpha_mode '%s' is not allowed" % [key, str(m.alpha_mode)]
		if m.texture != null and (typeof(m.texture) != TYPE_STRING or not textures.has(m.texture)):
			return "material '%s' texture '%s' is not a texture key" % [key, str(m.texture)]
		materials[key] = {"dependency": m.dependency, "alpha_mode": m.alpha_mode,
			"texture": "" if m.texture == null else m.texture}
	for dep in dependencies:
		if dep.type == "material" and not _material_listed(dep.key):
			return "material dependency '%s' is not listed in materials" % dep.key
	return ""


func _material_listed(dep_key: String) -> bool:
	for m in materials.values():
		if m.dependency == dep_key:
			return true
	return false


func _parse_texture(key: Variant, t: Variant) -> String:
	if typeof(key) != TYPE_STRING or key == "" or typeof(t) != TYPE_DICTIONARY:
		return "texture entry '%s' is invalid" % str(key)
	var err := RenderAssetJson.check_keys(t, ["low", "preview"], "texture '%s'" % key)
	if err != "":
		return err
	var low: Variant = _parse_tier(key, "low", t.low, LOW_MAX_DIM)
	if typeof(low) == TYPE_STRING:
		return low
	var prev: Variant = null
	if t.preview != null:
		prev = _parse_tier(key, "preview", t.preview, PREVIEW_MAX_DIM)
		if typeof(prev) == TYPE_STRING:
			return prev
	textures[key] = {"low": low, "preview": prev}
	return ""


## Returns the tier Dictionary or an error String.
func _parse_tier(key: String, name: String, t: Variant, max_dim: int) -> Variant:
	var what := "texture '%s' %s" % [key, name]
	if typeof(t) != TYPE_DICTIONARY:
		return "%s is not an object" % what
	var err := RenderAssetJson.check_keys(t, TIER_KEYS, what)
	if err != "":
		return err
	var dep: Dictionary = _dep_by_key.get(t.dependency, {}) if typeof(t.dependency) == TYPE_STRING else {}
	if dep.is_empty() or dep.type != "texture":
		return "%s dependency '%s' is not a texture dependency" % [what, str(t.dependency)]
	for k in ["width", "height"]:
		if not RenderAssetJson.is_int_in(t[k], 1, max_dim) or not RenderAssetJson.is_pow2(int(t[k])):
			return "%s %s must be a power of two <= %d" % [what, k, max_dim]
	if t.mipmaps != true:
		return "%s must have mipmaps" % what
	return {"dependency": t.dependency, "width": int(t.width), "height": int(t.height)}
