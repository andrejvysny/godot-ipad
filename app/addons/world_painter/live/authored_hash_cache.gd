class_name AuthoredHashCache
extends RefCounted
## Incremental authored content hash V4 (contracts/world-painter/world-v4/authored-hash-v4.md). The result is
## byte-identical to CanonicalEncoder.authored_hash(doc); only the parts a caller invalidated are recomputed:
## per-region map digests, scatter.bin / paths.bin digests, per-object canonical bytes, and the asset lock.
## Main thread only. The cache does not watch the document; it relies on the owner invalidating exactly what an
## operation touched (invalidate_change for a WorldChange, the explicit calls for a received delta). A different
## document instance, or an object count that disagrees with the cache, falls back to a full rebuild.

const SUFFIXES := {LiveTiles.KIND_HEIGHT: ".height.f32le", LiveTiles.KIND_CONTROL: ".control.u32le",
	LiveTiles.KIND_COLOR: ".color.rgba8"}

## Diagnostics of the most recent hash_of(): map digests and object chunks recomputed.
var maps_hashed := 0
var objects_encoded := 0

var _doc_id := 0
var _map_digests: Dictionary = {}  # Vector2i -> {kind: PackedByteArray raw sha256}; missing = stale
var _scatter_digest := PackedByteArray()
var _scatter_bytes := PackedByteArray()
var _paths_digest := PackedByteArray()
var _paths_bytes := PackedByteArray()
var _lock_digest := PackedByteArray()
var _lock_bytes := PackedByteArray()
var _lock_stale := true
var _lock_ids: Dictionary = {}  # binding id -> true, every row of the referenced lock
var _ids: Array = []  # sorted object ids
var _canon: Array = []  # PackedByteArray per id (CanonicalEncoder.encode_object)
var _bindings: Array = []  # binding id per id
var _counts: Dictionary = {}  # binding id -> record count
var _dirty_objects: Dictionary = {}
var _objects_stale := true


func invalidate_all() -> void:
	_map_digests.clear()
	_scatter_digest = PackedByteArray()
	_paths_digest = PackedByteArray()
	_lock_stale = true
	_objects_stale = true
	_dirty_objects.clear()


## Marks everything a WorldChange touched (forward or undo: the touched keys are the same).
func invalidate_change(change: WorldChange) -> void:
	for loc: Vector2i in change.height_regions():
		invalidate_map(loc, LiveTiles.KIND_HEIGHT)
	for loc: Vector2i in change.control_regions():
		invalidate_map(loc, LiveTiles.KIND_CONTROL)
	for loc: Vector2i in change.color_regions():
		invalidate_map(loc, LiveTiles.KIND_COLOR)
	invalidate_objects(change.object_ids())
	if change.has_scatter():
		invalidate_scatter()
	if not change.before_paths.is_empty():
		invalidate_paths()


func invalidate_map(loc: Vector2i, kind: String) -> void:
	if _map_digests.has(loc):
		(_map_digests[loc] as Dictionary).erase(kind)


func invalidate_objects(ids: Array) -> void:
	for id: String in ids:
		_dirty_objects[id] = true


func invalidate_scatter() -> void:
	_scatter_digest = PackedByteArray()
	_lock_stale = true


func invalidate_paths() -> void:
	_paths_digest = PackedByteArray()


func invalidate_lock() -> void:
	_lock_stale = true


## Hex hash of `doc`, or "" when its asset lock cannot be encoded.
func hash_of(doc: WorldDocument) -> String:
	maps_hashed = 0
	objects_encoded = 0
	if doc.get_instance_id() != _doc_id:
		invalidate_all()
		_doc_id = doc.get_instance_id()
	_refresh_objects(doc)
	if _lock_stale or _lock_digest.is_empty():
		var lock := doc.assets.encode_referenced(doc, PackedStringArray(_counts.keys()))
		if lock[1] != "":
			return ""
		_lock_bytes = lock[0]
		_lock_digest = CanonicalEncoder.sha256(_lock_bytes)
		_lock_ids = _ids_of_lock(_lock_bytes)
		_lock_stale = false
	if _scatter_digest.is_empty():
		_scatter_bytes = doc.scatter.encode()
		_scatter_digest = CanonicalEncoder.sha256(_scatter_bytes)
	if _paths_digest.is_empty():
		_paths_bytes = PathRecord.encode_all(doc.paths)
		_paths_digest = CanonicalEncoder.sha256(_paths_bytes)
	var digests := {WorldConstants.ASSET_LOCK_FILE: _lock_digest, WorldConstants.SCATTER_FILE: _scatter_digest,
		WorldConstants.PATHS_FILE: _paths_digest}
	_collect_map_digests(doc, digests)
	return CanonicalEncoder.authored_hash_of_parts(doc.layout, doc.rules, digests, _canon)


## Canonical asset_locks.json bytes of the last hash_of() (the referenced lock).
func lock_bytes() -> PackedByteArray:
	return _lock_bytes


## Binding ids the referenced lock of the last hash_of() holds (objects and scatter slots).
func lock_binding_ids() -> Dictionary:
	return _lock_ids


func lock_digest() -> PackedByteArray:
	return _lock_digest


func scatter_bytes() -> PackedByteArray:
	return _scatter_bytes


func paths_bytes() -> PackedByteArray:
	return _paths_bytes


## Binding ids referenced by at least one object record.
func binding_ids() -> PackedStringArray:
	return PackedStringArray(_counts.keys())


func _collect_map_digests(doc: WorldDocument, digests: Dictionary) -> void:
	for loc in doc.layout.region_locations():
		var r := doc.get_region(loc)
		var entry: Dictionary = _map_digests.get(loc, {})
		var stem := WorldConstants.region_file_stem(loc)
		for kind: String in LiveTiles.KINDS:
			if not entry.has(kind):
				entry[kind] = CanonicalEncoder.sha256(LiveTiles.bytes_of_region(r, kind)) if r != null else PackedByteArray()
				maps_hashed += 1
			digests[stem + SUFFIXES[kind]] = entry[kind]
		_map_digests[loc] = entry


func _refresh_objects(doc: WorldDocument) -> void:
	if _objects_stale or (_ids.size() != doc.objects.size() and _dirty_objects.is_empty()):
		_rebuild_objects(doc)
		return
	if _dirty_objects.is_empty():
		return
	for id: String in _dirty_objects:
		_apply_object(doc, id)
	_dirty_objects.clear()
	if _ids.size() != doc.objects.size():
		_rebuild_objects(doc)  # a write that bypassed put_object/remove_object


func _rebuild_objects(doc: WorldDocument) -> void:
	_ids = Array(doc.sorted_object_ids())
	_canon = []
	_bindings = []
	_counts = {}
	for id: String in _ids:
		var rec := doc.get_object(id)
		_canon.append(ObjectChunkCache.canon_chunk(rec))
		_bindings.append(rec.binding_id)
		_count(rec.binding_id, 1)
	objects_encoded = _ids.size()
	_dirty_objects.clear()
	_objects_stale = false
	_lock_stale = true


func _apply_object(doc: WorldDocument, id: String) -> void:
	var at := _ids.bsearch(id, true)
	var known: bool = at < _ids.size() and _ids[at] == id
	var rec := doc.get_object(id)
	if rec == null:
		if known:
			_count(_bindings[at], -1)
			_ids.remove_at(at)
			_canon.remove_at(at)
			_bindings.remove_at(at)
		return
	objects_encoded += 1
	if known:
		_count(_bindings[at], -1)
		_canon[at] = ObjectChunkCache.canon_chunk(rec)
		_bindings[at] = rec.binding_id
	else:
		_ids.insert(at, id)
		_canon.insert(at, ObjectChunkCache.canon_chunk(rec))
		_bindings.insert(at, rec.binding_id)
	_count(rec.binding_id, 1)


func _count(binding_id: String, delta: int) -> void:
	var before := int(_counts.get(binding_id, 0))
	var n := before + delta
	if n > 0:
		_counts[binding_id] = n
	else:
		_counts.erase(binding_id)
	if (before == 0) != (n <= 0):
		_lock_stale = true  # the set of referenced bindings changed


static func _ids_of_lock(bytes: PackedByteArray) -> Dictionary:
	var out := {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("bindings")) == TYPE_ARRAY:
		for row: Variant in parsed.bindings:
			if typeof(row) == TYPE_DICTIONARY and row.has("binding_id"):
				out[row.binding_id] = true
	return out
