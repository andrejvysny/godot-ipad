class_name LiveBlobReceiver
extends RefCounted
## Disk-backed staging of blob transfers (INT-SPEC-1.1 §10.3, ADR 0015 L1). Sizes are checked before anything is
## allocated; chunks stream into `<root>/<transfer>.part` with an incremental SHA-256, so resident memory is
## about one chunk plus hash state. Chunks must arrive in order; an identical repeat of an already stored chunk is
## ignored, a differing repeat, an out-of-range or an out-of-order index aborts the transfer.
## `root` must be a private directory the caller owns (the receiver's session root).

const MAX_IN_FLIGHT := 2
const SNAPSHOT_CAP := 264 * 1024 * 1024
const DELTA_CAP := 64 * 1024 * 1024

var root: String
## Total bytes declared by transfers that are still open (staging bound: <= MAX_IN_FLIGHT * SNAPSHOT_CAP).
var declared_bytes := 0

var _transfers: Dictionary = {}  # transfer_id -> state Dictionary


func _init(p_root: String) -> void:
	root = p_root


func in_flight() -> int:
	return _transfers.size()


func has_transfer(transfer_id: String) -> bool:
	return _transfers.has(transfer_id)


## `meta` is a checked blob_begin payload. Returns "" or an error; nothing is created on error.
func begin(meta: Dictionary) -> String:
	var id: String = meta.get("transfer_id", "")
	if not LiveIds.is_id(id):
		return "invalid transfer id"
	if _transfers.has(id):
		return "transfer %s is already open" % id
	if _transfers.size() >= MAX_IN_FLIGHT:
		return "more than %d blobs in flight" % MAX_IN_FLIGHT
	var err := _check_meta(meta)
	if err != "":
		return err
	err = StorageFs.make_dir(root)
	if err != "":
		return err
	var path := root.path_join(id + ".part")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "cannot stage transfer (error %d)" % FileAccess.get_open_error()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	_transfers[id] = {"meta": meta.duplicate(), "file": file, "path": path, "next": 0, "written": 0, "ctx": ctx,
		"digests": []}
	declared_bytes += int(meta.total_bytes)
	return ""


static func _check_meta(meta: Dictionary) -> String:
	for k in ["kind", "total_bytes", "chunk_size", "chunk_count", "sha256"]:
		if not meta.has(k):
			return "blob_begin lacks '%s'" % k
	var total := int(meta.total_bytes)
	var size := int(meta.chunk_size)
	var cap := SNAPSHOT_CAP if meta.kind == "snapshot" else DELTA_CAP
	if total < 1 or total > cap:
		return "%s blob of %d bytes exceeds its cap of %d" % [meta.kind, total, cap]
	if size < 1 or size > LiveBlobFramer.MAX_PAYLOAD:
		return "chunk_size %d is outside 1..%d" % [size, LiveBlobFramer.MAX_PAYLOAD]
	if int(meta.chunk_count) != LiveEnvelope.chunks_for(total, size):
		return "chunk_count %d does not equal ceil(%d / %d)" % [int(meta.chunk_count), total, size]
	if not LiveIds.is_hash(meta.sha256):
		return "sha256 is not 64 lowercase hex characters"
	return ""


## {ok, error, transfer_id, duplicate}. Any error also aborts (and deletes) that transfer.
func add_frame(data: PackedByteArray) -> Dictionary:
	var f := LiveBlobFramer.parse_frame(data)
	if not f.ok:
		return {"ok": false, "error": f.error, "transfer_id": "", "duplicate": false}
	var id: String = f.transfer_id
	if not _transfers.has(id):
		return {"ok": false, "error": "chunk for unknown transfer %s" % id, "transfer_id": id, "duplicate": false}
	var t: Dictionary = _transfers[id]
	var err := _store(t, int(f.index), f.payload)
	if err.begins_with("dup:"):
		return {"ok": true, "error": "", "transfer_id": id, "duplicate": true}
	if err != "":
		abort(id)
		return {"ok": false, "error": err, "transfer_id": id, "duplicate": false}
	return {"ok": true, "error": "", "transfer_id": id, "duplicate": false}


func _store(t: Dictionary, index: int, payload: PackedByteArray) -> String:
	var meta: Dictionary = t.meta
	if index >= int(meta.chunk_count):
		return "chunk index %d is outside 0..%d" % [index, int(meta.chunk_count) - 1]
	var digest := CanonicalEncoder.sha256(payload)
	if index < int(t.next):
		return "dup:" if (t.digests as Array)[index] == digest else "chunk %d repeated with different content" % index
	if index > int(t.next):
		return "chunk %d arrived before chunk %d" % [index, int(t.next)]
	var size := int(meta.chunk_size)
	var expected := mini(size, int(meta.total_bytes) - index * size)
	if payload.size() != expected:
		return "chunk %d has %d bytes, expected %d" % [index, payload.size(), expected]
	var file: FileAccess = t.file
	if not file.store_buffer(payload):
		return "staging write failed (error %d)" % file.get_error()
	(t.ctx as HashingContext).update(payload)
	(t.digests as Array).append(digest)
	t.next = index + 1
	t.written = int(t.written) + payload.size()
	return ""


## {ok, error, path, meta}: every chunk present, byte count and whole-blob hash verified. The staged file is
## renamed to `<id>.blob`; the caller owns it and removes it with release(). Any failure aborts the transfer.
func finish(transfer_id: String) -> Dictionary:
	if not _transfers.has(transfer_id):
		return {"ok": false, "error": "blob_end for unknown transfer", "path": "", "meta": {}}
	var t: Dictionary = _transfers[transfer_id]
	var meta: Dictionary = t.meta
	var err := ""
	if int(t.next) != int(meta.chunk_count) or int(t.written) != int(meta.total_bytes):
		err = "transfer ended with %d of %d chunks" % [int(t.next), int(meta.chunk_count)]
	elif (t.ctx as HashingContext).finish().hex_encode() != meta.sha256:
		err = "blob sha256 does not match blob_begin"
	if err != "":
		abort(transfer_id)
		return {"ok": false, "error": err, "path": "", "meta": {}}
	(t.file as FileAccess).flush()
	(t.file as FileAccess).close()
	var final := root.path_join(transfer_id + ".blob")
	if DirAccess.rename_absolute(t.path, final) != OK:
		abort(transfer_id)
		return {"ok": false, "error": "cannot finalize staged blob", "path": "", "meta": {}}
	declared_bytes -= int(meta.total_bytes)
	_transfers.erase(transfer_id)
	return {"ok": true, "error": "", "path": final, "meta": meta}


func abort(transfer_id: String) -> void:
	if not _transfers.has(transfer_id):
		return
	var t: Dictionary = _transfers[transfer_id]
	(t.file as FileAccess).close()
	DirAccess.remove_absolute(t.path)
	declared_bytes -= int((t.meta as Dictionary).total_bytes)
	_transfers.erase(transfer_id)


func abort_all() -> void:
	for id: String in _transfers.keys():
		abort(id)


## Deletes a finished blob the caller has consumed.
static func release(path: String) -> void:
	if path != "" and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
