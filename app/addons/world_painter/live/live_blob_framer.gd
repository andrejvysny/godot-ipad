class_name LiveBlobFramer
extends RefCounted
## Splits one blob (memory or file) into `WPB1` binary frames (INT-SPEC-1.1 §10.3):
## "WPB1" + 16 raw bytes transfer id + u32 LE chunk index + payload (at most 262144 bytes).
## A file-backed blob is read one chunk at a time, so a 264 MiB snapshot never sits in memory.

const MAGIC := "WPB1"
const ID_BYTES := 16
const HEADER_BYTES := 24
const MAX_PAYLOAD := 262144

var transfer_id := ""
var total_bytes := 0
var chunk_size := MAX_PAYLOAD
var chunk_count := 0
var sha256 := ""

var _bytes := PackedByteArray()
var _path := ""


static func from_bytes(p_transfer_id: String, bytes: PackedByteArray, p_chunk_size: int = MAX_PAYLOAD) -> LiveBlobFramer:
	var f := LiveBlobFramer.new()
	f._setup(p_transfer_id, bytes.size(), p_chunk_size)
	f._bytes = bytes
	f.sha256 = CanonicalEncoder.sha256_hex(bytes)
	return f


## Null when the file cannot be read. Hashes the file in chunks.
static func from_file(p_transfer_id: String, path: String, p_chunk_size: int = MAX_PAYLOAD) -> LiveBlobFramer:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var f := LiveBlobFramer.new()
	f._setup(p_transfer_id, file.get_length(), p_chunk_size)
	f._path = path
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var part := file.get_buffer(p_chunk_size)
		if part.is_empty():
			break
		ctx.update(part)
	f.sha256 = ctx.finish().hex_encode()
	return f


## For a file whose size and SHA-256 a worker already computed (hash_file): nothing is read here.
static func from_file_known(p_transfer_id: String, path: String, size: int, p_sha256: String,
		p_chunk_size: int = MAX_PAYLOAD) -> LiveBlobFramer:
	var f := LiveBlobFramer.new()
	f._setup(p_transfer_id, size, p_chunk_size)
	f._path = path
	f.sha256 = p_sha256
	return f


## SHA-256 hex of a file read in chunks ("" when it cannot be opened). Safe on any thread.
static func hash_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var part := file.get_buffer(MAX_PAYLOAD)
		if part.is_empty():
			break
		ctx.update(part)
	return ctx.finish().hex_encode()


func _setup(p_transfer_id: String, size: int, p_chunk_size: int) -> void:
	transfer_id = p_transfer_id
	total_bytes = size
	chunk_size = clampi(p_chunk_size, 1, MAX_PAYLOAD)
	chunk_count = LiveEnvelope.chunks_for(size, chunk_size)


## The frame for chunk `index` (empty when out of range or the file vanished).
func frame(index: int) -> PackedByteArray:
	if index < 0 or index >= chunk_count:
		return PackedByteArray()
	var payload := _read_chunk(index)
	var expected := mini(chunk_size, total_bytes - index * chunk_size)
	if payload.size() != expected:
		return PackedByteArray()
	return build_frame(transfer_id, index, payload)


func _read_chunk(index: int) -> PackedByteArray:
	if _path == "":
		return _bytes.slice(index * chunk_size, mini(total_bytes, (index + 1) * chunk_size))
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	file.seek(index * chunk_size)
	return file.get_buffer(chunk_size)


## blob_begin payload fields every transfer shares; callers add kind-specific keys.
func begin_payload(kind: String, format: String) -> Dictionary:
	return {"transfer_id": transfer_id, "kind": kind, "format": format, "total_bytes": total_bytes,
		"chunk_size": chunk_size, "chunk_count": chunk_count, "sha256": sha256}


static func build_frame(p_transfer_id: String, index: int, payload: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(HEADER_BYTES)
	out.encode_u32(0, 0x31425057)  # "WPB1" little-endian
	var id := p_transfer_id.hex_decode()
	for i in ID_BYTES:
		out[4 + i] = id[i]
	out.encode_u32(20, index)
	out.append_array(payload)
	return out


## {ok, error, transfer_id (hex), index, payload}.
static func parse_frame(data: PackedByteArray) -> Dictionary:
	if data.size() < HEADER_BYTES:
		return {"ok": false, "error": "binary frame is shorter than its header"}
	if data.size() - HEADER_BYTES > MAX_PAYLOAD:
		return {"ok": false, "error": "binary frame payload exceeds %d bytes" % MAX_PAYLOAD}
	if data.slice(0, 4).get_string_from_ascii() != MAGIC:
		return {"ok": false, "error": "binary frame has a bad magic"}
	return {"ok": true, "error": "", "transfer_id": data.slice(4, 20).hex_encode(),
		"index": data.decode_u32(20), "payload": data.slice(HEADER_BYTES)}
