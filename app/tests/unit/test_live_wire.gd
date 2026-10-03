extends TestCase
## Live protocol wire layer: envelope strictness, binary framing and the disk-backed blob receiver (hostile cases).

const SESSION := "0123456789abcdef0123456789abcdef"
const STREAM := "fedcba9876543210fedcba9876543210"
const HASH := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"


func _build(type: String, payload: Dictionary) -> String:
	var b := LiveEnvelope.build(type, SESSION, STREAM, payload)
	assert_true(b.ok, "build %s: %s" % [type, b.error])
	return b.text


func _tamper(text: String, mutate: Callable) -> String:
	var d: Dictionary = JSON.parse_string(text)
	mutate.call(d)
	return JSON.stringify(d)


func test_envelope_round_trip_normalizes_integers() -> void:
	var text := _build("resume", {"world_id": "w", "stream_id": STREAM, "revision": 7, "authored_hash": HASH})
	var parsed := LiveEnvelope.parse(text, true, SESSION)
	assert_true(parsed.ok, parsed.error)
	assert_eq(parsed.envelope.type, "resume")
	assert_eq(typeof(parsed.envelope.payload.revision), TYPE_INT)
	assert_eq(parsed.envelope.payload.revision, 7)


func test_envelope_rejects_unknown_type_keys_and_wrong_session() -> void:
	var text := _build("ping", {"nonce": 1})
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.type = "run_script"), true).ok, "unknown type")
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.extra = 1), true).ok, "unknown envelope key")
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.payload.cmd = "x"), true).ok, "unknown payload key")
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.payload.erase("nonce")), true).ok, "missing payload key")
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.payload.nonce = -1), true).ok, "negative int")
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.payload.nonce = 1.5), true).ok, "fractional int")
	assert_false(LiveEnvelope.parse(_tamper(text, func(d: Dictionary) -> void: d.protocol_version = 2), true).ok, "version")
	assert_false(LiveEnvelope.parse(text, true, "ffffffffffffffffffffffffffffffff").ok, "wrong session")
	assert_false(LiveEnvelope.parse("[1,2]", true).ok, "not an object")
	assert_false(LiveEnvelope.parse("{", true).ok, "invalid json")


func test_pre_auth_accepts_only_a_small_hello() -> void:
	var hello := {"role": "sender", "protocol_versions": [1], "auth": {"pairing_token": HASH}, "app": "wp",
		"capabilities": ["delta"]}
	var text := _build("hello", hello)
	assert_true(LiveEnvelope.parse(text, false).ok, "hello before auth")
	assert_false(LiveEnvelope.parse(_build("ping", {"nonce": 1}), false).ok, "only hello before auth")
	var padded := _tamper(text, func(d: Dictionary) -> void: d.payload.app = "a".repeat(900))
	assert_true(padded.length() < LiveEnvelope.MAX_PRE_AUTH_BYTES)
	var big := text + " ".repeat(LiveEnvelope.MAX_PRE_AUTH_BYTES)
	assert_false(LiveEnvelope.parse(big, false).ok, "over 8 KiB before auth")
	assert_true(LiveEnvelope.parse(big, true).ok, "the same size is fine after auth (cap 64 KiB)")
	assert_false(LiveEnvelope.parse(text + " ".repeat(LiveEnvelope.MAX_TEXT_BYTES), true).ok, "over 64 KiB")
	var two := _tamper(text, func(d: Dictionary) -> void: d.payload.auth = {"pairing_token": HASH, "session_credential": HASH})
	assert_false(LiveEnvelope.parse(two, false).ok, "exactly one credential")


func test_blob_begin_checks_chunk_count_and_kind_keys() -> void:
	var base := {"transfer_id": SESSION, "kind": "snapshot", "format": "worldpoc-v4", "total_bytes": 600000,
		"chunk_size": 262144, "chunk_count": 3, "sha256": HASH}
	assert_true(LiveEnvelope.check_payload("blob_begin", base).ok, "valid snapshot begin")
	var wrong_count := base.duplicate()
	wrong_count.chunk_count = 2
	assert_false(LiveEnvelope.check_payload("blob_begin", wrong_count).ok, "wrong chunk count")
	var too_big := base.duplicate()
	too_big.total_bytes = LiveEnvelope.MAX_SNAPSHOT_BYTES + 1
	too_big.chunk_count = LiveEnvelope.chunks_for(too_big.total_bytes, 262144)
	assert_false(LiveEnvelope.check_payload("blob_begin", too_big).ok, "over the snapshot cap")
	var big_chunk := base.duplicate()
	big_chunk.chunk_size = 262145
	big_chunk.chunk_count = 3
	assert_false(LiveEnvelope.check_payload("blob_begin", big_chunk).ok, "chunk over 256 KiB")
	var commit := base.duplicate()
	commit.kind = "commit"
	commit.format = "world-delta-v1"
	assert_false(LiveEnvelope.check_payload("blob_begin", commit).ok, "commit needs identity keys")
	var mismatched := base.duplicate()
	mismatched.format = "world-delta-v1"
	assert_false(LiveEnvelope.check_payload("blob_begin", mismatched).ok, "format must match kind")


func test_framer_round_trip_and_parse_errors() -> void:
	var blob := PackedByteArray()
	blob.resize(600000)
	for i in blob.size():
		blob[i] = i % 251
	var f := LiveBlobFramer.from_bytes(SESSION, blob)
	assert_eq(f.chunk_count, 3)
	var out := PackedByteArray()
	for i in f.chunk_count:
		var parsed := LiveBlobFramer.parse_frame(f.frame(i))
		assert_true(parsed.ok, parsed.error)
		assert_eq(parsed.transfer_id, SESSION)
		assert_eq(parsed.index, i)
		out.append_array(parsed.payload)
	assert_eq(out, blob)
	assert_true(f.frame(3).is_empty(), "no frame past the end")
	assert_false(LiveBlobFramer.parse_frame(PackedByteArray([1, 2, 3])).ok, "short frame")
	var bad_magic := f.frame(0)
	bad_magic[0] = 0x58
	assert_false(LiveBlobFramer.parse_frame(bad_magic).ok, "bad magic")
	var fat := f.frame(0)
	fat.append_array(PackedByteArray([0]))
	fat.resize(LiveBlobFramer.HEADER_BYTES + LiveBlobFramer.MAX_PAYLOAD + 1)
	assert_false(LiveBlobFramer.parse_frame(fat).ok, "payload over 256 KiB")


func _receiver() -> LiveBlobReceiver:
	return LiveBlobReceiver.new(scratch_dir() + "/blobs")


func _meta(framer: LiveBlobFramer, kind := "commit") -> Dictionary:
	return framer.begin_payload(kind, "worldpoc-v4" if kind == "snapshot" else "world-delta-v1")


func _blob(n: int, seed_value := 0) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = (i * 7 + seed_value) % 256
	return b


func test_receiver_stages_to_disk_and_verifies_hash() -> void:
	var blob := _blob(600000)
	var f := LiveBlobFramer.from_bytes(SESSION, blob)
	var r := _receiver()
	assert_empty_string(r.begin(_meta(f)))
	for i in f.chunk_count:
		assert_true(r.add_frame(f.frame(i)).ok)
	var done := r.finish(SESSION)
	assert_true(done.ok, done.error)
	var staged := FileAccess.get_file_as_bytes(done.path)
	assert_eq(staged, blob, "staged file holds the exact blob")
	assert_eq(r.in_flight(), 0)
	assert_eq(r.declared_bytes, 0)
	LiveBlobReceiver.release(done.path)
	assert_false(FileAccess.file_exists(done.path))


func test_receiver_ignores_identical_duplicate_and_aborts_on_conflict() -> void:
	var f := LiveBlobFramer.from_bytes(SESSION, _blob(600000))
	var r := _receiver()
	r.begin(_meta(f))
	assert_true(r.add_frame(f.frame(0)).ok)
	var dup := r.add_frame(f.frame(0))
	assert_true(dup.ok and dup.duplicate, "identical duplicate ignored")
	var evil := LiveBlobFramer.from_bytes(SESSION, _blob(600000, 3))
	var conflict := r.add_frame(evil.frame(0))
	assert_false(conflict.ok, "conflicting duplicate aborts")
	assert_false(r.has_transfer(SESSION), "transfer removed")
	assert_false(FileAccess.file_exists(scratch_dir() + "/blobs/" + SESSION + ".part"), "staging file deleted")


func test_receiver_aborts_on_range_order_size_and_hash_errors() -> void:
	var f := LiveBlobFramer.from_bytes(SESSION, _blob(600000))
	var r := _receiver()
	r.begin(_meta(f))
	var past := LiveBlobFramer.build_frame(SESSION, 3, PackedByteArray([1]))
	assert_false(r.add_frame(past).ok, "index == chunk_count is out of range")
	r.begin(_meta(f))
	assert_false(r.add_frame(f.frame(1)).ok, "chunk 1 before chunk 0")
	r.begin(_meta(f))
	r.add_frame(f.frame(0))
	r.add_frame(f.frame(1))
	var short := LiveBlobFramer.build_frame(SESSION, 2, PackedByteArray([1, 2]))
	assert_false(r.add_frame(short).ok, "last chunk with the wrong length")
	r.begin(_meta(f))
	for i in 2:
		r.add_frame(f.frame(i))
	assert_false(r.finish(SESSION).ok, "ended with a missing chunk")
	var other := LiveBlobFramer.from_bytes(SESSION, _blob(600000, 9))
	var meta := _meta(f)
	r.begin(meta)
	for i in other.chunk_count:
		r.add_frame(other.frame(i))
	var done := r.finish(SESSION)
	assert_false(done.ok, "whole-blob hash mismatch")
	assert_error_contains(done.error, "sha256")
	assert_eq(r.in_flight(), 0)


func test_receiver_enforces_caps_in_flight_and_unknown_transfers() -> void:
	var r := _receiver()
	var f := LiveBlobFramer.from_bytes(SESSION, _blob(1000))
	var meta := _meta(f)
	meta.total_bytes = LiveBlobReceiver.DELTA_CAP + 1
	meta.chunk_count = LiveEnvelope.chunks_for(meta.total_bytes, meta.chunk_size)
	assert_error_contains(r.begin(meta), "cap")
	var snap := _meta(f, "snapshot")
	snap.total_bytes = LiveBlobReceiver.SNAPSHOT_CAP + 1
	snap.chunk_count = LiveEnvelope.chunks_for(snap.total_bytes, snap.chunk_size)
	assert_error_contains(r.begin(snap), "cap")
	var bad_count := _meta(f)
	bad_count.chunk_count = 5
	assert_error_contains(r.begin(bad_count), "chunk_count")
	assert_eq(r.in_flight(), 0, "nothing allocated for rejected metadata")
	var ids := ["a".repeat(32), "b".repeat(32), "c".repeat(32)]
	var results: Array[String] = []
	for id: String in ids:
		var m := _meta(f)
		m.transfer_id = id
		results.append(r.begin(m))
	assert_eq(results[0], "")
	assert_eq(results[1], "")
	assert_error_contains(results[2], "in flight")
	assert_error_contains(r.begin(_meta(LiveBlobFramer.from_bytes(ids[0], _blob(10)))), "already open")
	var stray := LiveBlobFramer.build_frame("d".repeat(32), 0, PackedByteArray([1]))
	assert_false(r.add_frame(stray).ok, "unknown transfer")
	r.abort_all()
	assert_eq(r.declared_bytes, 0)
