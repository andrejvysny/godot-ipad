class_name LiveOverlay
extends RefCounted
## The receiver's provisional overlay (INT-SPEC-1.1 §10.5): values of the operation currently in progress, keyed by
## terrain tile, object id and scatter tile, each remembering the highest preview_seq applied. It never touches the
## committed document; consumers draw overlay values above the committed view. Cleared by the commit of that
## operation, preview_cancel, a 10 s silence, a stream change or a reconnect.

const TIMEOUT_MSEC := 10000

var operation_id := ""
var tiles: Dictionary = {}  # "x/z/tx/tz/kind" -> {seq, loc, tx, tz, kind, bytes}
var objects: Dictionary = {}  # id -> {seq, record: ObjectRecord or null}
var scatter_tiles: Dictionary = {}  # "x/z/tx/tz" -> {seq, loc, tx, tz, bytes}
var provisional: Dictionary = {}  # binding id -> AssetBinding
var last_preview_msec := 0


func is_empty() -> bool:
	return tiles.is_empty() and objects.is_empty() and scatter_tiles.is_empty()


func clear() -> void:
	operation_id = ""
	tiles = {}
	objects = {}
	scatter_tiles = {}
	provisional = {}


## Merges a validated preview delta (WorldDelta.parse). A different operation id replaces the overlay.
func apply(delta: Dictionary, now_msec: int) -> void:
	if delta.operation_id != operation_id:
		clear()
		operation_id = delta.operation_id
	var seq: int = delta.preview_seq
	last_preview_msec = now_msec
	for t: Dictionary in delta.tiles:
		var key := "%d/%d/%d/%d/%s" % [t.loc.x, t.loc.y, t.tx, t.tz, t.kind]
		if seq > int((tiles.get(key, {}) as Dictionary).get("seq", -1)):
			tiles[key] = {"seq": seq, "loc": t.loc, "tx": t.tx, "tz": t.tz, "kind": t.kind, "bytes": t.bytes}
	for rec: ObjectRecord in delta.upserts:
		_set_object(rec.object_id, seq, rec)
	for id: String in delta.deletes:
		_set_object(id, seq, null)
	for t: Dictionary in delta.get("scatter_tiles", []):
		var key := "%d/%d/%d/%d" % [t.loc.x, t.loc.y, t.tx, t.tz]
		if seq > int((scatter_tiles.get(key, {}) as Dictionary).get("seq", -1)):
			scatter_tiles[key] = {"seq": seq, "loc": t.loc, "tx": t.tx, "tz": t.tz, "bytes": t.bytes}
	for b: AssetBinding in delta.get("provisional", []):
		provisional[b.binding_id] = b


func _set_object(id: String, seq: int, rec: ObjectRecord) -> void:
	if seq > int((objects.get(id, {}) as Dictionary).get("seq", -1)):
		objects[id] = {"seq": seq, "record": rec}


## True once the overlay has been silent for TIMEOUT_MSEC.
func expired(now_msec: int) -> bool:
	return not is_empty() and now_msec - last_preview_msec >= TIMEOUT_MSEC


## Effective 16384-byte tile: the overlay's when present, else the committed bytes.
func effective_tile(doc: WorldDocument, loc: Vector2i, tx: int, tz: int, kind: String) -> PackedByteArray:
	var key := "%d/%d/%d/%d/%s" % [loc.x, loc.y, tx, tz, kind]
	if tiles.has(key):
		return tiles[key].bytes
	return LiveTiles.tile(LiveTiles.bytes_of_region(doc.get_region(loc), kind), tx, tz)


## Effective object record (null when absent or deleted by the overlay).
func effective_object(doc: WorldDocument, id: String) -> ObjectRecord:
	if objects.has(id):
		return objects[id].record
	return doc.get_object(id)
