class_name WorldDelta
extends RefCounted
## Parse and validate a received world-delta-v1 archive (INT-SPEC-1.1 §10.4, delta.schema.json). Validation is
## complete before anything is applied: container protections (ZipInspector.inspect_structure), exact member
## list, declared sizes, SHA-256 per member, identity agreement with the blob metadata, regions inside the layout,
## commit-only and preview-only members never mixed, no duplicate object ids or tile keys.
## parse() returns {ok, error, delta}; `delta` holds decoded values:
##   kind, world_id, stream_id, operation_id, base_revision, base_hash, target_revision, target_hash, preview_seq,
##   upserts: Array[ObjectRecord], deletes: Array[String], tiles: [{loc, tx, tz, kind, bytes}],
##   lock_bytes/lock (WorldAssetLock), scatter_bytes/scatter (ScatterLayer), paths_bytes/paths, rules,
##   scatter_tiles: [{loc, tx, tz, bytes, binding_ids}], provisional: Array[AssetBinding].

const DELTA_JSON := WorldDeltaBuilder.DELTA_JSON
const DIRECTORIES := ["tiles/", "scatter/", "files/"]
const MAX_ARCHIVE_BYTES := 64 * 1024 * 1024
const MAX_ENTRIES := 8192
const MAX_JSON_BYTES := 16 * 1024 * 1024
const MAX_TOTAL_BYTES := 128 * 1024 * 1024
const COMMON_KEYS := ["schema_version", "kind", "world_id", "stream_id", "operation_id", "base_revision",
	"object_upserts", "object_deletes", "tiles"]
const COMMIT_KEYS := ["base_authored_hash", "target_revision", "target_authored_hash", "asset_lock_file",
	"scatter_file", "paths_file", "terrain_rules"]
const PREVIEW_KEYS := ["preview_seq", "scatter_tiles", "provisional_bindings"]
const COMMIT_REQUIRED := ["base_authored_hash", "target_revision", "target_authored_hash"]


## `expect` (all optional) is compared with the inner identities: kind, world_id, stream_id, operation_id,
## base_revision, base_hash, target_revision, target_hash, preview_seq.
static func parse(path: String, layout: WorldLayout, expect: Dictionary = {}) -> Dictionary:
	var read := _read_json_and_entries(path)
	if read.error != "":
		return _fail(read.error)
	var doc: Dictionary = read.doc
	var err := _check_header(doc, layout, expect)
	if err != "":
		return _fail(err)
	var ctx := {"zip": read.zip, "entries": read.entries, "used": {DELTA_JSON: true}}
	var out := {"kind": doc.kind, "world_id": doc.world_id, "stream_id": doc.stream_id,
		"operation_id": doc.operation_id, "base_revision": int(doc.base_revision), "base_hash": "",
		"target_revision": -1, "target_hash": "", "preview_seq": -1}
	err = _read_records(doc, out)
	if err == "":
		err = _read_tiles(doc, layout, ctx, out)
	if err == "":
		err = _read_kind_members(doc, layout, ctx, out)
	(read.zip as ZIPReader).close()
	if err == "" and (ctx.used as Dictionary).size() != (read.entries as Dictionary).size():
		err = "archive holds members delta.json does not list"
	return _fail(err) if err != "" else {"ok": true, "error": "", "delta": out}


static func _read_json_and_entries(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "cannot open delta archive"}
	if file.get_length() > MAX_ARCHIVE_BYTES:
		return {"error": "delta archive is %d bytes, limit %d" % [file.get_length(), MAX_ARCHIVE_BYTES]}
	var data := file.get_buffer(file.get_length())
	file.close()
	var info := ZipInspector.inspect_structure(data, MAX_ENTRIES)
	if not info.ok:
		return {"error": info.error}
	var entries := {}
	var total := 0
	var dirs := {}
	for e: Dictionary in info.entries:
		if e.is_dir:  # ZIPPacker writes the parent directories of the members it adds
			if not DIRECTORIES.has(e.name) or int(e.uncompressed) != 0 or dirs.has(e.name):
				return {"error": "delta archive has an unexpected directory entry '%s'" % e.name}
			dirs[e.name] = true
			continue
		if entries.has(e.name):
			return {"error": "delta archive has a duplicate entry '%s'" % e.name}
		entries[e.name] = int(e.uncompressed)
		total += int(e.uncompressed)
	if total > MAX_TOTAL_BYTES or not entries.has(DELTA_JSON) or int(entries[DELTA_JSON]) > MAX_JSON_BYTES:
		return {"error": "delta archive sizes are out of bounds or delta.json is missing"}
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"error": "cannot open delta archive"}
	var json := JSON.new()
	var raw := zip.read_file(DELTA_JSON)
	if raw.size() != int(entries[DELTA_JSON]) or json.parse(raw.get_string_from_utf8()) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		zip.close()
		return {"error": "delta.json is not a JSON object of its declared size"}
	return {"error": "", "doc": json.data, "zip": zip, "entries": entries}


static func _check_header(doc: Dictionary, layout: WorldLayout, expect: Dictionary) -> String:
	for k: Variant in doc:
		if not (COMMON_KEYS.has(k) or COMMIT_KEYS.has(k) or PREVIEW_KEYS.has(k)):
			return "delta.json has unknown key '%s'" % str(k).left(40)
	for k: String in COMMON_KEYS:
		if not doc.has(k):
			return "delta.json lacks '%s'" % k
	if not _is_uint(doc.schema_version) or int(doc.schema_version) != WorldDeltaBuilder.SCHEMA_VERSION:
		return "unsupported delta schema_version"
	var kind: Variant = doc.kind
	if kind != "commit" and kind != "preview":
		return "delta kind must be commit or preview"
	if typeof(doc.world_id) != TYPE_STRING or not LiveIds.is_id(doc.stream_id) or typeof(doc.operation_id) != TYPE_STRING \
			or (doc.operation_id as String).is_empty() or (doc.operation_id as String).length() > 64 \
			or not _is_uint(doc.base_revision):
		return "delta.json identity fields are invalid"
	var err := _check_kind_keys(doc, kind)
	return err if err != "" else _check_expect(doc, expect)


static func _check_kind_keys(doc: Dictionary, kind: String) -> String:
	var forbidden: Array = PREVIEW_KEYS if kind == "commit" else COMMIT_KEYS
	for k: String in forbidden:
		if doc.has(k):
			return "%s delta must not contain '%s'" % [kind, k]
	var required: Array = COMMIT_REQUIRED if kind == "commit" else ["preview_seq"]
	for k: String in required:
		if not doc.has(k):
			return "%s delta lacks '%s'" % [kind, k]
	if kind == "commit":
		if not _is_uint(doc.target_revision) or int(doc.target_revision) != int(doc.base_revision) + 1 \
				or not LiveIds.is_hash(doc.base_authored_hash) or not LiveIds.is_hash(doc.target_authored_hash):
			return "commit target_revision must be base_revision + 1 with valid hashes"
	elif not _is_uint(doc.preview_seq):
		return "preview_seq is invalid"
	return ""


static func _check_expect(doc: Dictionary, expect: Dictionary) -> String:
	var pairs := {"kind": "kind", "world_id": "world_id", "stream_id": "stream_id", "operation_id": "operation_id",
		"base_revision": "base_revision", "base_hash": "base_authored_hash", "target_revision": "target_revision",
		"target_hash": "target_authored_hash", "preview_seq": "preview_seq"}
	for k: String in pairs:
		if not expect.has(k):
			continue
		var inner: Variant = doc.get(pairs[k])
		if inner == null or (typeof(expect[k]) == TYPE_INT and float(inner) != float(expect[k])) \
				or (typeof(expect[k]) == TYPE_STRING and inner != expect[k]):
			return "delta.json %s disagrees with the blob metadata" % pairs[k]
	return ""


static func _read_records(doc: Dictionary, out: Dictionary) -> String:
	if doc.kind == "commit":
		out.base_hash = doc.base_authored_hash
		out.target_revision = int(doc.target_revision)
		out.target_hash = doc.target_authored_hash
	else:
		out.preview_seq = int(doc.preview_seq)
	if typeof(doc.object_upserts) != TYPE_ARRAY or typeof(doc.object_deletes) != TYPE_ARRAY:
		return "object_upserts and object_deletes must be arrays"
	var seen := {}
	var upserts: Array = []
	for row: Variant in doc.object_upserts:
		var parsed := ObjectRecord.from_dict(row)
		if parsed[1] != "" or seen.has(parsed[0].object_id):
			return "object upsert is invalid or duplicated: %s" % str(parsed[1])
		seen[parsed[0].object_id] = true
		upserts.append(parsed[0])
	var deletes: Array = []
	for id: Variant in doc.object_deletes:
		if typeof(id) != TYPE_STRING or not ObjectRecord.is_uuid(id) or seen.has(id):
			return "object delete is invalid or conflicts with another entry"
		seen[id] = true
		deletes.append(id)
	out["upserts"] = upserts
	out["deletes"] = deletes
	return ""


static func _read_tiles(doc: Dictionary, layout: WorldLayout, ctx: Dictionary, out: Dictionary) -> String:
	if typeof(doc.tiles) != TYPE_ARRAY:
		return "tiles must be an array"
	var tiles: Array = []
	var seen := {}
	for row: Variant in doc.tiles:
		var t := _tile_ref(row, layout, true)
		if t.error != "":
			return t.error
		var key := "%s/%d/%d/%s" % [str(t.loc), t.tx, t.tz, t.kind]
		if seen.has(key):
			return "duplicate tile %s" % key
		seen[key] = true
		var bytes := _member(ctx, t.ref)
		if bytes.error != "":
			return bytes.error
		tiles.append({"loc": t.loc, "tx": t.tx, "tz": t.tz, "kind": t.kind, "bytes": bytes.data})
	out["tiles"] = tiles
	return ""


## {error, loc, tx, tz, kind, ref}. Region/tile ranges, canonical member path and exact sizes are enforced.
static func _tile_ref(row: Variant, layout: WorldLayout, terrain: bool) -> Dictionary:
	var keys := ["region", "tile", "map_kind", "path", "bytes", "sha256"] if terrain \
		else ["region", "tile", "path", "bytes", "sha256"]
	if typeof(row) != TYPE_DICTIONARY or (row as Dictionary).size() != keys.size():
		return {"error": "tile entry has the wrong shape"}
	for k: String in keys:
		if not (row as Dictionary).has(k):
			return {"error": "tile entry lacks '%s'" % k}
	var region := _pair(row.region)
	var tile := _pair(row.tile)
	if region.is_empty() or tile.is_empty() or tile[0] > 3 or tile[1] > 3 \
			or not layout.is_valid_region(Vector2i(region[0], region[1])):
		return {"error": "tile entry names a region or tile outside the layout"}
	var loc := Vector2i(region[0], region[1])
	var kind: String = row.map_kind if terrain else ""
	if terrain and not LiveTiles.KINDS.has(kind):
		return {"error": "unknown map_kind"}
	var want := LiveTiles.member_path(loc, tile[0], tile[1], kind) if terrain \
		else LiveTiles.scatter_member_path(loc, tile[0], tile[1])
	if row.path != want or not _is_uint(row.bytes) or not LiveIds.is_hash(row.sha256) \
			or (terrain and int(row.bytes) != LiveTiles.TILE_BYTES):
		return {"error": "tile entry path, size or hash is invalid"}
	return {"error": "", "loc": loc, "tx": tile[0], "tz": tile[1], "kind": kind, "ref": row}


static func _read_kind_members(doc: Dictionary, layout: WorldLayout, ctx: Dictionary, out: Dictionary) -> String:
	if doc.kind == "commit":
		return _read_commit_files(doc, ctx, out)
	return _read_preview_members(doc, layout, ctx, out)


## Reads the declared member `ref` ({path, bytes, sha256}); each member may be listed once.
static func _member(ctx: Dictionary, ref: Dictionary, max_bytes: int = LiveTiles.TILE_BYTES) -> Dictionary:
	var path: Variant = ref.get("path")
	var entries: Dictionary = ctx.entries
	if typeof(path) != TYPE_STRING or not entries.has(path) or (ctx.used as Dictionary).has(path):
		return {"error": "member '%s' is missing or listed twice" % str(path).left(80), "data": PackedByteArray()}
	if not _is_uint(ref.get("bytes")) or int(ref.bytes) != int(entries[path]) or int(ref.bytes) > max_bytes \
			or not LiveIds.is_hash(ref.get("sha256")):
		return {"error": "member '%s' size or hash declaration is invalid" % path, "data": PackedByteArray()}
	(ctx.used as Dictionary)[path] = true
	var data := (ctx.zip as ZIPReader).read_file(path)
	if data.size() != int(ref.bytes) or CanonicalEncoder.sha256_hex(data) != ref.sha256:
		return {"error": "member '%s' does not match its declared size or sha256" % path, "data": PackedByteArray()}
	return {"error": "", "data": data}


static func _read_commit_files(doc: Dictionary, ctx: Dictionary, out: Dictionary) -> String:
	var limits := WorldLimits.SCHEMA_4
	var caps := {"asset_lock_file": int(limits.max_lock_bytes), "scatter_file": int(limits.max_scatter_bytes),
		"paths_file": int(limits.max_paths_bytes)}
	for key: String in caps:
		if not doc.has(key):
			continue
		var ref: Variant = doc[key]
		if typeof(ref) != TYPE_DICTIONARY or ref.get("path") != WorldDeltaBuilder.FILE_MEMBERS[key]:
			return "%s is not a file reference to its canonical member" % key
		var m := _member(ctx, ref, caps[key])
		if m.error != "":
			return m.error
		var err := _decode_file(key, m.data, out)
		if err != "":
			return err
	if doc.has("terrain_rules"):
		var rules := TerrainRules.from_dict(doc.terrain_rules)
		if rules[1] != "":
			return rules[1]
		out["rules"] = rules[0]
	return ""


static func _decode_file(key: String, data: PackedByteArray, out: Dictionary) -> String:
	match key:
		"asset_lock_file":
			var lock := WorldAssetLock.decode(data, null)
			out["lock_bytes"] = data
			out["lock"] = lock[0]
			return lock[1]
		"scatter_file":
			var layer := ScatterLayer.decode(data)
			out["scatter_bytes"] = data
			out["scatter"] = layer[0]
			return layer[1]
	var paths := PathRecord.decode_all(data)
	out["paths_bytes"] = data
	out["paths"] = paths[0]
	return paths[1]


static func _read_preview_members(doc: Dictionary, layout: WorldLayout, ctx: Dictionary, out: Dictionary) -> String:
	var stiles: Array = []
	var rows: Variant = doc.get("scatter_tiles", [])
	if typeof(rows) != TYPE_ARRAY:
		return "scatter_tiles must be an array"
	var seen := {}
	for row: Variant in rows:
		var t := _tile_ref(row, layout, false)
		if t.error != "" or seen.has(str(t.loc) + str(t.tx) + str(t.tz)):
			return t.error if t.error != "" else "duplicate scatter tile"
		seen[str(t.loc) + str(t.tx) + str(t.tz)] = true
		var m := _member(ctx, t.ref, 4 * 1024 * 1024)
		var checked := LiveScatterTile.validate(m.data, LiveTiles.world_rect(t.loc, t.tx, t.tz)) if m.error == "" else {}
		if m.error != "" or not checked.ok:
			return m.error if m.error != "" else checked.error
		stiles.append({"loc": t.loc, "tx": t.tx, "tz": t.tz, "bytes": m.data, "binding_ids": checked.binding_ids})
	out["scatter_tiles"] = stiles
	return _read_provisional(doc, out)


static func _read_provisional(doc: Dictionary, out: Dictionary) -> String:
	var rows: Variant = doc.get("provisional_bindings", [])
	if typeof(rows) != TYPE_ARRAY or (rows as Array).size() > WorldAssetLock.MAX_BINDINGS:
		return "provisional_bindings must be a bounded array"
	var bindings: Array = []
	for row: Variant in rows:
		var b := AssetBinding.from_dict(row)
		if b[1] != "":
			return "provisional binding: " + str(b[1])
		bindings.append(b[0])
	out["provisional"] = bindings
	return ""


static func _pair(v: Variant) -> Array:
	if typeof(v) != TYPE_ARRAY or (v as Array).size() != 2 or not _is_int(v[0]) or not _is_int(v[1]):
		return []
	return [int(v[0]), int(v[1])]


static func _is_int(v: Variant) -> bool:
	return (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and is_finite(float(v)) and float(v) == floorf(float(v)) \
		and absf(float(v)) <= 1.0e9


static func _is_uint(v: Variant) -> bool:
	return _is_int(v) and float(v) >= 0.0


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
