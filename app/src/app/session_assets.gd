class_name SessionAssets
extends RefCounted
## AssetStudio bindings of the open world (IP-03): owns the provider router, starts preparation after a world opens,
## re-evaluates availability (read-only recovery) after every prepare, refreshes the presenter and scatter, and
## cancels and unpins on world switch, app deactivation and provider loss. A prepare that finishes after a cancel
## registers nothing (providers guarantee it), so this class only reacts to results that are still current.

const OWNER_PREFIX := "world:"
const READY_MESSAGE := "All AssetStudio assets are ready; editing is enabled."

## Device-local AssetStudio directory (connections, credentials, exact cache); tests point it at a scratch directory.
static var storage_dir := AssetStudioConnection.DIR

var providers := WorldAssetProviders.new()
var bundled: BundledProvider
var assetstudio: AssetStudioProvider
var connection: AssetStudioConnection
## Remote Library model: browse, thumbnails, change feed, staging/preparation of exact versions, update offers.
var remote := RemoteLibrary.new()

var _session: EditorSession
var _owner := ""
var _resolvers_built := false
var _resolvers: Dictionary = {}
var _retained: Dictionary = {}  # binding id -> true: referenced at some point of this world session (undo may restore it)


func _init(session: EditorSession) -> void:
	_session = session
	var render := session.render_state()
	connection = AssetStudioConnection.new(storage_dir, storage_dir.path_join("cache"))
	bundled = BundledProvider.new(render.registry(), render.cache)
	assetstudio = AssetStudioProvider.new(connection.blob_cache)
	assetstudio.bind_render(render.registry(), render.cache, _can_run_heavy)
	providers.add_provider(bundled)
	providers.add_provider(assetstudio)
	providers.prepared.connect(_on_prepared)
	session.add_child(remote)
	remote.thumbs.dir = storage_dir
	var doc_getter := func() -> WorldDocument: return _session.document
	remote.prep.bind(providers, doc_getter, ensure_resolvers)
	remote.updates.bind(doc_getter)
	session.world_committed.connect(_on_committed)


func _can_run_heavy() -> bool:
	return not _session.tools.has_active_operation()


## The session's document is `doc` now: cancels the previous world's work, binds the lock and pins the referenced
## AssetStudio bindings for the new owner (before releasing the old one, so shared assets stay prepared).
func switch_world(doc: WorldDocument) -> void:
	providers.cancel_all()
	var old := _owner
	_owner = OWNER_PREFIX + doc.world_id
	_retained.clear()
	remote.prep.reset()
	remote.updates.reset()
	providers.attach(doc.assets)
	for id in _remote_ids(doc):
		_retained[id] = true
	providers.pin(_owner, PackedStringArray(_retained.keys()))
	if old != "" and old != _owner:
		providers.unpin(old)


## Starts preparing what the open world references (offline: the exact cache only).
func start() -> void:
	var doc := _session.document
	if connection.has_connection():
		ensure_resolvers()
		remote.set_clients(connection.clients(), true)
		remote.refresh_libraries()
		remote.updates.check()
	if _remote_ids(doc).is_empty():
		return
	ensure_resolvers()
	providers.prepare_referenced(doc, _owner)
	for id: String in _retained:
		if doc.assets.has_binding(id) and not providers.is_prepared(id):
			providers.prepare(id)  # still reachable through undo: prepared again from the exact cache
	providers.pin(_owner, PackedStringArray(_retained.keys()))


## Builds the resolvers (network + exact cache) of the configured servers once; they are shared by the providers
## and the Library. Without a connection the map is empty and bindings are served from the exact cache only.
func ensure_resolvers() -> Dictionary:
	if not _resolvers_built:
		_resolvers_built = true
		_resolvers = connection.build_resolvers(_session)
		for id: String in _resolvers:
			assetstudio.add_resolver(id, _resolvers[id])
		remote.prep.connect_resolvers(_resolvers)
	return _resolvers


## The connection settings changed: rebuilds clients and resolvers, then reads the libraries again.
func reconnect() -> void:
	remote.stop_watching()
	connection.shutdown()
	assetstudio.clear_resolvers()
	_resolvers_built = false
	_resolvers = {}
	ensure_resolvers()
	remote.set_clients(connection.clients(), true)
	await remote.refresh_libraries()
	remote.updates.check()


## Provider loss or app deactivation: in-flight prepares are cancelled and the world's pins released.
func release() -> void:
	remote.stop_watching()
	providers.cancel_all()
	if _owner != "":
		providers.unpin(_owner)


## The app is active again: re-pins and re-prepares what the world references.
func resume() -> void:
	if _owner != "" and _session.document != null:
		providers.attach(_session.document.assets)
		start()
		if remote.has_servers():
			remote.resume_watching()


## Test seam: serves AssetStudio bindings through `provider` instead of the AssetStudio provider.
func replace_assetstudio_provider(provider: RuntimeBackedProvider) -> void:
	var render := _session.render_state()
	provider.bind_render(render.registry(), render.cache, _can_run_heavy)
	providers.add_provider(provider)
	provider.attach(_session.document.assets)


func shutdown() -> void:
	release()
	remote.shutdown()
	connection.shutdown()
	assetstudio.shutdown()


## A commit, undo or redo may reference a binding again later: keep every remote binding a change touches pinned
## (its prepared tiers and cached bytes) for the rest of the world session, so undo never downloads again.
func _on_committed(change: WorldChange, _revision: int, _forward: bool) -> void:
	var added := false
	for objects: Dictionary in [change.before_objects, change.after_objects]:
		for rec: Variant in objects.values():
			if rec is ObjectRecord and not _retained.has(rec.binding_id):
				var b := _session.document.assets.get_binding(rec.binding_id)
				if b != null and not b.is_bundled():
					_retained[rec.binding_id] = true
					added = true
	if added:
		providers.pin(_owner, PackedStringArray(_retained.keys()))


func _remote_ids(doc: WorldDocument) -> PackedStringArray:
	var out := PackedStringArray()
	for id in doc.assets.referenced_ids(doc):
		var b := doc.assets.get_binding(id)
		if b != null and not b.is_bundled():
			out.append(id)
	return out


func _on_prepared(binding_id: String, ok: bool, error: String) -> void:
	var doc := _session.document
	if error == "cancelled" or doc == null or not doc.assets.has_binding(binding_id):
		return
	if ok:
		_session.presenter.refresh_asset(doc, binding_id)
		_session.layers.scatter.asset_registered(binding_id)
	_reevaluate()


## Read-only recovery follows availability: editable once every referenced binding is usable.
func _reevaluate() -> void:
	var text := SessionWorldOps.read_only_text(_session.document)
	if text == _session.read_only_reason:
		return
	var was_read_only := _session.read_only_reason != ""
	_session.read_only_reason = text
	_session.tools.set_read_only(text)
	if text == "" and was_read_only:
		_session.post_message(READY_MESSAGE)
		_session.save_now()
	elif text != "" and providers.pending_count() == 0:
		_session.post_message(text, true)
	_session.status_changed.emit()
