class_name WPMaterialMapper
extends RefCounted
## Consumer material hook (ADR 0016 P4, ADR 0017 A4). `host` is an object with `map_material(slot_id: String,
## material: Material) -> Material`: the preview profile root, or the script named by the project setting
## `world_painter/apply/material_mapper` (its method is static). A host may define `map_material_for(asset_id: String,
## slot_id: String, material: Material) -> Material` instead (preferred when present): slot ids such as "m_solid" are
## shared by unrelated assets, and `asset_id` names the asset (catalog id of a bundled binding, AssetStudio asset id of a
## remote one). The result replaces the surface material; null or a non-Material result keeps the original, so unknown
## materials are preserved. The slot id is the material's name (the AssetStudio slot id of a portable GLB),
## "surface_<n>" for an unnamed surface. The hook runs once per (binding, slot) and every surface of that slot shares
## the result.

const SETTING := "world_painter/apply/material_mapper"
const METHOD := "map_material"
const METHOD_FOR := "map_material_for"

var _host: Object
var _cache := {}  # "binding|slot" -> Material (null: keep the original)


func _init(host: Object = null) -> void:
	_host = host


static func supports(host: Object) -> bool:
	return host != null and (host.has_method(METHOD) or host.has_method(METHOD_FOR))


## The asset identity the hook sees for `binding`.
static func asset_id_of(binding: AssetBinding) -> String:
	return binding.asset_id if binding.is_bundled() else str(binding.asset_ref.get("asset_id", binding.binding_id))


static func configured_path() -> String:
	return str(ProjectSettings.get_setting(SETTING, ""))


## [WPMaterialMapper or null, error]: no mapper (null, "") when the setting is empty.
static func from_setting() -> Array:
	var path := configured_path()
	if path == "":
		return [null, ""]
	if not path.begins_with("res://") or path.contains("..") or path.get_extension() != "gd" \
			or not FileAccess.file_exists(path):
		return [null, "material mapper '%s' is not a res:// script" % path.left(120)]
	var script := load(path) as GDScript
	if script == null or not supports(script):
		return [null, "material mapper '%s' has no static %s(slot_id, material)" % [path.left(120), METHOD]]
	return [WPMaterialMapper.new(script), ""]


static func slot_of(material: Material, surface: int) -> String:
	return material.resource_name if material != null and material.resource_name != "" else "surface_%d" % surface


func map(binding_id: String, slot_id: String, material: Material, asset_id: String = "") -> Material:
	var key := "%s|%s" % [binding_id, slot_id]
	if not _cache.has(key):
		_cache[key] = _call(asset_id if asset_id != "" else binding_id, slot_id, material)
	var mapped: Material = _cache[key]
	return mapped if mapped != null else material


func _call(asset_id: String, slot_id: String, material: Material) -> Material:
	if _host == null:
		return null
	var out: Variant = _host.call(METHOD_FOR, asset_id, slot_id, material) if _host.has_method(METHOD_FOR) \
			else _host.call(METHOD, slot_id, material)
	return out as Material


## Replaces the materials of `mesh` in place; returns the number of surfaces that changed.
func map_mesh(binding_id: String, mesh: Mesh, asset_id: String = "") -> int:
	var changed := 0
	for s in mesh.get_surface_count():
		var material := mesh.surface_get_material(s)
		var mapped := map(binding_id, slot_of(material, s), material, asset_id)
		if mapped != material:
			mesh.surface_set_material(s, mapped)
			changed += 1
	return changed


## Sets surface overrides on every MeshInstance3D below `root` (the shared meshes stay untouched); returns the
## number of surfaces that changed.
func map_nodes(binding_id: String, root: Node, asset_id: String = "") -> int:
	var changed := 0
	var nodes := root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		nodes.append(root)
	for node in nodes:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var material := mi.get_active_material(s)
			var mapped := map(binding_id, slot_of(mi.mesh.surface_get_material(s), s), material, asset_id)
			if mapped != material:
				mi.set_surface_override_material(s, mapped)
				changed += 1
	return changed
