class_name LiveDeltaApply
extends RefCounted
## Applies a validated commit delta (WorldDelta.parse) to a document in place (ADR 0015 L5). A rollback journal
## keeps the replaced values (map arrays and records are replaced, never edited, so keeping the old reference is
## the whole "copy"); any failure, including a target authored hash that differs from the recomputed one, restores
## every touched value. This is equivalent to scratch-then-swap without copying 64 regions per commit.
## Main thread only; the hash comes from the caller's AuthoredHashCache.

const MAX_REGISTRY := 2 * WorldAssetLock.MAX_BINDINGS


## {ok, error, hash, touched: {maps: [[loc, kind]], objects: [ids], scatter, paths, rules, lock}}.
static func apply_commit(doc: WorldDocument, delta: Dictionary, cache: AuthoredHashCache) -> Dictionary:
	if delta.kind != "commit" or int(delta.base_revision) != doc.document_revision:
		return _fail("commit does not continue the document revision")
	var err := _precheck(doc, delta)
	if err != "":
		return _fail(err)
	var journal := {"maps": {}, "objects": {}, "revision": doc.document_revision, "scatter": doc.scatter,
		"paths": doc.paths, "rules": doc.rules}
	err = _mutate(doc, delta, journal, cache)
	var hash := ""
	if err == "":
		doc.document_revision = int(delta.target_revision)
		hash = cache.hash_of(doc)
		if hash != delta.target_hash:
			err = "authored hash after applying the commit does not match target_authored_hash"
	if err != "":
		_rollback(doc, journal, cache)
		return _fail(err)
	return {"ok": true, "error": "", "hash": hash, "touched": _touched(delta, journal)}


static func _precheck(doc: WorldDocument, delta: Dictionary) -> String:
	if delta.world_id != doc.world_id:
		return "commit is for another world"
	var objects_after := doc.objects.size()
	for rec: ObjectRecord in delta.upserts:
		objects_after += 0 if doc.objects.has(rec.object_id) else 1
	for id: String in delta.deletes:
		objects_after -= 1 if doc.objects.has(id) else 0
	if objects_after > doc.max_objects():
		return "commit exceeds the object limit"
	if delta.has("paths") and (delta.paths as Dictionary).size() > WorldConstants.MAX_PATHS:
		return "commit exceeds the path limit"
	if delta.has("lock") and doc.assets.size() + (delta.lock as WorldAssetLock).size() > MAX_REGISTRY:
		return "commit exceeds the asset binding registry limit"
	return _validate_tiles(delta.tiles, doc)


static func _validate_tiles(tiles: Array, doc: WorldDocument) -> String:
	for t: Dictionary in tiles:
		if doc.get_region(t.loc) == null:
			return "tile names a region the document lacks"
		if t.kind == LiveTiles.KIND_HEIGHT:
			for h in (t.bytes as PackedByteArray).to_float32_array():
				if not (h >= WorldConstants.HEIGHT_MIN and h <= WorldConstants.HEIGHT_MAX):
					return "height tile holds a value outside [%s, %s]" % [WorldConstants.HEIGHT_MIN, WorldConstants.HEIGHT_MAX]
		elif t.kind == LiveTiles.KIND_CONTROL:
			for v in (t.bytes as PackedByteArray).to_int32_array():
				if (v & WorldValidator.CONTROL_UNSUPPORTED_FAST_MASK) != 0 and not ControlCodec.is_supported(v):
					return "control tile holds an unsupported value"
	return ""


static func _mutate(doc: WorldDocument, delta: Dictionary, journal: Dictionary, cache: AuthoredHashCache) -> String:
	if delta.has("lock"):
		for id in (delta.lock as WorldAssetLock).ids():
			doc.assets.add((delta.lock as WorldAssetLock).get_binding(id))
		cache.invalidate_lock()
	var err := _binding_error(doc, delta)
	if err == "":
		err = _content_error(doc, delta)
	if err != "":
		return err
	_apply_tiles(doc, delta.tiles, journal, cache)
	_apply_objects(doc, delta, journal, cache)
	if delta.has("scatter"):
		doc.scatter = delta.scatter
		cache.invalidate_scatter()
	if delta.has("paths"):
		doc.paths = delta.paths
		cache.invalidate_paths()
	if delta.has("rules"):
		doc.rules = delta.rules
	return ""


static func _binding_error(doc: WorldDocument, delta: Dictionary) -> String:
	for rec: ObjectRecord in delta.upserts:
		if not doc.assets.has_binding(rec.binding_id):
			return "object %s uses binding %s, which no lock holds" % [rec.object_id, rec.binding_id]
	if delta.has("scatter"):
		for id in (delta.scatter as ScatterLayer).binding_ids:
			if not doc.assets.has_binding(id):
				return "scatter uses binding %s, which no lock holds" % id
	return ""


## The same record, path and scatter rules WorldValidator applies to a whole document, for the changed parts only.
static func _content_error(doc: WorldDocument, delta: Dictionary) -> String:
	for rec: ObjectRecord in delta.upserts:
		var err := WorldValidator.validate_object(rec, doc.assets, doc.layout)
		if err != "":
			return err
	if delta.has("paths"):
		for id: String in delta.paths:
			var err := WorldValidator.validate_path(delta.paths[id], doc.layout)
			if err == "" and (delta.paths[id] as PathRecord).path_id != id:
				err = "path stored under another key"
			if err != "":
				return err
	if delta.has("scatter"):
		var errors := WorldValidator._validate_scatter(delta.scatter, doc.assets, doc.layout, WorldLimits.for_schema(doc.schema_version))
		if not errors.is_empty():
			return errors[0]
	if delta.has("rules") and (delta.rules as TerrainRules).range_error() != "":
		return (delta.rules as TerrainRules).range_error()
	return ""


static func _apply_tiles(doc: WorldDocument, tiles: Array, journal: Dictionary, cache: AuthoredHashCache) -> void:
	var grouped := {}  # "x/z/kind" -> {loc, kind, updates}
	for t: Dictionary in tiles:
		var key := "%d/%d/%s" % [t.loc.x, t.loc.y, t.kind]
		if not grouped.has(key):
			grouped[key] = {"loc": t.loc, "kind": t.kind, "updates": {}}
		(grouped[key].updates as Dictionary)[Vector2i(t.tx, t.tz)] = t.bytes
	for g: Dictionary in grouped.values():
		var r := doc.get_region(g.loc)
		var old: Variant = _map_value(r, g.kind)
		journal.maps[key_of(g.loc, g.kind)] = [g.loc, g.kind, old]
		LiveTiles.set_region_bytes(r, g.kind, LiveTiles.compose(LiveTiles.bytes_of_region(r, g.kind), g.updates))
		if g.kind == LiveTiles.KIND_HEIGHT:
			doc.invalidate_height_range(g.loc)
		cache.invalidate_map(g.loc, g.kind)


static func key_of(loc: Vector2i, kind: String) -> String:
	return "%d/%d/%s" % [loc.x, loc.y, kind]


static func _map_value(r: RegionBuffers, kind: String) -> Variant:
	match kind:
		LiveTiles.KIND_HEIGHT:
			return r.heights
		LiveTiles.KIND_CONTROL:
			return r.control
	return r.color


static func _restore_map(r: RegionBuffers, kind: String, value: Variant) -> void:
	match kind:
		LiveTiles.KIND_HEIGHT:
			r.heights = value
		LiveTiles.KIND_CONTROL:
			r.control = value
		_:
			r.color = value


static func _apply_objects(doc: WorldDocument, delta: Dictionary, journal: Dictionary, cache: AuthoredHashCache) -> void:
	var ids: Array = []
	for rec: ObjectRecord in delta.upserts:
		journal.objects[rec.object_id] = doc.get_object(rec.object_id)
		doc.put_object(rec)
		ids.append(rec.object_id)
	for id: String in delta.deletes:
		journal.objects[id] = doc.get_object(id)
		doc.remove_object(id)
		ids.append(id)
	cache.invalidate_objects(ids)


static func _rollback(doc: WorldDocument, journal: Dictionary, cache: AuthoredHashCache) -> void:
	for entry: Array in journal.maps.values():
		_restore_map(doc.get_region(entry[0]), entry[1], entry[2])
		if entry[1] == LiveTiles.KIND_HEIGHT:
			doc.invalidate_height_range(entry[0])
	for id: String in journal.objects:
		var old: ObjectRecord = journal.objects[id]
		if old == null:
			doc.remove_object(id)
		else:
			doc.put_object(old)
	doc.scatter = journal.scatter
	doc.paths = journal.paths
	doc.rules = journal.rules
	doc.document_revision = journal.revision
	cache.invalidate_all()


static func _touched(delta: Dictionary, journal: Dictionary) -> Dictionary:
	var maps: Array = []
	for entry: Array in journal.maps.values():
		maps.append([entry[0], entry[1]])
	return {"maps": maps, "objects": journal.objects.keys(), "scatter": delta.has("scatter"),
		"paths": delta.has("paths"), "rules": delta.has("rules"), "lock": delta.has("lock")}


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "hash": "", "touched": {}}
