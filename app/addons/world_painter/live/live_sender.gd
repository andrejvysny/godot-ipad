class_name LiveSender
extends RefCounted
## iPad-side sender of the live protocol (INT-SPEC-1.1 §10, ADR 0015). Transport-independent: the owner feeds it
## EditorSession.world_committed / world_replaced, calls tick() every frame and pump() with a LiveTransport, and
## passes received text messages to on_text().
## - Streams: a new stream_id (and a fresh stable snapshot) for a new world, a revision gap, spool overflow, a hash
##   mismatch, a receiver resync request or a failed blob. Within a stream `revision` rises by exactly one.
## - Commits: one world-delta-v1 archive per committed change, kept in the bounded LiveSpool until acknowledged.
## - Snapshots: captured only when no operation is open; plain values are frozen on the main thread and the
##   .worldpoc is written (and hashed) on a worker.
## - Previews: LivePreviewSampler output, materialized lazily when the queue head is reached; preview_cancel when an
##   operation ends without a commit.
## Main thread only. Nothing here blocks on the network.

const SCRATCH_ROOT := "user://live/tmp"
const CAPTURE_RETRY_MSEC := 2000

var world_id := ""
var spool := LiveSpool.new()
var outbox := LiveOutbox.new()
var created_with: Dictionary = {}
var scratch_root := SCRATCH_ROOT
var preview_enabled := true
## `() -> EditTransaction`: the open transaction (ToolController.open_transaction), null when idle.
var tx_provider := Callable()
var stats := {"streams": 0, "snapshots": 0, "snapshot_failures": 0, "commits": 0, "previews": 0, "preview_cancels": 0,
	"gaps": 0, "spool_overflows": 0, "resyncs": 0, "rejected": 0, "acked_revision": -1, "visual_ready": true,
	"last_reason": "", "errors": 0, "last_error": ""}

var _doc: WorldDocument
var _cache := AuthoredHashCache.new()
var _connected := false
var _revision := -1
var _hash := ""
var _lock_digest := PackedByteArray()
var _snapshot_reason := ""
var _snapshot_meta := {}
var _snapshot_job := {}
var _job_gen := 0
var _baseline_acked := false
var _next_capture_msec := 0
var _now_msec := 0
var _sampler: LivePreviewSampler
var _op_announced := false
var _preview_seq := 0
var _early_rects: Array[Rect2] = []


func _init() -> void:
	outbox.stream_id = LiveIds.new_id()
	outbox.materialize = _materialize_preview


func stream_id() -> String:
	return outbox.stream_id


func revision() -> int:
	return _revision


func authored_hash() -> String:
	return _hash


func baseline_acked() -> bool:
	return _baseline_acked


func snapshot_pending() -> bool:
	return _snapshot_reason != "" or not _snapshot_job.is_empty()


## A new or replaced document: new stream, new snapshot (EditorSession.world_replaced).
func set_document(doc: WorldDocument) -> void:
	_doc = doc
	world_id = doc.world_id
	_new_stream("world replaced")


func start_session(session_id: String) -> void:
	outbox.session_id = session_id
	_connected = true
	if _snapshot_reason == "" and _snapshot_job.is_empty() and _revision >= 0:
		if _baseline_acked:
			outbox.control("resume", {"world_id": world_id, "stream_id": outbox.stream_id, "revision": _revision,
				"authored_hash": _hash})
		else:
			_new_stream("baseline was never acknowledged")


func end_session() -> void:
	_connected = false
	outbox.purge(false)
	if not _snapshot_job.is_empty():
		_new_stream("connection lost during snapshot")
	_end_operation(false)


# --- Committed changes -------------------------------------------------------------------------

## EditorSession.world_committed. `change` null = a revision without terrain/object content (asset binding update).
func on_committed(change: WorldChange, revision: int, forward: bool) -> void:
	if _doc == null:
		return
	var c := change
	if c == null:
		c = WorldChange.new()
		c.operation_id = ObjectRecord.new_uuid_v4()
		forward = true
		_cache.invalidate_lock()
	else:
		_cache.invalidate_change(c)
	if _sampler != null and c.operation_id == _sampler.operation_id:
		_end_operation(false)
	if _snapshot_reason != "" or _revision < 0:
		return  # no baseline yet: the snapshot taken later contains this change
	if revision != _revision + 1:
		stats.gaps += 1
		_new_stream("revision gap")
		return
	_record_commit(c, revision, forward)


func _record_commit(change: WorldChange, revision: int, forward: bool) -> void:
	var hash := _cache.hash_of(_doc)
	if hash == "":
		_new_stream("asset lock cannot be encoded")
		return
	var ident := {"world_id": world_id, "stream_id": outbox.stream_id, "operation_id": change.operation_id,
		"base_revision": _revision, "base_hash": _hash, "target_revision": revision, "target_hash": hash}
	var path := spool.entry_path(outbox.stream_id, revision)
	var res := WorldDeltaBuilder.build_commit(change, forward, ident, _delta_files(change), path)
	var meta := {"base_revision": _revision, "target_revision": revision, "base_hash": _hash, "target_hash": hash,
		"operation_id": change.operation_id}
	if not res.ok or not spool.add(outbox.stream_id, meta, path):
		_new_stream("commit delta could not be built")
		return
	_revision = revision
	_hash = hash
	_lock_digest = _cache.lock_digest()
	if spool.overflowed():
		stats.spool_overflows += 1
		_new_stream("spool overflow")
	elif _connected:
		_queue_commit(spool.entry_for(revision))


func _delta_files(change: WorldChange) -> Dictionary:
	var files := {}
	if _cache.lock_digest() != _lock_digest:
		files["asset_lock_file"] = _cache.lock_bytes()
	if change.has_scatter():
		files["scatter_file"] = _cache.scatter_bytes()
	if not change.before_paths.is_empty():
		files["paths_file"] = _cache.paths_bytes()
	return files


func _queue_commit(entry: Dictionary) -> void:
	var framer := LiveSpool.framer_of(entry, LiveIds.new_id())
	if framer == null:
		_new_stream("spooled commit is unreadable")
		return
	outbox.blob("commit", framer, {"operation_id": entry.operation_id, "base_revision": entry.base_revision,
		"base_authored_hash": entry.base_hash, "target_revision": entry.target_revision,
		"target_authored_hash": entry.target_hash}, entry.operation_id, int(entry.target_revision))
	stats.commits += 1


# --- Streams and snapshots -----------------------------------------------------------------------

func _new_stream(reason: String) -> void:
	var aborts := outbox.purge(true)
	outbox.stream_id = LiveIds.new_id()
	outbox.push_front_texts(aborts)
	spool.clear()
	_job_gen += 1
	_revision = -1
	_hash = ""
	_baseline_acked = false
	_snapshot_reason = reason
	_snapshot_meta = {}
	_end_operation(false)
	stats.streams += 1
	stats.last_reason = reason


## Call every frame. `now_msec` is Time.get_ticks_msec() (injectable for tests).
func tick(now_msec: int) -> void:
	_now_msec = now_msec
	_collect_snapshot()
	_maybe_capture()
	_tick_preview()


func _operation_open() -> bool:
	if not tx_provider.is_valid():
		return false
	var tx: EditTransaction = tx_provider.call()
	return tx != null and tx.is_open()


func _maybe_capture() -> void:
	if _snapshot_reason == "" or not _connected or _doc == null or not _snapshot_job.is_empty() \
			or _now_msec < _next_capture_msec or _operation_open():
		return
	var frozen := LiveSnapshot.freeze(_doc, _cache, created_with)
	if frozen.has("error"):
		stats.snapshot_failures += 1
		_next_capture_msec = _now_msec + CAPTURE_RETRY_MSEC
		return
	var transfer_id := LiveIds.new_id()
	var out_path := scratch_root.path_join(transfer_id + ".worldpoc")
	StorageFs.make_dir(scratch_root)
	var box := {}
	var item := outbox.blob("snapshot", null, {}, "", _doc.document_revision, false)
	item.temp_path = out_path
	_snapshot_job = {"task": WorkerThreadPool.add_task(LiveSender._run_snapshot.bind(box, frozen.snap, out_path)),
		"box": box, "item": item, "transfer_id": transfer_id, "gen": _job_gen, "hash": frozen.hash, "path": out_path}
	_revision = _doc.document_revision
	_hash = frozen.hash
	_lock_digest = _cache.lock_digest()
	_snapshot_meta = {"revision": _revision, "hash": _hash, "stream_id": outbox.stream_id}
	_snapshot_reason = ""
	spool.clear()


static func _run_snapshot(box: Dictionary, snap: Dictionary, path: String) -> void:
	var res := LiveSnapshot.write(snap, path)
	if res.ok:
		res["sha256"] = LiveBlobFramer.hash_file(path)
	box["result"] = res


func _collect_snapshot() -> void:
	if _snapshot_job.is_empty():
		return
	if not _snapshot_job.get("waited", false):
		if not WorkerThreadPool.is_task_completed(_snapshot_job.task):
			return
		WorkerThreadPool.wait_for_task_completion(_snapshot_job.task)
	var job := _snapshot_job
	_snapshot_job = {}
	var res: Dictionary = job.box.result
	if job.gen != _job_gen:
		DirAccess.remove_absolute(job.path)  # the stream moved on; the purge already dropped the queue item
		return
	if not res.ok or res.hash != job.hash:
		stats.snapshot_failures += 1
		outbox.queue.erase(job.item)
		(job.item as LiveOutItem).cleanup()
		_snapshot_reason = "snapshot failed"
		_next_capture_msec = _now_msec + CAPTURE_RETRY_MSEC
		return
	var framer := LiveBlobFramer.from_file_known(job.transfer_id, job.path, int(res.bytes), res.sha256)
	if outbox.fill(job.item, framer, {}):
		job.item.ready = true
		stats.snapshots += 1
	else:
		outbox.queue.erase(job.item)
		_snapshot_reason = "snapshot failed"


## Test helper: waits for the preview sampler's scatter worker.
func flush_preview() -> void:
	if _sampler != null:
		_sampler.flush_scatter()


## Test helper: waits for the snapshot worker and collects it.
func flush_snapshot() -> void:
	if not _snapshot_job.is_empty() and not _snapshot_job.get("waited", false):
		WorkerThreadPool.wait_for_task_completion(_snapshot_job.task)
		_snapshot_job["waited"] = true
	_collect_snapshot()


# --- Previews --------------------------------------------------------------------------------------

## Scatter edits reported before this frame's tick created the sampler are kept (merged into one rect once
## there are many) and replayed into it.
func mark_scatter_rect(rect: Rect2) -> void:
	if _sampler != null:
		_sampler.mark_scatter_rect(rect)
	elif _operation_open():
		_early_rects.append(rect)
		if _early_rects.size() > 64:
			var union := _early_rects[0]
			for r in _early_rects:
				union = union.merge(r)
			_early_rects = [union]


func _tick_preview() -> void:
	var tx: EditTransaction = tx_provider.call() if tx_provider.is_valid() else null
	if tx == null or not tx.is_open():
		_end_operation(true)  # ended without a commit signal: cancelled
		_early_rects = []
		return
	if _sampler == null or not _sampler.is_bound_to(tx):
		_end_operation(true)
		if _doc == null:
			return
		_sampler = LivePreviewSampler.new()
		_sampler.bind(_doc, tx)
		_preview_seq = 0
		_op_announced = false
		for r in _early_rects:
			_sampler.mark_scatter_rect(r)
		_early_rects = []
	if not (preview_enabled and _connected and _baseline_acked):
		return
	if _sampler.sample(_now_msec) and not outbox.has_kind("preview"):
		outbox.blob("preview", null, {}, _sampler.operation_id, _revision)


## Ends the sampled operation. `cancelled`: no commit arrived, so the receiver is told to drop its overlay.
func report_provider_failure() -> void:
	_end_operation(true)


func _end_operation(cancelled: bool) -> void:
	if _sampler == null:
		return
	outbox.drop_unstarted("preview")
	if cancelled and _op_announced and _connected:
		outbox.control("preview_cancel", {"operation_id": _sampler.operation_id})
		stats.preview_cancels += 1
	_sampler.finish()
	_sampler = null
	_op_announced = false
	_early_rects = []


func _materialize_preview(item: LiveOutItem) -> bool:
	if _sampler == null or not _sampler.has_pending():
		return false
	var batch := _sampler.take()
	_preview_seq += 1
	var ident := {"world_id": world_id, "stream_id": outbox.stream_id, "operation_id": _sampler.operation_id,
		"base_revision": _revision, "preview_seq": _preview_seq}
	var path := scratch_root.path_join(LiveIds.new_id() + ".preview")
	StorageFs.make_dir(scratch_root)
	var res := WorldDeltaBuilder.build_preview(ident, batch.tiles, batch.objects, batch.deletes, batch.scatter_tiles,
		_provisional_rows(batch), path)
	if not res.ok:
		return false
	var framer := LiveBlobFramer.from_file(LiveIds.new_id(), path)
	if framer == null or not outbox.fill(item, framer, {"operation_id": _sampler.operation_id,
			"base_revision": _revision, "preview_seq": _preview_seq}):
		DirAccess.remove_absolute(path)
		return false
	item.temp_path = path
	_op_announced = true
	stats.previews += 1
	return true


## Lock rows of bindings the preview references that the committed lock does not hold yet.
func _provisional_rows(batch: Dictionary) -> Array:
	var committed := _cache.lock_binding_ids()
	var wanted := {}
	for rec: ObjectRecord in batch.objects:
		wanted[rec.binding_id] = true
	for t: Dictionary in batch.scatter_tiles:
		for id in t.binding_ids:
			wanted[id] = true
	var rows: Array = []
	var ids := wanted.keys()
	ids.sort()
	for id: String in ids:
		var b := _doc.assets.get_binding(id)
		if not committed.has(id) and b != null:
			rows.append(b.to_dict(true))
	return rows


# --- Transport and receiver messages ---------------------------------------------------------------

func pump(transport: LiveTransport) -> int:
	var n := outbox.pump(transport)
	if not outbox.failed_items.is_empty():
		outbox.failed_items.clear()
		_new_stream("a queued archive became unreadable")
	return n


func on_text(text: String) -> void:
	var parsed := LiveEnvelope.parse(text, true, outbox.session_id)
	if not parsed.ok:
		stats.rejected += 1
		return
	var env: Dictionary = parsed.envelope
	var p: Dictionary = env.payload
	match env.type:
		"commit_ack":
			_on_commit_ack(p)
		"snapshot_ack":
			_on_snapshot_ack(p)
		"resume_result":
			_on_resume_result(p)
		"resync_required":
			if env.stream_id != outbox.stream_id:
				return  # about a stream that was already replaced
			stats.resyncs += 1
			_new_stream("receiver requested resync: " + str(p.reason).left(80))
		"ping":
			outbox.control("pong", {"nonce": p.nonce})
		"error":
			stats.errors += 1
			stats.last_error = "%s: %s" % [p.code, str(p.message).left(120)]
		"session_close":
			end_session()


func _on_commit_ack(p: Dictionary) -> void:
	if p.stream_id != outbox.stream_id or p.world_id != world_id:
		return
	var entry := spool.entry_for(int(p.revision))
	if entry.is_empty():
		return
	if entry.target_hash != p.authored_hash:
		_new_stream("receiver hash differs at revision %d" % int(p.revision))
		return
	spool.ack(int(p.revision))
	stats.acked_revision = int(p.revision)
	stats.visual_ready = bool(p.visual_ready)


func _on_snapshot_ack(p: Dictionary) -> void:
	if _snapshot_meta.is_empty() or p.stream_id != outbox.stream_id or p.world_id != world_id:
		return
	if int(p.revision) != int(_snapshot_meta.revision) or p.authored_hash != _snapshot_meta.hash:
		_new_stream("receiver installed a different snapshot")
		return
	_baseline_acked = true
	stats.acked_revision = int(p.revision)
	stats.visual_ready = bool(p.visual_ready)


func _on_resume_result(p: Dictionary) -> void:
	if p.mode == "snapshot":
		_new_stream("receiver has no matching state")
		return
	var chain: Variant = spool.chain_after(int(p.revision), p.authored_hash, _revision)
	if chain == null or (int(p.revision) == _revision and p.authored_hash != _hash):
		_new_stream("exact resume is not possible")
		return
	for entry: Dictionary in chain:
		_queue_commit(entry)
