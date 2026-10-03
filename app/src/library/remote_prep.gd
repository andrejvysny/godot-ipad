class_name RemotePrep
extends RefCounted
## Staging and preparation of exact AssetStudio versions for the open world (IP-SPEC §4 "Preparation and
## placement"). prepare_ref() builds the binding of an exact version (RemoteBinding), registers it in the world's
## lock (which is append-only, content-addressed and serialized only from references, so a staged binding that no
## record uses never reaches a file or hash) and starts the provider's prepare; the object record appears only when
## a drop or tap commits. Finishing a download changes no tool and starts no placement. The tile states are
## "remote", "downloading", "ready", "failed" and "over_budget".

signal changed()
signal prepared(binding_id: String, ok: bool, error: String)

const REMOTE := "remote"
const DOWNLOADING := "downloading"
const READY := "ready"
const FAILED := "failed"
const OVER_BUDGET := "over_budget"
const BUDGET_WORDS := ["resource_limit", "exceed", "over the"]

var clients: Dictionary = {}  # server_id -> library client

var _providers: WorldAssetProviders
var _doc := Callable()
var _ensure := Callable()  # () -> Dictionary of resolvers (built on first use)
var _jobs: Dictionary = {}  # asset_key -> {state, progress, error, binding_id, name, serial}
var _names: Dictionary = {}  # binding_id -> display name the Library showed
var _serial := 0
var _by_key: Dictionary = {}  # asset_key -> binding id, rebuilt when the lock grows or is replaced
var _indexed_lock: WorldAssetLock
var _indexed_size := -1


## `doc_getter() -> WorldDocument`; `ensure_resolvers() -> Dictionary` builds the resolvers of the configured servers.
func bind(providers: WorldAssetProviders, doc_getter: Callable, ensure_resolvers: Callable) -> void:
	_providers = providers
	_doc = doc_getter
	_ensure = ensure_resolvers
	providers.prepared.connect(_on_prepared)


## Forgets every job and name (the world changed; providers cancel their own work).
func reset() -> void:
	_jobs.clear()
	_names.clear()
	changed.emit()


## Listens to download progress of `resolvers` (server_id -> ASAssetResolver); idempotent.
func connect_resolvers(resolvers: Dictionary) -> void:
	for r: Variant in resolvers.values():
		if r is Object and not (r as Object).is_connected("state_changed", _on_resolver_state):
			(r as Object).connect("state_changed", _on_resolver_state)


func name_of(binding_id: String) -> String:
	return str(_names.get(binding_id, ""))


func remember_name(binding_id: String, text: String) -> void:
	_names[binding_id] = text


## {state, progress, error, binding_id, disclosures} of the library item (an exact version).
func state_of(item: Dictionary) -> Dictionary:
	var key := str(item.asset_key)
	if _jobs.has(key):
		return _view(_jobs[key])
	var id := binding_of(key)
	if id != "":
		var doc: WorldDocument = _doc.call()
		if doc != null and doc.assets.is_prepared(id):
			return {"state": READY, "progress": 1.0, "error": "", "binding_id": id, "disclosures": disclosures(id)}
	return {"state": REMOTE, "progress": 0.0, "error": "", "binding_id": "", "disclosures": PackedStringArray()}


## Binding id the open world's lock holds for `asset_key` ("" when none).
func binding_of(asset_key: String) -> String:
	var doc: WorldDocument = _doc.call() if _doc.is_valid() else null
	if doc == null:
		return ""
	if doc.assets != _indexed_lock or doc.assets.size() != _indexed_size:
		_indexed_lock = doc.assets
		_indexed_size = doc.assets.size()
		_by_key.clear()
		for id in doc.assets.ids():
			var b := doc.assets.get_binding(id)
			if b != null and not b.is_bundled():
				_by_key[b.asset_key] = id
	return str(_by_key.get(asset_key, ""))


func disclosures(binding_id: String) -> PackedStringArray:
	var p := _providers.provider_of(binding_id) if _providers != null else null
	return p.call("disclosures", binding_id) if p != null and p.has_method("disclosures") else PackedStringArray()


func _view(job: Dictionary) -> Dictionary:
	return {"state": job.state, "progress": job.progress, "error": job.error, "binding_id": job.binding_id,
			"disclosures": disclosures(str(job.binding_id)) if str(job.binding_id) != "" else PackedStringArray()}


func prepare_item(item: Dictionary) -> String:
	return await prepare_ref(item.ref, str(item.name))


## Coroutine: stages and prepares the exact version `ref`. Returns the binding id once it is staged ("" on a
## failure, which the job records); the result of the preparation arrives through `prepared` and the job state.
func prepare_ref(ref: Dictionary, label: String) -> String:
	var key := AssetBinding.Canonical.asset_key(ref.server_id, ref.library_id, ref.asset_id, ref.version_id)
	var doc: WorldDocument = _doc.call() if _doc.is_valid() else null
	if doc == null:
		return ""
	var running: Dictionary = _jobs.get(key, {})
	if not running.is_empty() and running.state == DOWNLOADING:
		return str(running.binding_id)
	_serial += 1
	var job := {"state": DOWNLOADING, "progress": 0.0, "error": "", "binding_id": "", "name": label, "serial": _serial}
	_jobs[key] = job
	changed.emit()
	var client: Object = clients.get(ref.server_id)
	var built := {"ok": false, "error": "The server of this asset is not set up on this device."}
	if client != null:
		built = await RemoteBinding.build(client, ref)
	if _doc.call() != doc or int(_jobs.get(key, {}).get("serial", -1)) != int(job.serial):
		return ""  # the world changed or the job was cancelled meanwhile
	if not bool(built.ok):
		_fail(job, str(built.error))
		return ""
	var id := doc.assets.add(built.binding)
	job.binding_id = id
	_names[id] = label
	changed.emit()
	connect_resolvers(_ensure.call() if _ensure.is_valid() else {})
	if doc.assets.is_prepared(id):
		_finish(job, true, "")
		prepared.emit.call_deferred(id, true, "")
	else:
		_providers.prepare(id)
	return id


func cancel_item(item: Dictionary) -> void:
	var job: Dictionary = _jobs.get(str(item.asset_key), {})
	if job.is_empty():
		return
	_jobs.erase(str(item.asset_key))
	if str(job.binding_id) != "":
		_providers.cancel(str(job.binding_id))
	changed.emit()


func _on_prepared(binding_id: String, ok: bool, error: String) -> void:
	for key: String in _jobs.keys():
		var job: Dictionary = _jobs[key]
		if job.binding_id != binding_id:
			continue
		if error == "cancelled":
			_jobs.erase(key)
		elif ok:
			_finish(job, true, "")
		else:
			_fail(job, error)
	prepared.emit(binding_id, ok, error)
	changed.emit()


func _on_resolver_state(asset_key: String, state: String, progress: float) -> void:
	var job: Dictionary = _jobs.get(asset_key, {})
	if not job.is_empty() and state == "downloading" and job.state == DOWNLOADING:
		job.progress = progress
		changed.emit()


func _finish(job: Dictionary, _ok: bool, _error: String) -> void:
	job.state = READY
	job.progress = 1.0
	job.error = ""


func _fail(job: Dictionary, text: String) -> void:
	job.state = OVER_BUDGET if BUDGET_WORDS.any(func(w: String) -> bool: return text.contains(w)) else FAILED
	job.error = text
	changed.emit()
