class_name RenderWorldResources
extends RefCounted
## Mesh/material/texture access of ObjectRenderWorld through the shared RenderAssetCache (spec §12), plus the
## shared placeholder. Only prepared registry derivatives are loaded; a NOT_READY asset never reaches the cache.
## Requests carry owner "world:<epoch>" and tokens {"world_epoch": epoch} so a world replacement can cancel them.

const PLACEHOLDER := "placeholder"
const COARSE_ROLE := "far"
const PLACEHOLDER_TRIANGLES := 12
const UNIT_BOX := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)

var registry: RenderAssetRegistry
var cache: RenderAssetCache
var epoch: int = 0
var box := BoxMesh.new()
var awaiting: Dictionary = {}  # cache key -> asset_id, for accepted requests that are not READY yet

var _requested: Dictionary = {}  # cache key -> "requested" | "rejected" (rejected keys are not retried within an epoch)


func _init(registry_: RenderAssetRegistry, cache_: RenderAssetCache) -> void:
	registry = registry_
	cache = cache_
	box.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.45, 0.05)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = material


func owner() -> String:
	return "world:%d" % epoch


func tokens() -> Dictionary:
	return {"world_epoch": epoch}


## Cancels the work of the current epoch and starts the next one.
func next_epoch() -> void:
	cache.cancel_generation("world_epoch", epoch)
	cache.release(owner())
	epoch += 1
	_requested.clear()
	awaiting.clear()


func is_ready(asset_id: String) -> bool:
	return registry.is_ready(asset_id)


## The READY mesh of `role` (null while loading, failed or NOT_READY); requests it when needed.
func mesh(asset_id: String, role: String, priority: int) -> Mesh:
	var d := registry.descriptor(asset_id)
	if d == null:
		return null
	var dep := d.dependency(d.resolve_role(role))
	if dep.is_empty():
		return null
	var key := RenderAssetCache.resource_key(asset_id, d.asset_version, d.derivative_hash, str(dep.key))
	# A request cancelled by the cache (safety trim, lifecycle) is UNLOADED again and must be re-requested.
	var state := cache.state(key)
	if not _requested.has(key) or state == "RETIRED" or (state == "UNLOADED" and _requested[key] != "rejected"):
		_request(d, dep, key, priority, asset_id)
	return cache.get_resource(key) as Mesh


## Coarse-first (spec §8.1, LOD-02): the wanted role once READY, else the far mesh if loaded, else the placeholder.
func rep_for(asset_id: String, wanted_role: String, priority: int) -> String:
	if not registry.is_ready(asset_id):
		return PLACEHOLDER
	var coarse := mesh(asset_id, COARSE_ROLE, priority)
	if wanted_role == COARSE_ROLE:
		return COARSE_ROLE if coarse != null else PLACEHOLDER
	if mesh(asset_id, wanted_role, priority) != null:
		return wanted_role
	return COARSE_ROLE if coarse != null else PLACEHOLDER


func mesh_of(asset_id: String, rep: String, priority: int = 1) -> Mesh:
	return box if rep == PLACEHOLDER else mesh(asset_id, rep, priority)


## Mesh-space render AABB of a representation.
func render_aabb(asset_id: String, rep: String) -> AABB:
	var d := registry.descriptor(asset_id)
	if rep == PLACEHOLDER or d == null:
		return UNIT_BOX
	return d.roles[rep].aabb


func triangles(asset_id: String, rep: String) -> int:
	var d := registry.descriptor(asset_id)
	if rep == PLACEHOLDER or d == null:
		return PLACEHOLDER_TRIANGLES
	return int(d.roles[rep].triangles)


## Assets with a request that finished (READY) since the last call; failed requests are dropped.
func poll_ready() -> PackedStringArray:
	var done := PackedStringArray()
	for key: String in awaiting.keys():
		var state := cache.state(key)
		if state == "READY" or state == "UNLOADED":
			# UNLOADED = cancelled by the cache; re-queuing the asset re-requests it on the next build.
			done.append(str(awaiting[key]))
			awaiting.erase(key)
		elif state != "QUEUED" and state != "LOADING":
			awaiting.erase(key)
	return done


func _request(d: RenderAssetDescriptor, dep: Dictionary, key: String, priority: int, asset_id: String) -> void:
	_requested[key] = "requested"
	var result := cache.request(key, str(dep.path), "mesh", priority, maxi(int(dep.gpu_bytes), 1), owner(), tokens())
	if str(result.status) == "rejected":
		_requested[key] = "rejected"
		return
	if str(result.status) != "ready":
		awaiting[key] = asset_id
	if dep.key == d.resolve_role(COARSE_ROLE):
		cache.mark_fallback(key)
	_request_materials(d, priority)


## Materials and low-tier textures are separate cache entries so shared ones count once (MEMORY-01).
func _request_materials(d: RenderAssetDescriptor, priority: int) -> void:
	for m: Dictionary in d.materials.values():
		_request_dependency(d, str(m.dependency), "material", priority)
		if str(m.texture) != "":
			var tier: Dictionary = d.textures[m.texture].low
			_request_dependency(d, str(tier.dependency), "texture", priority)


func _request_dependency(d: RenderAssetDescriptor, dep_key: String, kind: String, priority: int) -> void:
	var dep := d.dependency(dep_key)
	if dep.is_empty():
		return
	var key := RenderAssetCache.resource_key(d.asset_id, d.asset_version, d.derivative_hash, dep_key)
	if _requested.has(key) and cache.state(key) != "UNLOADED":
		return
	_requested[key] = "requested"
	cache.request(key, str(dep.path), kind, priority, maxi(int(dep.gpu_bytes), 1), owner(), tokens())
