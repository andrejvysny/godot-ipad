class_name PresenterGhost
extends RefCounted
## The placement ghost (spec §8.4): one reusable MeshInstance3D wearing the shared alpha material.
## Shows the asset's prepared `ghost` role mesh from the render cache; until it is READY (or when the asset
## has no derivatives) a box of the logical bounds stands in. Catalog preview scenes are never loaded.

const VALID := Color(0.30, 0.90, 0.40, 0.45)
const INVALID := Color(0.95, 0.30, 0.25, 0.45)
const OWNER := "ghost"

var node: MeshInstance3D
var material := StandardMaterial3D.new()
var asset_id: String = ""
var valid: bool = false

var _box := BoxMesh.new()
var _registry: RenderAssetRegistry
var _cache: RenderAssetCache
var _key: String = ""
var _have_mesh: bool = false


func _init(registry: RenderAssetRegistry, cache: RenderAssetCache) -> void:
	_registry = registry
	_cache = cache
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = INVALID
	_box.size = Vector3.ONE


func show(host: Node3D, asset: AssetDefinition, xf: Transform3D, is_valid: bool) -> void:
	if node == null:
		node = MeshInstance3D.new()
		node.name = "ghost"
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host.add_child(node)
	if asset_id != asset.asset_id:
		asset_id = asset.asset_id
		_key = _request(asset)
		_have_mesh = false
		node.mesh = _box
	if not _have_mesh and _key != "":
		var mesh := _cache.get_resource(_key) as Mesh
		if mesh != null:
			node.mesh = mesh
			_have_mesh = true
	if _have_mesh:
		node.transform = xf
	else:
		node.transform = xf * Transform3D(Basis.from_scale(asset.bounds.size), asset.bounds.get_center())
	node.visible = true
	valid = is_valid
	material.albedo_color = VALID if is_valid else INVALID


func hide() -> void:
	if node != null:
		node.visible = false


func is_visible() -> bool:
	return node != null and node.visible


func uses_prepared_mesh() -> bool:
	return _have_mesh


func _request(asset: AssetDefinition) -> String:
	var d := _registry.descriptor(asset.asset_id)
	if d == null:
		return ""
	var dep := d.dependency(d.resolve_role("ghost"))
	if dep.is_empty():
		return ""
	var key := RenderAssetCache.resource_key(d.asset_id, d.asset_version, d.derivative_hash, str(dep.key))
	var result := _cache.request(key, str(dep.path), "mesh", 0, maxi(int(dep.gpu_bytes), 1), OWNER)
	return "" if str(result.status) == "rejected" else key
