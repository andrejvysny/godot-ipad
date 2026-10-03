class_name RemoteUpdates
extends RefCounted
## Update offers for the AssetStudio bindings the open world references (shared spec §7): the server's current
## pointer of an asset differs from the exact version a binding is pinned to. An offer is only a badge and a
## "Review update" entry; nothing is installed, the world does not change, and no modal ever opens by itself.
## Declining records the exact target version, so only a different version (or a change event of the asset)
## offers again.

signal changed()

var clients: Dictionary = {}  # server_id -> library client

var _doc := Callable()
var _offers: Dictionary = {}  # binding_id -> {target_version, display_version, server_id, library_id, asset_id}
var _dismissed: Dictionary = {}  # binding_id -> declined target version


func bind(doc_getter: Callable) -> void:
	_doc = doc_getter


func reset() -> void:
	_offers.clear()
	_dismissed.clear()
	changed.emit()


func offer_for(binding_id: String) -> Dictionary:
	return (_offers[binding_id] as Dictionary).duplicate() if _offers.has(binding_id) else {}


func has_offer(binding_id: String) -> bool:
	return _offers.has(binding_id)


## Binding ids of the world that have an offer for this asset (any version of it).
func bindings_for_asset(server_id: String, library_id: String, asset_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in _offers:
		var o: Dictionary = _offers[id]
		if o.server_id == server_id and o.library_id == library_id and o.asset_id == asset_id:
			out.append(id)
	out.sort()
	return out


func count() -> int:
	return _offers.size()


func dismiss(binding_id: String) -> void:
	if _offers.has(binding_id):
		_dismissed[binding_id] = _offers[binding_id].target_version
		_offers.erase(binding_id)
		changed.emit()


## A change event of the asset withdraws earlier declines and asks the server again.
func on_asset_current_changed(library_id: String, asset_id: String) -> void:
	var doc: WorldDocument = _doc.call() if _doc.is_valid() else null
	if doc == null:
		return
	for id in doc.assets.ids():
		var b := doc.assets.get_binding(id)
		if b != null and not b.is_bundled() and b.asset_ref.library_id == library_id and b.asset_ref.asset_id == asset_id:
			_dismissed.erase(id)
	check(asset_id)


## Coroutine: asks the servers for the current version of the referenced assets (all, or `only_asset`).
func check(only_asset: String = "") -> void:
	var doc: WorldDocument = _doc.call() if _doc.is_valid() else null
	if doc == null or clients.is_empty():
		return
	var asked := {}
	for id in doc.assets.referenced_ids(doc):
		var b := doc.assets.get_binding(id)
		if b == null or b.is_bundled() or (only_asset != "" and b.asset_ref.asset_id != only_asset):
			continue
		var client: Object = clients.get(b.asset_ref.server_id)
		if client == null:
			continue
		var k := "%s/%s" % [b.asset_ref.library_id, b.asset_ref.asset_id]
		if not asked.has(k):
			asked[k] = await client.call("asset", b.asset_ref.library_id, b.asset_ref.asset_id)
		if _doc.call() != doc:
			return
		var r: RefCounted = asked[k]
		if r.get("ok"):
			_offer(id, b, r.get("value") as Dictionary)
	if only_asset == "":
		var referenced := doc.assets.referenced_ids(doc)
		for id: String in _offers.keys():
			if not referenced.has(id):
				_offers.erase(id)  # every object moved off this binding
	changed.emit()


func _offer(id: String, b: AssetBinding, detail: Dictionary) -> void:
	var current := str(detail.get("current_version_id", ""))
	if current == "" or current == b.asset_ref.version_id or _dismissed.get(id) == current:
		_offers.erase(id)
		return
	var shown := current
	for v: Variant in (detail.get("versions", []) as Array if detail.get("versions") is Array else []):
		if v is Dictionary and v.get("version_id") == current:
			shown = str(v.get("display_version", current))
	_offers[id] = {"target_version": current, "display_version": shown, "server_id": b.asset_ref.server_id,
			"library_id": b.asset_ref.library_id, "asset_id": b.asset_ref.asset_id}
