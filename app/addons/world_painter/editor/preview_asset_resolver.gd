@tool
class_name PreviewAssetResolver
extends Node
## Editor-side AssetStudio access of the preview broker (ADR 0016 P3). The only holder of AssetStudio credentials:
## it resolves one binding row of the iPad's world lock through the vendored resolver, pinned to the exact
## `portable_glb_v1` delivery and manifest of that row, and answers with blob-cache paths and the verified manifest
## text. The host project's assetstudio.project.json decides whether the network may be used: a matching server
## and library resolve online; anything else is served from the exact cache only. Paths and URLs never come from
## the iPad.

const Registry := preload("res://addons/assetstudio/core/as_connection_registry.gd")
const BlobCache := preload("res://addons/assetstudio/core/as_blob_cache.gd")
const Client := preload("res://addons/assetstudio/core/as_library_client.gd")
const Resolver := preload("res://addons/assetstudio/core/as_asset_resolver.gd")
const AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")
const ProjectConfig := preload("res://addons/assetstudio/project/as_project_config.gd")
const REPRESENTATION := "portable_glb_v1"

var registry: RefCounted
var cache: RefCounted
var project_root := ""

var _resolvers: Dictionary = {}  # server_id -> online resolver
var _offline: Node


func _init(p_registry: RefCounted = null, p_cache: RefCounted = null, p_project_root: String = "") -> void:
	registry = p_registry if p_registry != null else Registry.new()
	cache = p_cache if p_cache != null else BlobCache.new()
	project_root = p_project_root if p_project_root != "" else ProjectSettings.globalize_path("res://")


## Absolute blob cache root the child may load from.
func blob_root() -> String:
	return ProjectSettings.globalize_path((cache.get("root") as String).path_join("blobs"))


## Coroutine: {state: "ready"|"error", files: {path: absolute path}, manifest_sha256, manifest, error}.
func resolve(row: Dictionary) -> Dictionary:
	var parsed := AssetBinding.from_dict(row)
	if parsed[1] != "":
		return _error("invalid binding: " + str(parsed[1]))
	var binding: AssetBinding = parsed[0]
	if binding.is_bundled() or not binding.deliveries.has(REPRESENTATION):
		return _error("not an AssetStudio binding with a portable_glb_v1 delivery")
	var pin: Dictionary = binding.deliveries[REPRESENTATION]
	var ref: RefCounted = AssetRef.parse(binding.asset_ref).value
	var result: RefCounted = await _resolver_for(ref).call("prepare", ref, REPRESENTATION, null, pin.delivery_id)
	if not result.get("ok"):
		return _error("%s: %s" % [result.get("code"), str(result.get("message")).left(200)])
	var value: Dictionary = result.get("value")
	if str(value.delivery_id) != str(pin.delivery_id) or str(value.manifest.raw_sha256) != str(pin.manifest_sha256) \
			or str(value.descriptor.raw_sha256) != binding.descriptor_sha256:
		return _error("integrity_mismatch: the resolved delivery differs from the locked one")
	return _reply(value, pin)


func _reply(value: Dictionary, pin: Dictionary) -> Dictionary:
	var root := blob_root()
	var files := {}
	for path: String in value.files:
		var absolute := ProjectSettings.globalize_path(str(value.files[path])).simplify_path()
		if not absolute.begins_with(root.simplify_path() + "/"):
			return _error("the cache returned a path outside the blob root")
		files[path] = absolute
	var manifest: PackedByteArray = cache.call("load_document", "manifests", str(pin.manifest_sha256))
	if manifest.is_empty():
		return _error("the manifest is not in the cache")
	return {"state": "ready", "files": files, "manifest_sha256": str(pin.manifest_sha256),
		"manifest": manifest.get_string_from_utf8(), "error": ""}


## Online only for the project's own server and libraries; otherwise the exact cache.
func _resolver_for(ref: RefCounted) -> Node:
	var server := str(ref.get("server_id"))
	var cfg: RefCounted = ProjectConfig.load_from(project_root)
	var allowed: bool = cfg.ok and cfg.value.get("server_id") == server and cfg.value.call("has_library", str(ref.get("library_id")))
	if allowed and registry.call("server_ids").has(server):
		if not _resolvers.has(server):
			var client: Node = Client.new()
			client.call("setup", registry, server)
			var resolver: Node = Resolver.new()
			resolver.call("setup", client, cache)
			add_child(client)
			add_child(resolver)
			_resolvers[server] = resolver
		return _resolvers[server]
	if _offline == null:
		_offline = Resolver.new()
		_offline.call("setup", null, cache)
		_offline.set("offline_only", true)
		add_child(_offline)
	return _offline


static func _error(message: String) -> Dictionary:
	return {"state": "error", "files": {}, "manifest_sha256": "", "manifest": "", "error": message}
