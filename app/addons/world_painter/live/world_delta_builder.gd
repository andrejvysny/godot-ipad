class_name WorldDeltaBuilder
extends RefCounted
## Builds world-delta-v1 ZIP archives (INT-SPEC-1.1 §10.4-§10.5): delta.json plus the binary members it lists.
## A commit delta is derived purely from an immutable WorldChange (absolute after-values; undo uses the
## before-values); a preview delta from a provisional sample. Nothing here reads the live document.
## Layout: delta.json, tiles/<region>.t<x>_<z>.<map_kind>, scatter/<region>.t<x>_<z>.wpst,
## files/asset_locks.json, files/scatter.bin, files/paths.bin.

const SCHEMA_VERSION := 1
const FILE_MEMBERS := {"asset_lock_file": "files/asset_locks.json", "scatter_file": "files/scatter.bin",
	"paths_file": "files/paths.bin"}
const DELTA_JSON := "delta.json"

const _CHANGE_MAPS := {
	LiveTiles.KIND_HEIGHT: ["before_heights", "after_heights"],
	LiveTiles.KIND_CONTROL: ["before_controls", "after_controls"],
	LiveTiles.KIND_COLOR: ["before_colors", "after_colors"],
}


## ident: world_id, stream_id, operation_id, base_revision, base_hash, target_revision, target_hash.
## files: {asset_lock_file|scatter_file|paths_file: PackedByteArray} (only the ones to send).
## Returns {ok, error, bytes, tiles}; the archive is written to `out_path`.
static func build_commit(change: WorldChange, forward: bool, ident: Dictionary, files: Dictionary,
		out_path: String) -> Dictionary:
	var members: Array = []
	var doc := _header("commit", ident)
	doc["base_authored_hash"] = ident.base_hash
	doc["target_revision"] = ident.target_revision
	doc["target_authored_hash"] = ident.target_hash
	doc["tiles"] = _terrain_tiles(change, forward, members)
	_objects(change, forward, doc)
	for key: String in FILE_MEMBERS:
		if files.has(key):
			doc[key] = _file_ref(FILE_MEMBERS[key], files[key], members)
	var rules: TerrainRules = change.after_rules if forward else change.before_rules
	if rules != null:
		doc["terrain_rules"] = rules.to_dict()
	var res := _pack(doc, members, out_path)
	res["tiles"] = (doc.tiles as Array).size()
	return res


## tiles: [{loc, tx, tz, kind, bytes}], upserts: [ObjectRecord], deletes: [id], scatter_tiles: [{loc, tx, tz, bytes}],
## provisional: [AssetBinding rows as dictionaries]. ident adds preview_seq (no hashes).
static func build_preview(ident: Dictionary, tiles: Array, upserts: Array, deletes: Array, scatter_tiles: Array,
		provisional: Array, out_path: String) -> Dictionary:
	var members: Array = []
	var doc := _header("preview", ident)
	doc["preview_seq"] = ident.preview_seq
	var entries: Array = []
	for t: Dictionary in tiles:
		entries.append(_tile_entry(t.loc, t.tx, t.tz, t.kind, t.bytes, members))
	doc["tiles"] = entries
	var records: Array = []
	for rec: ObjectRecord in upserts:
		records.append(rec.to_dict())
	doc["object_upserts"] = records
	doc["object_deletes"] = deletes
	var stiles: Array = []
	for t: Dictionary in scatter_tiles:
		var path := LiveTiles.scatter_member_path(t.loc, t.tx, t.tz)
		var ref := _file_ref(path, t.bytes, members)
		ref["region"] = [t.loc.x, t.loc.y]
		ref["tile"] = [t.tx, t.tz]
		stiles.append(ref)
	if not stiles.is_empty():
		doc["scatter_tiles"] = stiles
	if not provisional.is_empty():
		doc["provisional_bindings"] = provisional
	var res := _pack(doc, members, out_path)
	res["tiles"] = entries.size()
	return res


static func _header(kind: String, ident: Dictionary) -> Dictionary:
	return {"schema_version": SCHEMA_VERSION, "kind": kind, "world_id": ident.world_id, "stream_id": ident.stream_id,
		"operation_id": ident.operation_id, "base_revision": ident.base_revision, "object_upserts": [],
		"object_deletes": [], "tiles": []}


static func _terrain_tiles(change: WorldChange, forward: bool, members: Array) -> Array:
	var entries: Array = []
	for kind: String in LiveTiles.KINDS:
		var names: Array = _CHANGE_MAPS[kind]
		var before: Dictionary = change.get(names[0] if forward else names[1])
		var after: Dictionary = change.get(names[1] if forward else names[0])
		var locs := before.keys()
		locs.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
		for loc: Vector2i in locs:
			var from := LiveTiles.bytes_of_array(kind, before[loc])
			var to := LiveTiles.bytes_of_array(kind, after[loc])
			for t in LiveTiles.changed_tiles(from, to):
				entries.append(_tile_entry(loc, t.x, t.y, kind, LiveTiles.tile(to, t.x, t.y), members))
	return entries


static func _tile_entry(loc: Vector2i, tx: int, tz: int, kind: String, bytes: PackedByteArray, members: Array) -> Dictionary:
	var path := LiveTiles.member_path(loc, tx, tz, kind)
	members.append({"name": path, "bytes": bytes})
	return {"region": [loc.x, loc.y], "tile": [tx, tz], "map_kind": kind, "path": path, "bytes": bytes.size(),
		"sha256": CanonicalEncoder.sha256_hex(bytes)}


static func _file_ref(path: String, bytes: PackedByteArray, members: Array) -> Dictionary:
	members.append({"name": path, "bytes": bytes})
	return {"path": path, "bytes": bytes.size(), "sha256": CanonicalEncoder.sha256_hex(bytes)}


static func _objects(change: WorldChange, forward: bool, doc: Dictionary) -> void:
	var objs: Dictionary = change.after_objects if forward else change.before_objects
	var ids := objs.keys()
	ids.sort()
	var upserts: Array = []
	var deletes: Array = []
	for id: String in ids:
		if objs[id] == null:
			deletes.append(id)
		else:
			upserts.append((objs[id] as ObjectRecord).to_dict())
	doc["object_upserts"] = upserts
	doc["object_deletes"] = deletes


## Writes delta.json first, then the members. {ok, error, bytes} where bytes is the archive size.
static func _pack(doc: Dictionary, members: Array, out_path: String) -> Dictionary:
	var zp := ZIPPacker.new()
	if zp.open(out_path) != OK:
		return {"ok": false, "error": "cannot create delta archive '%s'" % out_path, "bytes": 0}
	var all: Array = [{"name": DELTA_JSON, "bytes": JSON.stringify(doc, "", true, true).to_utf8_buffer()}]
	all.append_array(members)
	var err := ""
	for m: Dictionary in all:
		if zp.start_file(m.name) != OK or zp.write_file(m.bytes) != OK or zp.close_file() != OK:
			err = "cannot write '%s' into the delta archive" % m.name
			break
	if zp.close() != OK and err == "":
		err = "cannot finalize the delta archive"
	if err != "":
		return {"ok": false, "error": err, "bytes": 0}
	var f := FileAccess.open(out_path, FileAccess.READ)
	return {"ok": true, "error": "", "bytes": f.get_length() if f != null else 0}
