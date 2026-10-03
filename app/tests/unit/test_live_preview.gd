extends TestCase
## Provisional previews: sampling of an open EditTransaction, the receiver overlay, cancel, coalescing, timeout.

const LOC := Vector2i(0, 0)


func _h() -> LiveHarness:
	var h := LiveHarness.new()
	h.setup(scratch_dir())
	h.connect_and_sync()
	return h


func _begin(h: LiveHarness) -> EditTransaction:
	var tx := EditTransaction.new()
	tx.begin(h.doc, "sculpt", "Raise")
	h.tx_open = tx
	return tx


func _raise(h: LiveHarness, tx: EditTransaction, index: int, value: float) -> void:
	tx.capture_heights(LOC)
	h.doc.get_region(LOC).heights[index] = value


## Sample index of the first sample of tile (tx, tz) plus an offset.
func _in_tile(tx: int, tz: int, offset: int = 0) -> int:
	return tz * 64 * 256 + tx * 64 + offset


func _tick(h: LiveHarness) -> void:
	h.link.now_msec += 100
	h.sender.tick(h.link.now_msec)
	h.sender.flush_preview()


func _tile_values(bytes: PackedByteArray) -> PackedFloat32Array:
	return bytes.to_float32_array()


func test_preview_reaches_the_overlay_without_touching_the_committed_replica() -> void:
	var h := _h()
	var base := h.replica.authored_hash()
	var tx := _begin(h)
	_raise(h, tx, _in_tile(0, 0, 5), 2.5)
	_raise(h, tx, _in_tile(3, 3, 9), 7.0)
	_tick(h)
	h.link.settle()
	assert_eq(h.replica.stats.previews, 1, "one preview transfer")
	assert_eq(h.replica.overlay.tiles.size(), 2, "two changed tiles, not the whole region")
	assert_eq(h.replica.authored_hash(), base, "committed replica untouched")
	assert_eq(CanonicalEncoder.authored_hash(h.replica.document), base)
	var tile := h.replica.overlay.effective_tile(h.replica.document, LOC, 0, 0, LiveTiles.KIND_HEIGHT)
	assert_eq(_tile_values(tile)[5], 2.5, "overlay carries the provisional value")
	assert_eq(h.replica.document.get_height_at_sample(5, 0), 0.0, "committed view still has the old value")
	var untouched := h.replica.overlay.effective_tile(h.replica.document, LOC, 1, 1, LiveTiles.KIND_HEIGHT)
	assert_eq(_tile_values(untouched)[0], 0.0, "untouched tiles fall back to the committed bytes")
	# Commit: final authoritative values, overlay cleared.
	var change := tx.finish()
	h.tx_open = null
	h.commit(change)
	h.verify(self, "after commit")
	assert_true(h.replica.overlay.is_empty(), "commit of the operation clears the overlay")
	assert_eq(h.replica.document.get_height_at_sample(5, 0), 2.5)


func test_cancelled_operation_leaves_no_change_and_clears_the_overlay() -> void:
	var h := _h()
	var base := CanonicalEncoder.authored_hash(h.doc)
	var revision := h.doc.document_revision
	var tx := _begin(h)
	_raise(h, tx, _in_tile(1, 2, 3), 4.0)
	_tick(h)
	h.link.settle()
	assert_false(h.replica.overlay.is_empty(), "preview visible")
	tx.rollback()
	h.tx_open = null
	_tick(h)
	h.link.settle()
	assert_true(h.replica.overlay.is_empty(), "overlay cleared by preview_cancel")
	assert_eq(h.sender.stats.preview_cancels, 1)
	assert_eq(h.replica.revision(), revision, "no revision was created")
	assert_eq(h.replica.authored_hash(), base)
	assert_eq(CanonicalEncoder.authored_hash(h.replica.document), base, "no persistent change")
	assert_eq(h.doc.document_revision, revision)


func test_unsent_cancel_still_clears_when_the_cancel_message_is_lost() -> void:
	var h := _h()
	var tx := _begin(h)
	_raise(h, tx, _in_tile(0, 1, 1), 3.0)
	_tick(h)
	h.link.settle()
	assert_false(h.replica.overlay.is_empty())
	h.replica.reset_connection()  # connection reset: correctness never depends on the cancel message
	assert_true(h.replica.overlay.is_empty())
	tx.rollback()


func test_coalescing_keeps_each_tiles_latest_value_when_intermediate_previews_are_dropped() -> void:
	var h := _h()
	var tx := _begin(h)
	# The link is never pumped between samples: every sample overwrites the pending value of its key.
	_raise(h, tx, _in_tile(0, 0, 0), 1.0)
	_tick(h)
	_raise(h, tx, _in_tile(2, 1, 0), 5.0)
	_tick(h)
	_raise(h, tx, _in_tile(0, 0, 0), 2.0)
	_tick(h)
	_raise(h, tx, _in_tile(0, 0, 1), 3.0)
	_raise(h, tx, _in_tile(2, 1, 0), 6.0)
	_tick(h)
	assert_eq(h.sender.outbox.queue.filter(func(i: LiveOutItem) -> bool: return i.kind == "preview").size(), 1,
		"a single preview placeholder, never a backlog of previews")
	h.link.settle()
	assert_eq(h.replica.stats.previews, 1, "the receiver got one coalesced preview")
	var a := _tile_values(h.replica.overlay.effective_tile(h.replica.document, LOC, 0, 0, LiveTiles.KIND_HEIGHT))
	var b := _tile_values(h.replica.overlay.effective_tile(h.replica.document, LOC, 2, 1, LiveTiles.KIND_HEIGHT))
	assert_eq([a[0], a[1]], [2.0, 3.0], "tile (0,0) keeps its latest values")
	assert_eq(b[0], 6.0, "tile (2,1) keeps its latest value")
	tx.rollback()


func test_later_previews_keep_earlier_touched_tiles() -> void:
	var h := _h()
	var tx := _begin(h)
	_raise(h, tx, _in_tile(0, 0, 0), 1.0)
	_tick(h)
	h.link.settle()
	_raise(h, tx, _in_tile(3, 0, 0), 9.0)
	_tick(h)
	h.link.settle()
	assert_eq(h.replica.stats.previews, 2)
	assert_eq(h.replica.overlay.tiles.size(), 2, "a later patch does not erase earlier touched keys")
	tx.rollback()


func test_highest_preview_sequence_wins_per_key() -> void:
	var overlay := LiveOverlay.new()
	var loc := Vector2i(0, 0)
	var tile_a := PackedByteArray()
	tile_a.resize(LiveTiles.TILE_BYTES)
	var tile_b := tile_a.duplicate()
	tile_b[0] = 7
	var newer := {"operation_id": "op", "preview_seq": 5, "tiles": [{"loc": loc, "tx": 0, "tz": 0,
		"kind": LiveTiles.KIND_HEIGHT, "bytes": tile_b}], "upserts": [], "deletes": []}
	var older := {"operation_id": "op", "preview_seq": 3, "tiles": [{"loc": loc, "tx": 0, "tz": 0,
		"kind": LiveTiles.KIND_HEIGHT, "bytes": tile_a}], "upserts": [], "deletes": []}
	overlay.apply(newer, 0)
	overlay.apply(older, 1)  # reordered delivery of an older preview
	assert_eq((overlay.tiles.values()[0].bytes as PackedByteArray)[0], 7, "the older sequence is ignored")
	overlay.apply({"operation_id": "other", "preview_seq": 1, "tiles": [], "upserts": [], "deletes": []}, 2)
	assert_true(overlay.is_empty(), "another operation replaces the overlay")


func test_object_preview_is_absolute_and_cleared_by_the_commit() -> void:
	var h := _h()
	var id := ObjectRecord.new_uuid_v4()
	var tx := _begin(h)
	tx.capture_object(id)
	var rec := ObjectRecord.new()
	rec.object_id = id
	rec.binding_id = h.binding(LiveHarness.BOULDER)
	rec.set_position(10.0, 0.0, 12.0)
	h.doc.put_object(rec)
	_tick(h)
	h.link.settle()
	assert_true(h.replica.overlay.objects.has(id), "provisional object in the overlay")
	assert_true(h.replica.document.get_object(id) == null, "not in the committed replica")
	assert_true(h.replica.overlay.provisional.has(rec.binding_id), "its binding travels as a provisional binding")
	var moved := rec.clone()
	moved.set_position(11.0, 0.0, 12.0)
	h.doc.put_object(moved)
	_tick(h)
	h.link.settle()
	assert_eq(h.replica.overlay.objects[id].record.position[0], 11.0, "latest absolute state")
	var change := tx.finish()
	h.tx_open = null
	h.commit(change)
	h.verify(self, "object commit")
	assert_true(h.replica.overlay.is_empty())
	assert_true(h.replica.document.assets.has_binding(rec.binding_id), "the commit's lock now holds the binding")


func test_scatter_preview_tiles_are_valid_wpst_files() -> void:
	var h := _h()
	var tx := _begin(h)
	tx.capture_scatter()
	h.doc.scatter.add(h.binding(LiveHarness.SPRUCE), 3.0, 4.0, 0.5, 1.0, 0)
	h.doc.scatter.add(h.binding(LiveHarness.SPRUCE), 40.0, 4.0, 0.5, 1.0, 0)  # next 32 m tile
	h.sender.mark_scatter_rect(Rect2(0.0, 0.0, 60.0, 10.0))
	_tick(h)
	h.sender.flush_preview()
	_tick(h)
	h.link.settle()
	var tiles := h.replica.overlay.scatter_tiles
	assert_eq(tiles.size(), 2, "two 32 m tiles inside the affected bounds")
	for key: String in tiles:
		var t: Dictionary = tiles[key]
		var checked := LiveScatterTile.validate(t.bytes, LiveTiles.world_rect(t.loc, t.tx, t.tz))
		assert_true(checked.ok, str(checked.error))
		assert_eq(checked.count, 1)
	var change := tx.finish()
	h.tx_open = null
	h.commit(change)
	h.verify(self, "scatter commit")
	assert_true(h.replica.overlay.is_empty())


func test_overlay_times_out_and_stream_change_clears_it() -> void:
	var h := _h()
	var tx := _begin(h)
	_raise(h, tx, _in_tile(0, 0, 0), 1.0)
	_tick(h)
	h.link.settle()
	assert_false(h.replica.overlay.is_empty())
	var last := h.replica.overlay.last_preview_msec
	h.replica.tick(last + LiveOverlay.TIMEOUT_MSEC - 1)
	assert_false(h.replica.overlay.is_empty(), "still alive just before 10 s")
	h.replica.tick(last + LiveOverlay.TIMEOUT_MSEC)
	assert_true(h.replica.overlay.is_empty(), "cleared after 10 s without preview traffic")
	assert_eq(h.replica.stats.overlay_timeouts, 1)
	tx.rollback()
	h.tx_open = null
	# A stream change installs a new snapshot and clears whatever the overlay held.
	var tx2 := _begin(h)
	_raise(h, tx2, _in_tile(0, 0, 0), 2.0)
	_tick(h)
	h.link.settle()
	assert_false(h.replica.overlay.is_empty())
	tx2.rollback()
	h.tx_open = null
	h.sender.set_document(h.doc)  # new stream
	h.verify(self, "after stream change")
	assert_true(h.replica.overlay.is_empty())


func test_previews_stay_off_until_the_baseline_is_acknowledged() -> void:
	var h := LiveHarness.new()
	h.setup(scratch_dir())
	h.sender.set_document(h.doc)
	var tx := _begin(h)
	_raise(h, tx, _in_tile(0, 0, 0), 1.0)
	h.sender.start_session(LiveHarness.SESSION)
	_tick(h)
	assert_false(h.sender.outbox.has_kind("preview"), "no preview before the snapshot is acknowledged")
	tx.rollback()
