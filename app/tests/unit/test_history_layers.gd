extends TestCase
## Undo/redo/rollback for tint colours, scatter, paths and rules.

const PATH_A := "33333333-3333-4333-8333-333333333333"
const PATH_B := "44444444-4444-4444-8444-444444444444"


func _doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.default_value())
	doc.scatter.add("nature.tree.spruce_a", 1, 1.0, 2.0, 0.5, 1.0, 0)
	doc.scatter.add("nature.tree.spruce_a", 1, 3.0, 4.0, 0.25, 1.5, 1)
	var p := PathRecord.new()
	p.path_id = PATH_A
	p.width_m = 2.0
	p.points = PackedVector2Array([Vector2(0, 0), Vector2(5, 5)])
	doc.put_path(p)
	return doc


func _commit(doc: WorldDocument, hist: CommandHistory, tx: EditTransaction) -> WorldChange:
	var c := tx.finish()
	if c != null:
		doc.bump_revision()
		hist.push_already_applied(c)
	return c


func test_colors_undo_redo() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var h0 := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "tint", "Tint")
	assert_true(tx.capture_colors(Vector2i(0, 0)))
	assert_true(tx.has_captured_colors(Vector2i(0, 0)))
	doc.get_region(Vector2i(0, 0)).color[0] = 10
	doc.get_region(Vector2i(0, 0)).color[3] = 200
	tx.capture_colors(Vector2i(-1, 0))  # captured but unchanged: dropped
	var c := _commit(doc, hist, tx)
	assert_eq(c.color_regions(), [Vector2i(0, 0)], "unchanged capture dropped")
	assert_eq(c.before_colors[Vector2i(0, 0)][0], 0xFF)
	assert_eq(c.after_colors[Vector2i(0, 0)][3], 200)
	assert_true(c.affected_world_bounds.has_point(Vector2(10, 10)), "bounds cover the region")
	assert_true(c.payload_bytes >= 2 * WorldConstants.REGION_MAP_BYTES)
	var h1 := CanonicalEncoder.authored_hash(doc)
	assert_ne(h0, h1)
	hist.undo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h0)
	hist.redo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h1)
	doc.get_region(Vector2i(0, 0)).color[0] = 99
	assert_eq(c.after_colors[Vector2i(0, 0)][0], 10, "snapshot not aliased")


func test_scatter_undo_redo_restores_order() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var h0 := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "scatter", "Scatter")
	assert_true(tx.capture_scatter())
	doc.scatter.add("nature.tree.spruce_a", 1, -5.0, 5.0, 0.0, 1.0, 0)
	doc.scatter.remove_indices(PackedInt32Array([0]))
	var c := _commit(doc, hist, tx)
	assert_true(c.has_scatter())
	assert_eq(c.before_scatter.count(), 2)
	assert_eq(c.after_scatter.count(), 2)
	assert_eq(c.payload_bytes, 4 * WorldChange.SCATTER_INSTANCE_BYTES_ESTIMATE)
	var h1 := CanonicalEncoder.authored_hash(doc)
	hist.undo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h0, "order restored exactly")
	assert_eq(doc.scatter.x[0], 1.0)
	hist.redo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h1)
	assert_true(doc.scatter != c.after_scatter, "document gets a copy")


func test_paths_create_edit_delete() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var h0 := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "path", "Path")
	tx.capture_path(PATH_A)
	tx.capture_path(PATH_B)
	doc.get_path_record(PATH_A).points[1] = Vector2(8, 8)
	var added := PathRecord.new()
	added.path_id = PATH_B
	added.width_m = 3.0
	added.points = PackedVector2Array([Vector2(-20, -20), Vector2(-10, -30)])
	doc.put_path(added)
	var c := _commit(doc, hist, tx)
	assert_eq(c.path_ids().size(), 2)
	assert_true(c.before_paths[PATH_B] == null, "creation: null before")
	assert_true(c.affected_world_bounds.has_point(Vector2(-15, -25)), "bounds from path points")
	var h1 := CanonicalEncoder.authored_hash(doc)
	hist.undo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h0)
	assert_true(doc.get_path_record(PATH_B) == null, "created path removed")
	assert_eq(doc.get_path_record(PATH_A).points[1], Vector2(5, 5))
	hist.redo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h1)
	var tx2 := EditTransaction.new()
	tx2.begin(doc, "path", "Delete")
	tx2.capture_path(PATH_A)
	doc.remove_path(PATH_A)
	_commit(doc, hist, tx2)
	assert_true(doc.get_path_record(PATH_A) == null)
	hist.undo(doc)
	assert_true(doc.get_path_record(PATH_A) != null, "deleted path restored")


func test_rules_undo_redo() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var h0 := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "rules", "Rock slope")
	assert_true(tx.capture_rules())
	doc.rules.rock_slope_deg = 50
	var c := _commit(doc, hist, tx)
	assert_true(c.has_rules())
	assert_eq(c.before_rules.rock_slope_deg, 30)
	assert_eq(c.after_rules.rock_slope_deg, 50)
	var h1 := CanonicalEncoder.authored_hash(doc)
	hist.undo(doc)
	assert_eq(doc.rules.rock_slope_deg, 30)
	assert_eq(CanonicalEncoder.authored_hash(doc), h0)
	hist.redo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), h1)


func test_noop_captures_produce_no_change() -> void:
	var doc := _doc()
	var tx := EditTransaction.new()
	tx.begin(doc, "mixed", "Nothing")
	tx.capture_colors(Vector2i(0, 0))
	tx.capture_scatter()
	tx.capture_path(PATH_A)
	tx.capture_path(PATH_B)
	tx.capture_rules()
	doc.scatter.add("nature.tree.spruce_a", 1, 9.0, 9.0, 0.0, 1.0, 0)
	doc.scatter.remove_indices(PackedInt32Array([2]))  # add + remove: semantically unchanged
	assert_true(tx.finish() == null, "unchanged captures -> null")


func test_rollback_restores_every_layer() -> void:
	var doc := _doc()
	var h0 := CanonicalEncoder.authored_hash(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "mixed", "Mixed")
	tx.capture_colors(Vector2i(0, 0))
	tx.capture_scatter()
	tx.capture_path(PATH_A)
	tx.capture_path(PATH_B)
	tx.capture_rules()
	doc.get_region(Vector2i(0, 0)).color[1] = 3
	doc.scatter.remove_indices(PackedInt32Array([0, 1]))
	doc.get_path_record(PATH_A).width_m = 5.0
	var p := PathRecord.new()
	p.path_id = PATH_B
	p.width_m = 1.0
	doc.put_path(p)
	doc.rules.sand_enabled = false
	var touched := tx.rollback()
	assert_eq(CanonicalEncoder.authored_hash(doc), h0, "everything restored")
	assert_eq(touched.colors, [Vector2i(0, 0)])
	assert_true(touched.scatter and touched.rules)
	assert_eq(touched.paths.size(), 2)
	assert_true(doc.get_path_record(PATH_B) == null)


func test_budget_covers_new_captures() -> void:
	var doc := _doc()
	var tx := EditTransaction.new()
	tx.begin(doc, "mixed", "Mixed")
	tx.max_payload_bytes = WorldConstants.REGION_MAP_BYTES * 2 + 50
	assert_true(tx.capture_colors(Vector2i(0, 0)), "2 * bytes fits exactly")
	assert_false(tx.capture_scatter(), "scatter reservation exceeds the budget")
	assert_true(tx.budget_exceeded)
	assert_false(tx.has_captured_scatter(), "nothing captured on refusal")
	tx.rollback()
