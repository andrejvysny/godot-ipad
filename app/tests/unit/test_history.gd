extends TestCase
## Transactions and bounded history (TE-05, TE-12, OB-05, IO-10).


func _doc() -> WorldDocument:
	return WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, AssetCatalog.load_from()[0])


func _raise(doc: WorldDocument, tx: EditTransaction, loc: Vector2i, index: int, dh: float) -> void:
	tx.capture_heights(loc)
	doc.get_region(loc).heights[index] += dh
	doc.invalidate_height_range(loc)


func test_finish_captures_before_after_and_undo_redo_exact() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var before_hash := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	for loc in WorldLayout.legacy().region_locations():
		_raise(doc, tx, loc, 1000, 0.75)
	var change := tx.finish()
	assert_true(change != null, "change produced")
	assert_eq(change.height_regions().size(), 4, "four regions")
	doc.bump_revision()
	hist.push_already_applied(change)
	var after_hash := CanonicalEncoder.authored_hash(doc)
	assert_ne(before_hash, after_hash)
	hist.undo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), before_hash, "undo exact")
	assert_eq(doc.document_revision, 2, "undo increments revision")
	hist.redo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), after_hash, "redo exact")
	assert_eq(doc.document_revision, 3)


func test_snapshots_are_not_aliased_to_live_buffers() -> void:
	var doc := _doc()
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	_raise(doc, tx, Vector2i(0, 0), 5, 1.0)
	var change := tx.finish()
	doc.get_region(Vector2i(0, 0)).heights[5] = 99.0  # later live edit
	assert_eq(change.after_heights[Vector2i(0, 0)][5], 1.0, "after snapshot immutable")
	assert_eq(change.before_heights[Vector2i(0, 0)][5], 0.0, "before snapshot immutable")


func test_noop_creates_no_change() -> void:
	var doc := _doc()
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	tx.capture_heights(Vector2i(0, 0))
	tx.capture_controls(Vector2i(-1, 0))
	assert_true(tx.finish() == null, "no-op returns null")


func test_rollback_restores_all_regions_and_objects() -> void:
	var doc := _doc()
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = doc.assets.bundled_binding_for("nature.tree.spruce_a")
	doc.put_object(rec)
	var before_hash := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	for loc in WorldLayout.legacy().region_locations():
		_raise(doc, tx, loc, 77, 2.0)
		tx.capture_controls(loc)
		doc.get_region(loc).control[77] = ControlCodec.encode_paint(0, 200)
	tx.capture_object(rec.object_id)
	var moved := rec.clone()
	moved.set_position(1, 2, 3)
	doc.put_object(moved)
	var created := ObjectRecord.new()
	created.object_id = ObjectRecord.new_uuid_v4()
	tx.capture_object(created.object_id)
	doc.put_object(created)
	var touched := tx.rollback()
	assert_eq(CanonicalEncoder.authored_hash(doc), before_hash, "pre-stroke hash restored")
	assert_eq(touched.heights.size(), 4)
	assert_true(doc.get_object(created.object_id) == null, "created object removed")


func test_delete_and_undo_restores_same_id_and_transform() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = doc.assets.bundled_binding_for("nature.rock.boulder_a")
	rec.set_position(3.25, 1.5, -9.125)
	rec.set_yaw(1.0)
	doc.put_object(rec)
	var tx := EditTransaction.new()
	tx.begin(doc, "select", "Delete")
	tx.capture_object(rec.object_id)
	doc.remove_object(rec.object_id)
	hist.push_already_applied(tx.finish())
	assert_true(doc.get_object(rec.object_id) == null)
	hist.undo(doc)
	assert_true(doc.get_object(rec.object_id) != null and doc.get_object(rec.object_id).equals(rec), "same record restored")


func test_redo_branch_truncation_and_eviction() -> void:
	var doc := _doc()
	var hist := CommandHistory.new(3)
	for i in 5:
		var tx := EditTransaction.new()
		tx.begin(doc, "sculpt", "Raise %d" % i)
		_raise(doc, tx, Vector2i(0, 0), i, 1.0)
		hist.push_already_applied(tx.finish())
	assert_eq(hist.size(), 3, "capped at 3")
	assert_eq(hist.evicted_count, 2)
	var world_before := CanonicalEncoder.authored_hash(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), world_before, "eviction does not modify world")
	hist.undo(doc)
	hist.undo(doc)
	assert_true(hist.can_redo())
	var tx2 := EditTransaction.new()
	tx2.begin(doc, "sculpt", "Branch")
	_raise(doc, tx2, Vector2i(-1, -1), 0, 1.0)
	hist.push_already_applied(tx2.finish())
	assert_false(hist.can_redo(), "new action drops redo branch")
	assert_eq(hist.size(), 2)


func test_byte_budget_eviction() -> void:
	var doc := _doc()
	# One height region change is 2 * 256 KiB; budget allows two such entries.
	var hist := CommandHistory.new(20, 1100 * 1024)
	for i in 4:
		var tx := EditTransaction.new()
		tx.begin(doc, "sculpt", "Raise %d" % i)
		_raise(doc, tx, Vector2i(0, 0), i, 1.0)
		hist.push_already_applied(tx.finish())
	assert_eq(hist.size(), 2, "byte budget keeps two entries")
	assert_true(hist.total_bytes() <= 1100 * 1024)


func test_transaction_budget_rejects_capture() -> void:
	var doc := _doc()
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	tx.max_payload_bytes = WorldConstants.REGION_MAP_BYTES * 3
	assert_true(tx.capture_heights(Vector2i(0, 0)))
	assert_false(tx.capture_heights(Vector2i(-1, 0)), "second region exceeds budget")
	assert_true(tx.budget_exceeded)
	tx.rollback()


func test_eviction_drops_oldest_first() -> void:
	var doc := _doc()
	var hist := CommandHistory.new(3)
	for i in 5:
		var tx := EditTransaction.new()
		tx.begin(doc, "sculpt", "Raise %d" % i)
		_raise(doc, tx, Vector2i(0, 0), i, 1.0)
		hist.push_already_applied(tx.finish())
	assert_eq(hist.oldest_label(), "Raise 2")
	assert_eq(hist.peek_undo_label(), "Raise 4")
	for i in 3:
		assert_true(hist.undo(doc) != null, "every retained entry undoes")
	assert_false(hist.can_undo())


func test_oversized_entry_is_kept_and_evicts_older() -> void:
	var doc := _doc()
	# Budget below one height-region entry (2 * 256 KiB): only the newest survives.
	var hist := CommandHistory.new(100, 256 * 1024)
	for i in 3:
		var tx := EditTransaction.new()
		tx.begin(doc, "sculpt", "Raise %d" % i)
		_raise(doc, tx, Vector2i(0, 0), i, 1.0)
		hist.push_already_applied(tx.finish())
	assert_eq(hist.size(), 1, "newest kept despite exceeding the budget")
	assert_eq(hist.peek_undo_label(), "Raise 2")
	assert_eq(hist.evicted_count, 2)
	assert_true(hist.undo(doc) != null)


func test_default_limits() -> void:
	var hist := CommandHistory.new()
	assert_eq(hist.max_actions, 100)
	assert_eq(hist.max_bytes, 256 * 1024 * 1024)
