class_name AssetStudioConnection
extends RefCounted
## Device-local AssetStudio configuration (IP-SPEC §2): server endpoint, token and the exact-bytes cache live under
## user://assetstudio through the vendored ASConnectionRegistry / ASBlobCache. Nothing is read from res://, the
## token is never logged, returned in an error or put into a URL (the client sends it as a bearer header only).

const Registry := preload("res://addons/assetstudio/core/as_connection_registry.gd")
const BlobCache := preload("res://addons/assetstudio/core/as_blob_cache.gd")
const Client := preload("res://addons/assetstudio/core/as_library_client.gd")
const Resolver := preload("res://addons/assetstudio/core/as_asset_resolver.gd")

const DIR := "user://assetstudio"
const CACHE_DIR := "user://assetstudio/cache"
const INSECURE_WARNING := "Cleartext HTTP to %s: the access token can be read by anyone on the network. Use HTTPS, or keep this to a trusted LAN."

var registry: RefCounted
var blob_cache: RefCounted
## True forces the exact cache only (no network), e.g. an explicit offline mode.
var offline_only := false

var _nodes: Array[Node] = []
var _clients: Dictionary = {}  # server_id -> ASLibraryClient of the last build_resolvers()


func _init(dir: String = DIR, cache_dir: String = CACHE_DIR) -> void:
	registry = Registry.new(dir)
	blob_cache = BlobCache.new(cache_dir)


func server_ids() -> PackedStringArray:
	return registry.call("server_ids")


func has_connection() -> bool:
	return not server_ids().is_empty()


## Stores the endpoint and, when given, the bearer token. `allow_insecure_lan` must be true for cleartext http to a
## non-loopback host. Returns "" or an error (never the token).
func configure(server_id: String, base_url: String, token: String = "", allow_insecure_lan: bool = false) -> String:
	var r: RefCounted = registry.call("set_connection", server_id, base_url, allow_insecure_lan)
	if not r.get("ok"):
		return str(r.get("message"))
	if token != "":
		r = registry.call("set_credential", server_id, token)
		if not r.get("ok"):
			return str(r.get("message"))
	return ""


func remove(server_id: String) -> void:
	registry.call("remove_connection", server_id)


## "" or the visible warning for a server reached over cleartext http on a non-loopback host.
func warning_for(server_id: String) -> String:
	var r: RefCounted = registry.call("get_connection", server_id)
	if not r.get("ok"):
		return ""
	var info: Dictionary = r.get("value")
	if str(info.scheme) == "http" and not bool(info.loopback):
		return INSECURE_WARNING % str(info.host)
	return ""


func warnings() -> PackedStringArray:
	var out := PackedStringArray()
	for id in server_ids():
		var w := warning_for(id)
		if w != "":
			out.append(w)
	return out


## One resolver (with its client) per configured server, added below `parent`; they are freed by shutdown().
## Without a connection the map is empty and bindings are served from the exact cache only.
func build_resolvers(parent: Node) -> Dictionary:
	var out := {}
	for id in server_ids():
		var client: Node = Client.new()
		client.call("setup", registry, id)
		var resolver: Node = Resolver.new()
		resolver.call("setup", client, blob_cache)
		resolver.set("offline_only", offline_only)
		parent.add_child(client)
		parent.add_child(resolver)
		_nodes.append(client)
		_nodes.append(resolver)
		out[id] = resolver
		_clients[id] = client
	return out


## The library client built for `server_id` by build_resolvers() (browse and metadata use it), or null.
func client_for(server_id: String) -> Node:
	return _clients.get(server_id)


func clients() -> Dictionary:
	return _clients.duplicate()


func shutdown() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	_clients.clear()
