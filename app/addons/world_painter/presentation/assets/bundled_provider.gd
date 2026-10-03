class_name BundledProvider
extends WPAssetProvider
## Bundled catalog bindings: their prepared tiers are the committed render derivatives of RenderAssetRegistry, so a
## trusted binding is always prepared (no work, no network) and its meshes come from the shared RenderAssetCache.

var registry: RenderAssetRegistry
var cache: RenderAssetCache


func _init(p_registry: RenderAssetRegistry = null, p_cache: RenderAssetCache = null) -> void:
	registry = p_registry
	cache = p_cache


func provider_id() -> String:
	return AssetBinding.PROVIDER_BUNDLED


func prepare(binding_id: String, _cancel: RefCounted = null) -> void:
	var reason := _reason(binding_id)
	prepared.emit.call_deferred(binding_id, reason == "", reason)


func is_prepared(binding_id: String) -> bool:
	return _reason(binding_id) == ""


## The READY tier mesh from the shared cache; null until the render world has loaded it.
func representation(binding_id: String, tier: String) -> Mesh:
	var key := _render_key(binding_id)
	var d := registry.descriptor(key) if registry != null and key != "" else null
	if d == null or cache == null or not d.roles.has(tier):
		return null
	var dep := d.dependency(d.resolve_role(tier))
	var res_key := RenderAssetCache.resource_key(key, d.asset_version, d.derivative_hash, str(dep.get("key", "")))
	return cache.get_resource(res_key) as Mesh


## The trusted preview scene (res://, shipped with the app).
func instantiate(binding_id: String) -> Node3D:
	var b: AssetBinding = assets.get_binding(binding_id) if assets != null else null
	if b == null or _reason(binding_id) != "":
		return null
	var def := assets.catalog.get_asset(b.asset_id)
	var scene := load(def.preview_scene) as PackedScene
	return scene.instantiate() as Node3D if scene != null else null


func _reason(binding_id: String) -> String:
	var b: AssetBinding = assets.get_binding(binding_id) if assets != null else null
	if b == null or not b.is_bundled():
		return "not a bundled binding of the open world"
	return assets.unavailable_reason(binding_id)


func _render_key(binding_id: String) -> String:
	var def: AssetDefinition = assets.definition(binding_id) if assets != null else null
	return def.asset_id if def != null else ""
