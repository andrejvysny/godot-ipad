extends TestCase
## Faults between sender and replica: gaps, reordering, duplicates, hostile commits, overflow, backpressure,
## reconnect. The replica must always hold a state the sender really had; it never applies a partial commit.


func _h() -> LiveHarness:
	var h := LiveHarness.new()
	h.setup(scratch_dir())
	h.connect_and_sync()
	h.link.recording = true
	return h


## Steps the link like settle() but checks after every round that the replica holds a real sender state.
func _settle_checked(h: LiveHarness, valid: Array) -> void:
	for round in 200:
		h.link.now_msec += 100
		h.sender.tick(h.link.now_msec)
		h.sender.flush_snapshot()
		var moved := h.sender.pump(h.link) + h.link.deliver()
		if h.replica.document != null:
			var actual := CanonicalEncoder.authored_hash(h.replica.document)
			assert_eq(actual, h.replica.authored_hash(), "replica hash is consistent with its content")
			assert_true(valid.has(actual), "replica holds a state the sender had (round %d)" % round)
		if moved == 0 and not h.sender.snapshot_pending() and h.link.wire.is_empty():
			return


func _state_hashes(h: LiveHarness) -> Array:
	return [CanonicalEncoder.authored_hash(h.doc)]


func test_gap_triggers_resync_and_a_new_stream_never_a_partial_apply() -> void:
	var h := _h()
	var valid := _state_hashes(h)
	var stream := h.sender.stream_id()
	h.link.drop_all = true
	h.sculpt(Vector2i(0, 0), 100, 1.0)  # lost on the way
	h.sender.pump(h.link)
	valid.append(CanonicalEncoder.authored_hash(h.doc))
	h.link.drop_all = false
	h.sculpt(Vector2i(0, 0), 200, 1.0)
	valid.append(CanonicalEncoder.authored_hash(h.doc))
	_settle_checked(h, valid)
	assert_true(h.replica.stats.resyncs >= 1, "gap requested a resync")
	assert_ne(h.sender.stream_id(), stream, "full resynchronization starts a new stream")
	assert_eq(h.replica.authored_hash(), CanonicalEncoder.authored_hash(h.doc), "converged through a fresh snapshot")
	assert_eq(h.replica.revision(), h.doc.document_revision)


func test_reordered_messages_end_in_resync_and_never_a_partial_state() -> void:
	var h := _h()
	var valid := _state_hashes(h)
	h.link.faults[h.link.sent_count] = "swap"  # blob_begin arrives after the chunk
	h.sculpt(Vector2i(-1, -1), 50, 2.0)
	valid.append(CanonicalEncoder.authored_hash(h.doc))
	_settle_checked(h, valid)
	assert_true(h.replica.stats.resyncs >= 1 or h.replica.stats.rejected >= 1, "the reorder was noticed")
	h.link.settle()
	assert_eq(h.replica.authored_hash(), CanonicalEncoder.authored_hash(h.doc), "converged after the resync")


func test_duplicate_chunk_is_ignored_and_the_commit_still_applies() -> void:
	var h := _h()
	h.link.faults[h.link.sent_count + 1] = "dup"  # the first binary frame twice
	h.sculpt(Vector2i(0, 0), 10, 1.0)
	h.verify(self, "duplicate frame")
	assert_eq(h.replica.stats.commits, 1)


func test_replay_of_an_installed_commit_is_idempotent() -> void:
	var h := _h()
	var from := h.link.recorded.size()
	h.sculpt(Vector2i(0, 0), 10, 1.0)
	h.verify(self, "first delivery")
	var hash := h.replica.authored_hash()
	var to := h.link.recorded.size()
	h.link.redeliver(from, to)
	assert_eq(h.replica.stats.replays, 1, "recognized as a replay")
	assert_eq(h.replica.stats.resyncs, 0)
	assert_eq(h.replica.authored_hash(), hash)
	assert_eq(h.replica.revision(), h.doc.document_revision)
	h.verify(self, "after replay")


## Delivers a delta built with arbitrary identities as a whole blob; returns the replica's reply types.
func _send_delta(h: LiveHarness, ident: Dictionary, stream: String, kind := "commit") -> Array:
	var change: WorldChange = ident.change
	var path := scratch_dir() + "/crafted.delta"
	var res := WorldDeltaBuilder.build_commit(change, true, ident, {}, path)
	assert_true(res.ok, res.error)
	var framer := LiveBlobFramer.from_file(LiveIds.new_id(), path)
	var payload := framer.begin_payload(kind, "world-delta-v1")
	payload.merge({"operation_id": ident.operation_id, "base_revision": ident.base_revision,
		"base_authored_hash": ident.base_hash, "target_revision": ident.target_revision,
		"target_authored_hash": ident.target_hash})
	h.replica.on_text(LiveEnvelope.build("blob_begin", LiveHarness.SESSION, stream, payload).text)
	for i in framer.chunk_count:
		h.replica.on_binary(framer.frame(i))
	h.replica.on_text(LiveEnvelope.build("blob_end", LiveHarness.SESSION, stream, {"transfer_id": framer.transfer_id}).text)
	var types: Array = []
	for text in h.replica.take_outgoing():
		types.append(LiveEnvelope.parse(text, true).envelope.type)
	return types


func _craft_change(h: LiveHarness) -> WorldChange:
	var tx := EditTransaction.new()
	tx.begin(h.doc, "t", "t")
	tx.capture_heights(Vector2i(0, 0))
	h.doc.get_region(Vector2i(0, 0)).heights[77] = 3.0
	var change := tx.finish()
	tx.rollback()  # leave the sender's document as it was
	h.doc.get_region(Vector2i(0, 0)).heights[77] = 0.0
	return change


func _ident(h: LiveHarness, change: WorldChange, patch := {}) -> Dictionary:
	var ident := {"change": change, "world_id": h.doc.world_id, "stream_id": h.replica.stream_id(),
		"operation_id": change.operation_id, "base_revision": h.replica.revision(), "base_hash": h.replica.authored_hash(),
		"target_revision": h.replica.revision() + 1, "target_hash": "ab".repeat(32)}
	ident.merge(patch, true)
	return ident


func test_hostile_commits_are_refused_and_leave_the_replica_untouched() -> void:
	var h := _h()
	h.sculpt(Vector2i(0, 0), 5, 1.0)  # a real revision 1 to conflict with later
	h.verify(self, "setup")
	var change := _craft_change(h)
	var before := h.replica.authored_hash()
	var revision := h.replica.revision()
	# Right chain, wrong target hash: applying reproduces another hash, so everything is rolled back.
	var types := _send_delta(h, _ident(h, change), h.replica.stream_id())
	assert_true(types.has("resync_required"), "target hash mismatch -> %s" % str(types))
	assert_eq(h.replica.authored_hash(), before)
	assert_eq(CanonicalEncoder.authored_hash(h.replica.document), before, "rolled back completely")
	assert_eq(h.replica.revision(), revision, "revision untouched")
	# Unexpected base hash.
	types = _send_delta(h, _ident(h, change, {"base_hash": "cd".repeat(32)}), h.replica.stream_id())
	assert_true(types.has("resync_required"), "unexpected base hash")
	# A gap.
	types = _send_delta(h, _ident(h, change, {"base_revision": 5, "target_revision": 6}), h.replica.stream_id())
	assert_true(types.has("resync_required"), "gap")
	# Wrong stream.
	types = _send_delta(h, _ident(h, change), LiveIds.new_id())
	assert_true(types.has("resync_required"), "wrong stream")
	# Conflicting duplicate: a different hash for a revision that is already installed.
	types = _send_delta(h, _ident(h, change, {"base_revision": revision - 1, "target_revision": revision}), h.replica.stream_id())
	assert_true(types.has("resync_required"), "conflicting duplicate")
	assert_eq(CanonicalEncoder.authored_hash(h.replica.document), before, "nothing was ever applied")
	assert_eq(h.replica.revision(), revision)


func test_commit_before_any_snapshot_is_refused() -> void:
	var h := LiveHarness.new()
	h.setup(scratch_dir())
	var change := _craft_change(h)
	var ident := {"change": change, "world_id": h.doc.world_id, "stream_id": LiveIds.new_id(), "operation_id": "op",
		"base_revision": 0, "base_hash": "ab".repeat(32), "target_revision": 1, "target_hash": "cd".repeat(32)}
	var types := _send_delta(h, ident, ident.stream_id)
	assert_true(types.has("resync_required"))
	assert_true(h.replica.document == null)


func test_hostile_delta_archives_fail_validation() -> void:
	var h := _h()
	var change := _craft_change(h)
	var path := scratch_dir() + "/ok.delta"
	var ident := _ident(h, change)
	assert_true(WorldDeltaBuilder.build_commit(change, true, ident, {}, path).ok)
	var layout := h.doc.layout
	var expect := {"kind": "commit", "stream_id": ident.stream_id, "base_revision": ident.base_revision}
	assert_true(WorldDelta.parse(path, layout, expect).ok, "the well-formed archive parses")
	assert_false(WorldDelta.parse(path, layout, {"stream_id": LiveIds.new_id()}).ok, "identity must agree with the blob")
	assert_false(WorldDelta.parse(path, layout, {"base_revision": 9}).ok)
	assert_false(WorldDelta.parse(path, layout, {"kind": "preview"}).ok)
	var bytes := FileAccess.get_file_as_bytes(path)
	var bad := scratch_dir() + "/bad.delta"
	var cut := bytes.slice(0, bytes.size() - 30)
	var f := FileAccess.open(bad, FileAccess.WRITE)
	f.store_buffer(cut)
	f.close()
	assert_false(WorldDelta.parse(bad, layout, {}).ok, "truncated archive")
	var tail := bytes.duplicate()
	tail.append_array(PackedByteArray([1, 2, 3]))
	f = FileAccess.open(bad, FileAccess.WRITE)
	f.store_buffer(tail)
	f.close()
	assert_false(WorldDelta.parse(bad, layout, {}).ok, "data after the end record")
	# A region outside the layout and an extra undeclared member.
	for patch in [{"region": [9, 0]}, {"extra_member": true}, {"drop_tile": true}, {"bad_hash": true}]:
		var forged := _forge(path, patch)
		assert_false(WorldDelta.parse(forged, layout, {}).ok, "forged archive %s" % str(patch))


## Rewrites the archive with one defect injected into delta.json or its members.
func _forge(src: String, patch: Dictionary) -> String:
	var zr := ZIPReader.new()
	zr.open(src)
	var doc: Dictionary = JSON.parse_string(zr.read_file("delta.json").get_string_from_utf8())
	var members := {}
	for name in zr.get_files():
		if name != "delta.json" and not name.ends_with("/"):
			members[name] = zr.read_file(name)
	zr.close()
	if patch.has("region"):
		doc.tiles[0].region = patch.region
	if patch.has("extra_member"):
		members["tiles/extra"] = PackedByteArray([1])
	if patch.has("drop_tile"):
		members.erase(doc.tiles[0].path)
	if patch.has("bad_hash"):
		doc.tiles[0].sha256 = "00".repeat(32)
	var out := scratch_dir() + "/forged_%d.delta" % randi()
	var zp := ZIPPacker.new()
	zp.open(out)
	zp.start_file("delta.json")
	zp.write_file(JSON.stringify(doc, "", true, true).to_utf8_buffer())
	zp.close_file()
	for name: String in members:
		zp.start_file(name)
		zp.write_file(members[name])
		zp.close_file()
	zp.close()
	return out


func test_spool_overflow_schedules_a_new_snapshot_on_a_new_stream() -> void:
	var h := _h()
	h.sender.spool.max_ops = 3
	var stream := h.sender.stream_id()
	var snapshots := int(h.sender.stats.snapshots)
	h.link.stalled = true  # nothing is acknowledged
	for i in 5:
		h.sculpt(Vector2i(0, 0), 10 + i, 1.0)
	assert_eq(h.sender.stats.spool_overflows, 1, "overflow detected")
	assert_ne(h.sender.stream_id(), stream, "new stream")
	assert_true(h.sender.spool.count() <= 3, "spool stays bounded")
	h.link.stalled = false
	h.verify(self, "converged through a fresh snapshot")
	assert_eq(h.sender.stats.snapshots, snapshots + 1, "exactly one new snapshot")
	assert_eq(h.replica.stream_id(), h.sender.stream_id())


func test_sender_stays_bounded_under_backpressure() -> void:
	var h := _h()
	h.sender.outbox.high_water = 64 * 1024
	h.link.stalled = true
	for i in 300:
		h.sculpt(Vector2i(-(i % 2), 0), 5 + i, 0.25)
		h.sender.tick(h.link.now_msec + i)
		h.sender.pump(h.link)
		assert_true(h.sender.outbox.queue.size() <= h.sender.spool.max_ops + 8, "queue bounded (%d)" % h.sender.outbox.queue.size())
		assert_true(h.sender.spool.count() <= h.sender.spool.max_ops, "spool bounded")
	assert_true(h.link.max_backlog <= h.sender.outbox.high_water + 2 * LiveBlobFramer.MAX_PAYLOAD, "transport backlog bounded: %d" % h.link.max_backlog)
	assert_true(h.sender.spool.resident_bytes() <= h.sender.spool.memory_bytes, "resident spool bounded")
	assert_true(h.sender.stats.spool_overflows >= 1, "overflowed instead of growing")
	h.link.stalled = false
	h.verify(self, "recovers once the transport drains")


func test_reconnect_resumes_with_the_exact_missing_chain() -> void:
	var h := _h()
	h.sculpt(Vector2i(0, 0), 5, 1.0)
	h.verify(self, "before disconnect")
	var snapshots := int(h.sender.stats.snapshots)
	h.sender.end_session()
	h.link.open = false
	h.sculpt(Vector2i(0, 0), 6, 1.0)
	h.place(LiveHarness.SPRUCE, 4.0, 4.0)
	h.rules(41)
	h.link.open = true
	h.replica.reset_connection()
	h.sender.start_session(LiveHarness.SESSION)
	h.verify(self, "after resume")
	assert_eq(h.sender.stats.snapshots, snapshots, "no new snapshot: the chain was replayed")
	assert_eq(h.replica.stats.commits, 4)


func test_reconnect_with_an_unavailable_chain_falls_back_to_a_snapshot() -> void:
	var h := _h()
	h.sender.spool.max_ops = 2
	h.sender.end_session()
	h.link.open = false
	for i in 4:
		h.sculpt(Vector2i(0, 0), 20 + i, 1.0)
	h.link.open = true
	h.replica.reset_connection()
	h.sender.start_session(LiveHarness.SESSION)
	h.verify(self, "after fallback snapshot")
	assert_eq(h.replica.stats.snapshots, 2, "a second snapshot was installed")


func test_snapshot_waits_for_a_stable_committed_point() -> void:
	var h := LiveHarness.new()
	h.setup(scratch_dir())
	var tx := EditTransaction.new()
	tx.begin(h.doc, "sculpt", "Raise")
	h.tx_open = tx
	tx.capture_heights(Vector2i(0, 0))
	h.doc.get_region(Vector2i(0, 0)).heights[3] = 9.0  # half a stroke
	h.sender.set_document(h.doc)
	h.sender.start_session(LiveHarness.SESSION)
	h.link.settle(20)
	assert_true(h.replica.document == null, "no snapshot while an operation is open")
	tx.rollback()
	h.tx_open = null
	h.link.settle()
	assert_true(h.replica.document != null, "snapshot taken after the operation ended")
	h.verify(self, "stable snapshot")
	assert_eq(h.replica.document.get_height_at_sample(3, 0), 0.0, "never serialized half a stroke")


func test_invalid_snapshot_is_refused_without_replacing_anything() -> void:
	var h := _h()
	var before := h.replica.authored_hash()
	var junk := PackedByteArray()
	junk.resize(5000)
	for i in junk.size():
		junk[i] = (i * 31) % 251
	var framer := LiveBlobFramer.from_bytes(LiveIds.new_id(), junk)
	var stream := LiveIds.new_id()
	var begin := LiveEnvelope.build("blob_begin", LiveHarness.SESSION, stream, framer.begin_payload("snapshot", "worldpoc-v4"))
	h.replica.on_text(begin.text)
	for i in framer.chunk_count:
		h.replica.on_binary(framer.frame(i))
	h.replica.on_text(LiveEnvelope.build("blob_end", LiveHarness.SESSION, stream, {"transfer_id": framer.transfer_id}).text)
	var types: Array = h.replica.take_outgoing().map(func(t: String) -> String: return LiveEnvelope.parse(t, true).envelope.type)
	assert_true(types.has("resync_required"), "garbage snapshot -> %s" % str(types))
	assert_eq(h.replica.authored_hash(), before, "the installed world is untouched")
	assert_eq(h.replica.stream_id(), h.sender.stream_id(), "the stream is untouched")


func test_visual_readiness_is_reported_separately_from_data_integrity() -> void:
	var h := _h()
	h.replica.visual_probe = func() -> bool: return false  # e.g. a remote binding that is not resolved yet
	h.sculpt(Vector2i(0, 0), 5, 1.0)
	h.verify(self, "data is exact")
	assert_eq(h.sender.stats.visual_ready, false, "commit_ack says the visuals are not ready")
	h.replica.visual_probe = Callable()
	h.sculpt(Vector2i(0, 0), 6, 1.0)
	h.verify(self, "ready again")
	assert_eq(h.sender.stats.visual_ready, true)
