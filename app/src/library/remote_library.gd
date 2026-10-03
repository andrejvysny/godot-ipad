class_name RemoteLibrary
extends Node
## Browse model of the AssetStudio libraries a device may read (IP-SPEC §4): granted libraries per configured
## server, paged browsing with query/category/tag filters, per-library failure isolation, thumbnails, the change
## feed (invalidation hints only) and connectivity text. It never touches a world: staging, preparation and update
## offers live in RemotePrep / RemoteUpdates, which share its clients. A cursor reset keeps the items on screen until
## a replacement first page arrives; a failed page or library keeps what was loaded before.

signal changed()
signal thumbnail_ready(key: String)

const ChangeWatcher := preload("res://addons/assetstudio/core/as_change_watcher.gd")
const PAGE_SIZE := 60
const MAX_PAGE := 200

var page_size := PAGE_SIZE
## False keeps the change feed off (tests, and an explicit "no live updates" mode); browsing still works.
var watch_enabled := true
var thumbs := RemoteThumbs.new()
var prep := RemotePrep.new()
var updates := RemoteUpdates.new()
var query := {"q": "", "category": "", "tags": ""}

var _clients: Dictionary = {}  # server_id -> library client (ASLibraryClient or a test double)
var _servers: Dictionary = {}  # server_id -> {"ok": bool, "error": String, "live": bool}
var _libs: Dictionary = {}  # library key -> state (see _new_state)
var _selected := ""  # "" = the bundled catalog
var _watchers: Array[Node] = []


func _init() -> void:
	thumbs.ready.connect(thumbnail_ready.emit)
	prep.changed.connect(changed.emit)
	updates.changed.connect(changed.emit)


static func key_of(server_id: String, library_id: String) -> String:
	return "%s/%s" % [server_id, library_id]


## Replaces the clients (server_id -> library client). `watch` starts a change watcher per client; tests drive
## on_events() / on_reset() themselves.
func set_clients(clients: Dictionary, watch: bool = true) -> void:
	stop_watching()
	_clients = clients.duplicate()
	for sid: String in _servers.keys():
		if not _clients.has(sid):
			_servers.erase(sid)
	for key: String in _libs.keys():
		if not _clients.has(str(_libs[key].server_id)):
			_libs.erase(key)
	if _selected != "" and not _libs.has(_selected):
		_selected = ""
	prep.clients = _clients
	updates.clients = _clients
	if watch:
		resume_watching()
	changed.emit()


func has_servers() -> bool:
	return not _clients.is_empty()


func client_for(server_id: String) -> Object:
	return _clients.get(server_id)


# --- libraries ---------------------------------------------------------------------------------

## Coroutine: asks every server for its granted libraries. A failing server keeps its earlier libraries (marked
## offline) and never hides the others.
func refresh_libraries() -> void:
	for sid: String in _clients.keys():
		var r: RefCounted = await (_clients[sid] as Object).call("libraries")
		if not _clients.has(sid):
			continue
		if not r.get("ok"):
			_servers[sid] = {"ok": false, "error": str(r.call("describe")), "live": false}
			continue
		_servers[sid] = {"ok": true, "error": "", "live": true}
		_apply_libraries(sid, (r.get("value") as Dictionary).get("libraries", []))
	changed.emit()


func _apply_libraries(sid: String, rows: Variant) -> void:
	var seen := {}
	for row: Variant in (rows as Array if rows is Array else []):
		if not (row is Dictionary) or not (row.get("library_id") is String):
			continue
		var key := key_of(sid, row.library_id)
		seen[key] = true
		if not _libs.has(key):
			_libs[key] = _new_state(sid, row.library_id)
		_libs[key].name = str(row.get("name", row.library_id))
		_libs[key].available = str(row.get("state", "available")) == "available"
	for key: String in _libs.keys():
		if str(_libs[key].server_id) == sid and not seen.has(key):
			_libs.erase(key)
			if _selected == key:
				_selected = ""


static func _new_state(sid: String, library_id: String) -> Dictionary:
	return {"server_id": sid, "library_id": library_id, "name": library_id, "available": true, "items": [],
			"cursor": "", "has_more": false, "error": "", "loading": false, "gen": 0, "loaded": false, "stale": false}


## [{key, server_id, library_id, name, available, error, loaded}] sorted by name.
func libraries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key: String in _libs:
		var st: Dictionary = _libs[key]
		var server: Dictionary = _servers.get(st.server_id, {})
		out.append({"key": key, "server_id": st.server_id, "library_id": st.library_id, "name": st.name,
				"available": bool(st.available) and bool(server.get("ok", true)),
				"error": str(st.error) if str(st.error) != "" else str(server.get("error", "")), "loaded": st.loaded})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name) < str(b.name))
	return out


func selected() -> String:
	return _selected


## "" selects the bundled catalog. Browses the library when it was never loaded or changed meanwhile.
func select(key: String) -> void:
	if key != "" and not _libs.has(key):
		return
	_selected = key
	changed.emit()
	if key != "" and (not _libs[key].loaded or _libs[key].stale):
		browse(key)


## "none" (no server configured), "online", "offline" (no server answers) or "partial", plus one line of text.
func connectivity() -> Dictionary:
	if _clients.is_empty():
		return {"state": "none", "text": "No AssetStudio server is set up."}
	var bad := PackedStringArray()
	for sid: String in _clients:
		if _servers.has(sid) and not bool(_servers[sid].ok):
			bad.append(str(_servers[sid].error))
	if bad.is_empty():
		return {"state": "online" if not _servers.is_empty() else "unknown", "text": "Connected."}
	var state := "offline" if bad.size() == _clients.size() else "partial"
	return {"state": state, "text": "Offline: %s" % bad[0] if state == "offline" else "Some servers are unreachable: %s" % bad[0]}


# --- browse ------------------------------------------------------------------------------------

func set_query(q: String, category: String = "", tags: String = "") -> void:
	query = {"q": q.strip_edges(), "category": category.strip_edges(), "tags": tags.strip_edges()}
	if _selected != "":
		browse(_selected)


func items(key: String) -> Array:
	return (_libs[key].items as Array).duplicate() if _libs.has(key) else []


func has_more(key: String) -> bool:
	return _libs.has(key) and bool(_libs[key].has_more)


func is_loading(key: String) -> bool:
	return _libs.has(key) and bool(_libs[key].loading)


func library_error(key: String) -> String:
	return str(_libs[key].error) if _libs.has(key) else ""


## Category ids present in the loaded items of `key`, sorted.
func categories(key: String) -> PackedStringArray:
	var seen := {}
	for it: Dictionary in items(key):
		if str(it.category) != "":
			seen[it.category] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


func _query_dict() -> Dictionary:
	var out := {}
	for k: String in query:
		if str(query[k]) != "":
			out[k] = query[k]
	return out


## Coroutine: loads the first page (`more` false: replaces the items when it arrives) or the next one.
func browse(key: String, more: bool = false) -> void:
	var st: Dictionary = _libs.get(key, {})
	var client: Object = _clients.get(st.get("server_id", ""))
	if st.is_empty() or client == null:
		return
	st.gen = int(st.gen) + 1
	var gen: int = st.gen
	st.loading = true
	st.stale = false
	changed.emit()
	var r: RefCounted = await client.call("list_assets", st.library_id, _query_dict(), str(st.cursor) if more else "",
			clampi(page_size, 1, MAX_PAGE))
	if not _libs.has(key) or int(_libs[key].gen) != gen:
		return  # superseded by a newer browse or the library vanished
	st.loading = false
	if not r.get("ok"):
		st.error = str(r.call("describe"))
		changed.emit()
		return
	var v: Dictionary = r.get("value")
	if bool(v.get("reset_required", false)):
		if more:
			browse(key, false)  # the old pages stay visible until the replacement first page arrives
		else:
			st.error = "The server asked for a reset of a fresh listing."
			changed.emit()
		return
	_take_page(st, v, more)


func _take_page(st: Dictionary, v: Dictionary, more: bool) -> void:
	var page: Array = []
	for row: Variant in (v.get("items", []) as Array if v.get("items") is Array else []):
		if row is Dictionary and row.get("asset_id") is String and row.get("current_version_id") is String:
			page.append(_item(st, row))
	if more:
		var known := {}
		for it: Dictionary in st.items:
			known[it.asset_id] = true
		for it: Dictionary in page:
			if not known.has(it.asset_id):
				(st.items as Array).append(it)
	else:
		st.items = page
	var next: Variant = v.get("next_cursor")
	st.cursor = next if next is String else ""
	st.has_more = str(st.cursor) != ""
	st.error = ""
	st.loaded = true
	changed.emit()
	_load_thumbnails(st)
	updates.check()


## Normalised item: ids, display data and the exact asset_key of the version the server lists as current.
func _item(st: Dictionary, row: Dictionary) -> Dictionary:
	var ref := {"server_id": st.server_id, "library_id": st.library_id, "asset_id": row.asset_id,
			"version_id": row.current_version_id}
	return {"key": key_of(st.server_id, st.library_id), "server_id": st.server_id, "library_id": st.library_id,
			"asset_id": row.asset_id, "version_id": row.current_version_id, "ref": ref,
			"asset_key": AssetBinding.Canonical.asset_key(st.server_id, st.library_id, row.asset_id, row.current_version_id),
			"name": str(row.get("display_name", row.asset_id)), "category": str(row.get("category_id", "")),
			"tags": row.get("tags", []), "display_version": str(row.get("display_version", row.current_version_id)),
			"has_thumbnail": bool(row.get("has_thumbnail", false))}


func _load_thumbnails(st: Dictionary) -> void:
	var client: Object = _clients.get(st.server_id)
	for it: Dictionary in st.items:
		if bool(it.has_thumbnail) and thumbs.texture(str(it.asset_key)) == null:
			thumbs.request(client, str(it.asset_key), str(it.library_id), str(it.asset_id), str(it.version_id))


# --- change feed -------------------------------------------------------------------------------

## Starts one watcher per client (idempotent). Events are hints: they refresh browse and update offers.
func resume_watching() -> void:
	if not _watchers.is_empty() or not watch_enabled:
		return
	for sid: String in _clients:
		var w: Node = ChangeWatcher.new()
		add_child(w)
		w.connect("changed", on_events)
		w.connect("reset_required", on_reset)
		w.connect("failed", _on_watch_failed.bind(sid))
		_watchers.append(w)
		w.call("start", _clients[sid])


func stop_watching() -> void:
	for w in _watchers:
		w.call("stop")
		w.queue_free()
	_watchers.clear()


func _on_watch_failed(code: String, sid: String) -> void:
	_servers[sid] = {"ok": false, "error": code, "live": false}
	changed.emit()


## Invalidation hints of the change feed ({type, library_id[, asset_id]}). Refreshes what is on screen, withdraws
## earlier "dismissed" decisions of a changed asset and re-checks update offers; never installs anything.
func on_events(events: Array) -> void:
	var libs := {}
	for e: Variant in events:
		if not (e is Dictionary):
			continue
		var kind := str(e.get("type"))
		if kind == "access_changed":
			refresh_libraries()
		elif kind in ["library_changed", "asset_metadata_changed", "asset_current_changed", "delivery_ready"]:
			libs[str(e.get("library_id", ""))] = true
		if kind == "asset_current_changed":
			updates.on_asset_current_changed(str(e.get("library_id", "")), str(e.get("asset_id", "")))
	for key: String in _libs:
		if libs.has(str(_libs[key].library_id)):
			if key == _selected:
				browse(key)
			else:
				_libs[key].stale = true


## The server asked for a full re-read (restart, expired cursor).
func on_reset() -> void:
	for key: String in _libs:
		_libs[key].stale = key != _selected
	await refresh_libraries()
	if _selected != "":
		browse(_selected)
	updates.check()


func shutdown() -> void:
	stop_watching()
