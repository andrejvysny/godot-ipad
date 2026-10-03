class_name LivePreviewSampler
extends RefCounted
## Provisional sampling of ONE open EditTransaction (ADR 0015 L6). Runs at most 15 Hz: tiles of the regions the
## transaction captured are compared with the bytes last sent for this operation (initially the committed base,
## i.e. the transaction's before-values); captured objects are sent as absolute records; scatter WPST tiles are
## rebuilt at most 4 Hz, only for tiles inside rectangles the tools reported through mark_scatter_rect(), on a
## worker thread from a frozen copy of the layer. Pending values are coalesced by key (tile, object, scatter
## tile): a newer sample overwrites the pending value, so dropping intermediate batches loses nothing.
## Main thread only. Nothing here transmits or mutates the document.

const MIN_INTERVAL_MSEC := 66  # 15 Hz
const SCATTER_INTERVAL_MSEC := 250  # 4 Hz
const MAX_SCATTER_TILES_PER_JOB := 256

var operation_id := ""
## Pending coalesced values (key -> value); take() hands them over.
var pending_tiles: Dictionary = {}  # "x/z/tx/tz/kind" -> {loc, tx, tz, kind, bytes}
var pending_objects: Dictionary = {}  # object id -> ObjectRecord, or null = deleted
var pending_scatter: Dictionary = {}  # "x/z/tx/tz" -> {loc, tx, tz, bytes, binding_ids}

var _doc: WorldDocument
var _tx: EditTransaction
var _sent: Dictionary = {}  # "x/z/kind" -> byte image of the region map last sampled
var _objects_sent: Dictionary = {}  # id -> ObjectRecord or null
var _scatter_dirty: Dictionary = {}  # tile key -> Vector3i(region x, region z, tile index tx*4+tz)
var _scatter_sent: Dictionary = {}  # tile key -> sha256 hex of the WPST last sampled
var _scatter_job: Dictionary = {}  # {task, frozen, keys}
var _last_msec := -1000000
var _last_scatter_msec := -1000000


func bind(doc: WorldDocument, tx: EditTransaction) -> void:
	_doc = doc
	_tx = tx
	operation_id = tx.operation_id


func is_bound_to(tx: EditTransaction) -> bool:
	return _tx == tx and _tx != null and _tx.operation_id == operation_id


func has_pending() -> bool:
	return not (pending_tiles.is_empty() and pending_objects.is_empty() and pending_scatter.is_empty())


## Tools report the world-XZ rectangle whose scatter instances changed (ToolContext.scatter_changed).
func mark_scatter_rect(rect: Rect2) -> void:
	if _doc == null or not rect.has_area():
		return
	var area := rect.intersection(_doc.layout.extent_rect())
	if not area.has_area():
		return
	var lo := LiveTiles.tile_at(area.position.x, area.position.y)
	var hi := LiveTiles.tile_at(area.end.x - 0.0001, area.end.y - 0.0001)
	var gx0: int = lo.loc.x * 4 + lo.tx
	var gx1: int = hi.loc.x * 4 + hi.tx
	var gz0: int = lo.loc.y * 4 + lo.tz
	var gz1: int = hi.loc.y * 4 + hi.tz
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			_scatter_dirty[Vector2i(gx, gz)] = true


## Samples when the rate gate allows (or `force`). Returns true when anything is pending afterwards.
func sample(now_msec: int, force: bool = false) -> bool:
	if _tx == null or not _tx.is_open():
		return has_pending()
	_collect_scatter_job()
	if not force and now_msec - _last_msec < MIN_INTERVAL_MSEC:
		return has_pending()
	_last_msec = now_msec
	for kind in LiveTiles.KINDS:
		for loc: Vector2i in _touched_regions(kind):
			_sample_map(loc, kind)
	_sample_objects()
	if _tx.has_captured_scatter() and (force or now_msec - _last_scatter_msec >= SCATTER_INTERVAL_MSEC):
		_last_scatter_msec = now_msec
		_start_scatter_job()
	return has_pending()


## Hands over and clears the pending values: {tiles, objects (ObjectRecord), deletes (ids), scatter_tiles}.
func take() -> Dictionary:
	var objects: Array = []
	var deletes: Array = []
	for id: String in pending_objects:
		if pending_objects[id] == null:
			deletes.append(id)
		else:
			objects.append(pending_objects[id])
	var out := {"tiles": pending_tiles.values(), "objects": objects, "deletes": deletes,
		"scatter_tiles": pending_scatter.values()}
	pending_tiles = {}
	pending_objects = {}
	pending_scatter = {}
	return out


## Waits for a running scatter job and collects it (tests, end of operation).
func flush_scatter() -> void:
	if not _scatter_job.is_empty() and not _scatter_job.get("waited", false):
		WorkerThreadPool.wait_for_task_completion(_scatter_job.task)
		_scatter_job["waited"] = true
	_collect_scatter_job()


func scatter_busy() -> bool:
	return not _scatter_job.is_empty()


func finish() -> void:
	flush_scatter()
	_tx = null
	_doc = null
	pending_tiles = {}
	pending_objects = {}
	pending_scatter = {}


func _touched_regions(kind: String) -> Array:
	match kind:
		LiveTiles.KIND_HEIGHT:
			return _tx.touched_height_regions()
		LiveTiles.KIND_CONTROL:
			return _tx.touched_control_regions()
	return _tx.touched_color_regions()


func _sample_map(loc: Vector2i, kind: String) -> void:
	var r := _doc.get_region(loc)
	if r == null:
		return
	var key := LiveDeltaApply.key_of(loc, kind)
	if not _sent.has(key):
		_sent[key] = LiveTiles.bytes_of_array(kind, _before_array(loc, kind))
	var now := LiveTiles.bytes_of_region(r, kind)
	for t in LiveTiles.changed_tiles(_sent[key], now):
		pending_tiles["%s/%d/%d" % [key, t.x, t.y]] = {"loc": loc, "tx": t.x, "tz": t.y, "kind": kind,
			"bytes": LiveTiles.tile(now, t.x, t.y)}
	_sent[key] = now


func _before_array(loc: Vector2i, kind: String) -> Variant:
	match kind:
		LiveTiles.KIND_HEIGHT:
			return _tx.before_heights(loc)
		LiveTiles.KIND_CONTROL:
			return _tx.before_controls(loc)
	return _tx.before_colors(loc)


func _sample_objects() -> void:
	for id: String in _tx.captured_object_ids():
		var cur := _doc.get_object(id)
		var last: ObjectRecord = _objects_sent[id] if _objects_sent.has(id) else _tx.before_object(id)
		if (cur == null) == (last == null) and (cur == null or cur.equals(last)):
			continue
		var copy: ObjectRecord = cur.clone() if cur != null else null
		pending_objects[id] = copy
		_objects_sent[id] = copy


func _start_scatter_job() -> void:
	if _scatter_dirty.is_empty() or not _scatter_job.is_empty():
		return
	var keys: Array = []
	for k: Vector2i in _scatter_dirty:
		keys.append(k)
		if keys.size() >= MAX_SCATTER_TILES_PER_JOB:
			break
	for k: Vector2i in keys:
		_scatter_dirty.erase(k)
	var frozen := {"layer": _doc.scatter.clone(), "keys": keys, "result": []}
	_scatter_job = {"frozen": frozen, "keys": keys,
		"task": WorkerThreadPool.add_task(LivePreviewSampler._run_scatter_job.bind(frozen))}


func _collect_scatter_job() -> void:
	if _scatter_job.is_empty():
		return
	if not _scatter_job.get("waited", false):
		if not WorkerThreadPool.is_task_completed(_scatter_job.task):
			return
		WorkerThreadPool.wait_for_task_completion(_scatter_job.task)
	for t: Dictionary in _scatter_job.frozen.result:
		var key := "%d/%d/%d/%d" % [t.loc.x, t.loc.y, t.tx, t.tz]
		var digest := CanonicalEncoder.sha256_hex(t.bytes)
		if _scatter_sent.get(key, "") != digest:
			_scatter_sent[key] = digest
			pending_scatter[key] = t
	_scatter_job = {}


## Worker thread: one pass over the frozen layer, then one WPST per requested 32 m tile.
static func _run_scatter_job(frozen: Dictionary) -> void:
	var layer: ScatterLayer = frozen.layer
	var wanted := {}
	for k: Vector2i in frozen.keys:
		wanted[k] = []
	for i in layer.count():
		var key := Vector2i(floori(layer.x[i] / LiveTiles.SCATTER_TILE_METERS), floori(layer.z[i] / LiveTiles.SCATTER_TILE_METERS))
		if wanted.has(key):
			(wanted[key] as Array).append(i)
	var out: Array = []
	for k: Vector2i in frozen.keys:
		var indices := PackedInt32Array(wanted[k])
		var bytes := LiveScatterTile.encode(layer, indices)
		if bytes.is_empty():
			continue  # more than 16384 instances in one tile: no preview for it
		var ids := PackedStringArray()
		for i in indices:
			if not ids.has(layer.binding_of(i)):
				ids.append(layer.binding_of(i))
		out.append({"loc": Vector2i(floori(k.x / 4.0), floori(k.y / 4.0)), "tx": posmod(k.x, 4), "tz": posmod(k.y, 4),
			"bytes": bytes, "binding_ids": ids})
	frozen["result"] = out
