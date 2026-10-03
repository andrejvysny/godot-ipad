class_name LiveReplica
extends RefCounted
## Receiver-side logic of the live protocol (INT-SPEC-1.1 §10, ADR 0015): the committed replica document plus the
## provisional overlay. Transport-independent: feed it text and binary messages, collect what it wants to send with
## take_outgoing(). The committed document changes only through a fully validated snapshot install or a commit apply
## that reproduced the sender's target_authored_hash; every other situation (gap, unexpected base hash, conflicting
## duplicate, wrong stream, invalid delta) ends in resync_required and leaves the document untouched.
## Previews only ever touch the overlay. Main thread only.

signal commit_applied(touched: Dictionary)

const HISTORY := 256
const ZERO_HASH := "0000000000000000000000000000000000000000000000000000000000000000"

var document: WorldDocument
var overlay := LiveOverlay.new()
var session_id := ""
## `() -> bool`: whether every referenced binding is usable (visual readiness); default = lock availability.
var visual_probe := Callable()
var stats := {"snapshots": 0, "commits": 0, "replays": 0, "previews": 0, "stale_previews": 0, "resyncs": 0,
	"rejected": 0, "overlay_timeouts": 0, "last_resync": ""}

var _stream_id := ""
var _catalog: AssetCatalog
var _tmp_root: String
var _blobs: LiveBlobReceiver
var _cache := AuthoredHashCache.new()
var _hash := ""
var _history: Dictionary = {}  # revision -> authored hash of recently installed commits
var _transfers: Dictionary = {}  # transfer id -> {kind, meta}
var _aborted: Dictionary = {}
var _out: Array[String] = []
var _now_msec := 0


func _init(p_session_id: String, p_catalog: AssetCatalog, p_root: String) -> void:
	session_id = p_session_id
	_catalog = p_catalog
	_tmp_root = p_root.path_join("extract")
	_blobs = LiveBlobReceiver.new(p_root.path_join("blobs"))


func stream_id() -> String:
	return _stream_id


func authored_hash() -> String:
	return _hash


func revision() -> int:
	return document.document_revision if document != null else -1


func take_outgoing() -> Array[String]:
	var out := _out
	_out = []
	return out


## Connection lost or re-established: provisional state and unfinished transfers are discarded.
func reset_connection() -> void:
	overlay.clear()
	_blobs.abort_all()
	_transfers.clear()


func tick(now_msec: int) -> void:
	_now_msec = now_msec
	if overlay.expired(now_msec):
		overlay.clear()
		stats.overlay_timeouts += 1


func on_text(text: String, now_msec: int = 0) -> void:
	_now_msec = now_msec
	var parsed := LiveEnvelope.parse(text, true, session_id)
	if not parsed.ok:
		stats.rejected += 1
		_send("error", {"code": "bad_message", "message": str(parsed.error).left(200)}, _stream_id)
		return
	var env: Dictionary = parsed.envelope
	var p: Dictionary = env.payload
	match env.type:
		"blob_begin":
			_on_blob_begin(env.stream_id, p)
		"blob_end":
			_on_blob_end(env.stream_id, p.transfer_id)
		"blob_abort":
			_drop_transfer(p.transfer_id)
		"preview_cancel":
			if overlay.operation_id == p.operation_id:
				overlay.clear()
		"resume":
			_on_resume(p)
		"ping":
			_send("pong", {"nonce": p.nonce}, _stream_id)


func on_binary(data: PackedByteArray) -> void:
	var res := _blobs.add_frame(data)
	if res.ok:
		return
	var id: String = res.transfer_id
	if id == "" or not _transfers.has(id):
		stats.rejected += 1
		return
	var kind: String = _transfers[id].kind
	_drop_transfer(id)
	if kind != "preview":
		_resync("blob transfer failed: " + str(res.error).left(120), _stream_id)


func _drop_transfer(id: String) -> void:
	_blobs.abort(id)
	_transfers.erase(id)
	_aborted[id] = true


func _on_resume(p: Dictionary) -> void:
	reset_connection()
	if document != null and p.world_id == document.world_id and p.stream_id == _stream_id \
			and int(p.revision) >= document.document_revision:
		_send("resume_result", {"mode": "continue", "revision": document.document_revision, "authored_hash": _hash},
			_stream_id)
	else:
		_send("resume_result", {"mode": "snapshot", "revision": 0, "authored_hash": ZERO_HASH}, p.stream_id)


func _on_blob_begin(env_stream: String, meta: Dictionary) -> void:
	var kind: String = meta.kind
	if kind != "snapshot":
		if document == null or env_stream != _stream_id:
			_resync("%s for a stream that is not installed" % kind, env_stream)
			_aborted[meta.transfer_id] = true
			return
		if kind == "commit" and int(meta.base_revision) > document.document_revision:
			_resync("revision gap before commit %d" % int(meta.target_revision), env_stream)
			_aborted[meta.transfer_id] = true
			return
	var err := _blobs.begin(meta)
	if err != "":
		stats.rejected += 1
		_aborted[meta.transfer_id] = true
		_send("error", {"code": "blob_rejected", "message": err.left(200)}, env_stream)
		return
	_transfers[meta.transfer_id] = {"kind": kind, "meta": meta, "stream_id": env_stream}


func _on_blob_end(env_stream: String, id: String) -> void:
	if not _transfers.has(id):
		if not _aborted.has(id):
			stats.rejected += 1
		return
	var t: Dictionary = _transfers[id]
	_transfers.erase(id)
	var done := _blobs.finish(id)
	if not done.ok:
		if t.kind != "preview":
			_resync("blob transfer failed: " + str(done.error).left(120), env_stream)
		return
	match t.kind:
		"snapshot":
			_install_snapshot(done.path, env_stream)
		"commit":
			_on_commit(done.path, t.meta)
		_:
			_on_preview(done.path, t.meta)


# --- Snapshot ---------------------------------------------------------------------------------------

func _install_snapshot(path: String, env_stream: String) -> void:
	var res := LiveSnapshot.install(path, _catalog, _tmp_root)
	LiveBlobReceiver.release(path)
	if res[1] != "":
		_resync("snapshot rejected: " + str(res[1]).left(160), env_stream)
		return
	_blobs.abort_all()
	_transfers.clear()
	overlay.clear()
	document = res[0]
	_stream_id = env_stream
	_cache = AuthoredHashCache.new()
	_hash = _cache.hash_of(document)
	_history = {document.document_revision: _hash}
	stats.snapshots += 1
	_ack("snapshot_ack")


# --- Commits ------------------------------------------------------------------------------------------

func _on_commit(path: String, meta: Dictionary) -> void:
	var expect := {"kind": "commit", "world_id": document.world_id, "stream_id": _stream_id,
		"operation_id": meta.operation_id, "base_revision": meta.base_revision, "base_hash": meta.base_authored_hash,
		"target_revision": meta.target_revision, "target_hash": meta.target_authored_hash}
	var parsed := WorldDelta.parse(path, document.layout, expect)
	LiveBlobReceiver.release(path)
	if not parsed.ok:
		_resync("invalid commit delta: " + str(parsed.error).left(160), _stream_id)
		return
	var d: Dictionary = parsed.delta
	var rev := document.document_revision
	if int(d.target_revision) <= rev:
		_replay(d)
	elif int(d.base_revision) != rev:
		_resync("revision gap: have %d, commit continues %d" % [rev, int(d.base_revision)], _stream_id)
	elif d.base_hash != _hash:
		_resync("commit continues an unexpected base hash", _stream_id)
	else:
		_apply(d)


func _apply(d: Dictionary) -> void:
	var res := LiveDeltaApply.apply_commit(document, d, _cache)
	if not res.ok:
		_resync("commit not applied: " + str(res.error).left(160), _stream_id)
		return
	_hash = res.hash
	_history[document.document_revision] = _hash
	_history.erase(document.document_revision - HISTORY)
	overlay.clear()
	stats.commits += 1
	_ack("commit_ack")
	commit_applied.emit(res.touched)


## An already installed commit with the same identity is idempotent (acknowledged again); any other content at a
## known revision is a conflicting duplicate.
func _replay(d: Dictionary) -> void:
	if _history.get(int(d.target_revision), "") != d.target_hash:
		_resync("commit %d conflicts with the installed history" % int(d.target_revision), _stream_id)
		return
	stats.replays += 1
	_send("commit_ack", {"world_id": document.world_id, "stream_id": _stream_id, "revision": int(d.target_revision),
		"authored_hash": d.target_hash, "visual_ready": _visual_ready()}, _stream_id)


# --- Previews -----------------------------------------------------------------------------------------

func _on_preview(path: String, meta: Dictionary) -> void:
	if int(meta.base_revision) != document.document_revision:
		LiveBlobReceiver.release(path)
		stats.stale_previews += 1
		return
	var expect := {"kind": "preview", "world_id": document.world_id, "stream_id": _stream_id,
		"operation_id": meta.operation_id, "base_revision": meta.base_revision, "preview_seq": meta.preview_seq}
	var parsed := WorldDelta.parse(path, document.layout, expect)
	LiveBlobReceiver.release(path)
	if not parsed.ok:
		stats.rejected += 1
		return
	overlay.apply(parsed.delta, _now_msec)
	stats.previews += 1


# --- Replies ------------------------------------------------------------------------------------------

func _visual_ready() -> bool:
	if visual_probe.is_valid():
		return bool(visual_probe.call())
	return document != null and (document.assets.availability(document).unavailable as Dictionary).is_empty()


func _ack(type: String) -> void:
	_send(type, {"world_id": document.world_id, "stream_id": _stream_id, "revision": document.document_revision,
		"authored_hash": _hash, "visual_ready": _visual_ready()}, _stream_id)


func _resync(reason: String, stream: String) -> void:
	stats.resyncs += 1
	stats.last_resync = reason
	var payload := {"reason": reason}
	if document != null:
		payload["revision"] = document.document_revision
		payload["authored_hash"] = _hash
	_send("resync_required", payload, stream)


func _send(type: String, payload: Dictionary, stream: String) -> void:
	var s := stream if LiveIds.is_id(stream) else LiveIds.ZERO_ID
	var built := LiveEnvelope.build(type, session_id, s, payload)
	if built.ok:
		_out.append(built.text)
