class_name AssetStudioProvider
extends RuntimeBackedProvider
## Resolves AssetStudio bindings to their exact verified portable GLB through the vendored resolver (never the
## "latest" version, never another delivery) and prepares them at runtime. The delivery is pinned to the binding's
## deliveries.portable_glb_v1; the resolver result must also match the binding's manifest and descriptor hashes.
## A server without a configured connection (or an offline device) is served from the exact cache only.

const AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")
const Resolver := preload("res://addons/assetstudio/core/as_asset_resolver.gd")
const REPRESENTATION := "portable_glb_v1"

var _resolvers: Dictionary = {}  # server_id -> resolver Node (network + cache)
var _offline: Node


func _init(blob_cache: RefCounted = null) -> void:
	_blobs = blob_cache


func provider_id() -> String:
	return AssetBinding.PROVIDER_ASSETSTUDIO


## Resolver (an ASAssetResolver) for bindings of `server_id`; the caller owns its lifetime.
func add_resolver(server_id: String, resolver: Node) -> void:
	_resolvers[server_id] = resolver


## Forgets every resolver (the connection was rebuilt); bindings fall back to the exact cache until new ones arrive.
func clear_resolvers() -> void:
	_resolvers.clear()


## Frees the cache-only resolver this provider created.
func shutdown() -> void:
	if _offline != null:
		_offline.free()
		_offline = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _offline != null and is_instance_valid(_offline):
		_offline.free()


func _resolver_for(server_id: String) -> Node:
	if _resolvers.has(server_id):
		return _resolvers[server_id]
	if _offline == null:
		_offline = Resolver.new()
		_offline.call("setup", null, _blobs)
		_offline.set("offline_only", true)
	return _offline


func _fetch(binding: AssetBinding, token: RefCounted) -> Dictionary:
	var ref: RefCounted = AssetRef.parse(binding.asset_ref).value
	var pin: Dictionary = binding.deliveries[AssetBinding.REQUIRED_DELIVERY]
	var resolver := _resolver_for(binding.asset_ref.server_id)
	var r: RefCounted = await resolver.call("prepare", ref, REPRESENTATION, token, pin.delivery_id)
	if not r.get("ok"):
		return {"ok": false, "error": "%s: %s" % [r.get("code"), r.get("message")] if r.get("code") != "cancelled" else "cancelled"}
	var value: Dictionary = r.get("value")
	var err := _exactness_error(binding, pin, value)
	if err != "":
		return {"ok": false, "error": err}
	return _read_entrypoint(value)


static func _exactness_error(binding: AssetBinding, pin: Dictionary, value: Dictionary) -> String:
	if str(value.delivery_id) != str(pin.delivery_id):
		return "integrity_mismatch: resolved delivery differs from the locked delivery"
	if str(value.manifest.raw_sha256) != str(pin.manifest_sha256):
		return "integrity_mismatch: manifest differs from the locked manifest"
	if str(value.descriptor.raw_sha256) != binding.descriptor_sha256:
		return "integrity_mismatch: descriptor differs from the locked descriptor"
	return ""


## The entrypoint file of the verified manifest; file sha and size were checked by the resolver's blob cache.
static func _read_entrypoint(value: Dictionary) -> Dictionary:
	var data: Dictionary = value.manifest.data
	var path := str((value.files as Dictionary).get(data.entrypoint, ""))
	var shas := PackedStringArray()
	var size := -1
	for f: Dictionary in data.files:
		shas.append(str(f.sha256))
		if f.path == data.entrypoint:
			size = int(f.size)
	if path == "" or size < 0:
		return {"ok": false, "error": "invalid_response: manifest entrypoint is not among its files"}
	if size > RuntimeGlbValidator.MAX_BYTES:
		return {"ok": false, "error": "resource_limit: GLB is over the %d MiB limit" % (RuntimeGlbValidator.MAX_BYTES / RuntimeGlbValidator.MIB)}
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != size:
		return {"ok": false, "error": "integrity_mismatch: cached GLB size differs from the manifest"}
	return {"ok": true, "glb": bytes, "error": "", "shas": shas}
