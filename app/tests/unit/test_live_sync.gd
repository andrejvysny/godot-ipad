extends TestCase
## Sender -> fake link -> replica: every operation kind reproduces the exact authored hash on the receiver.

const PID := "11111111-1111-4111-8111-111111111111"
const PIDS := ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
	"33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"]


func _h(layout: WorldLayout = null) -> LiveHarness:
	var h := LiveHarness.new()
	h.setup(scratch_dir(), layout)
	h.connect_and_sync()
	return h


func test_initial_snapshot_installs_the_exact_world() -> void:
	var h := _h()
	assert_true(h.replica.document != null, "snapshot installed")
	assert_true(h.sender.baseline_acked(), "sender saw snapshot_ack")
	assert_eq(h.replica.stream_id(), h.sender.stream_id())
	h.verify(self, "snapshot")


func test_terrain_operations_reproduce_the_hash() -> void:
	var h := _h()
	assert_true(h.sculpt(Vector2i(0, 0), 1000, 0.75, 3))
	h.verify(self, "sculpt")
	assert_true(h.sculpt(Vector2i(-1, -1), 5, -0.5))
	h.verify(self, "sculpt other region")
	assert_true(h.paint(Vector2i(0, -1), 2000, 120))
	h.verify(self, "paint")
	assert_true(h.tint(Vector2i(-1, 0), 60000, PackedByteArray([255, 10, 20, 128])))
	h.verify(self, "tint")
	assert_true(h.hole(Vector2i(0, 0), 300))
	h.verify(self, "holes")
	assert_eq(h.replica.stats.commits, 5)


func test_object_operations_reproduce_the_hash() -> void:
	var h := _h()
	var id := h.place(LiveHarness.SPRUCE, 10.0, 12.0)
	assert_ne(id, "")
	h.verify(self, "place")
	assert_true(h.move(id, -20.0, 30.0))
	h.verify(self, "move")
	var other := h.place(LiveHarness.BOULDER, 1.0, 2.0)
	h.verify(self, "second object, second binding")
	assert_true(h.delete_object(id))
	h.verify(self, "delete")
	assert_true(h.rebind(other, LiveHarness.SPRUCE))
	h.verify(self, "binding change")
	assert_true(h.delete_object(other))
	h.verify(self, "delete last user of a binding")


func test_scatter_path_and_rule_operations_reproduce_the_hash() -> void:
	var h := _h()
	assert_true(h.scatter_add(LiveHarness.SPRUCE, [Vector2(3, 4), Vector2(-5, 6), Vector2(40, -40)]))
	h.verify(self, "scatter brush")
	assert_true(h.scatter_add(LiveHarness.BOULDER, [Vector2(1, 1)]))
	h.verify(self, "scatter second binding")
	assert_true(h.scatter_erase(PackedInt32Array([0, 3])))
	h.verify(self, "scatter erase")
	assert_true(h.path_set(PID, PackedVector2Array([Vector2(0, 0), Vector2(10, 5), Vector2(20, 0)])))
	h.verify(self, "path edit")
	assert_true(h.path_delete(PID))
	h.verify(self, "path delete")
	assert_true(h.rules(45))
	h.verify(self, "rules change")


func test_undo_and_redo_are_new_revisions_with_the_same_content_hash() -> void:
	var h := _h()
	var base := CanonicalEncoder.authored_hash(h.doc)
	h.sculpt(Vector2i(0, 0), 10, 1.0)
	h.place(LiveHarness.SPRUCE, 5.0, 5.0)
	h.scatter_add(LiveHarness.BOULDER, [Vector2(2, 2)])
	h.verify(self, "after edits")
	var edited := CanonicalEncoder.authored_hash(h.doc)
	var revisions := [h.doc.document_revision]
	for i in 3:
		assert_true(h.undo())
		revisions.append(h.doc.document_revision)
		h.verify(self, "undo %d" % i)
	assert_eq(CanonicalEncoder.authored_hash(h.doc), base, "back to the original content")
	assert_eq(h.replica.authored_hash(), base, "receiver content equals the original")
	for i in 3:
		assert_true(h.redo())
		revisions.append(h.doc.document_revision)
		h.verify(self, "redo %d" % i)
	assert_eq(CanonicalEncoder.authored_hash(h.doc), edited, "redo restores the edited content")
	for i in range(1, revisions.size()):
		assert_eq(revisions[i], revisions[i - 1] + 1, "every undo/redo is exactly one new revision")


func _random_terrain_op(h: LiveHarness, rng: RandomNumberGenerator, kind: int) -> bool:
	var locs := [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]
	var loc: Vector2i = locs[rng.randi() % 4]
	match kind:
		0:
			return h.sculpt(loc, rng.randi() % 60000, rng.randf_range(-0.5, 0.9), 1 + rng.randi() % 20)
		1:
			return h.paint(loc, rng.randi() % 65536, 1 + rng.randi() % 250)
		2:
			return h.tint(loc, rng.randi() % 65000, PackedByteArray([rng.randi() % 256, 7, 9, 1 + rng.randi() % 255]))
	return h.hole(loc, rng.randi() % 65536)


func _random_object_op(h: LiveHarness, rng: RandomNumberGenerator, ids: Array[String], kind: int) -> bool:
	var pos := Vector2(rng.randf_range(-100, 100), rng.randf_range(-100, 100))
	if kind == 0:
		var id := h.place(LiveHarness.SPRUCE if rng.randi() % 2 == 0 else LiveHarness.BOULDER, pos.x, pos.y)
		if id != "":
			ids.append(id)
		return id != ""
	if ids.is_empty():
		return false
	if kind == 1:
		return h.move(ids[rng.randi() % ids.size()], pos.x, pos.y)
	var at := rng.randi() % ids.size()
	var ok := h.delete_object(ids[at])
	ids.remove_at(at)
	return ok


func _random_misc_op(h: LiveHarness, rng: RandomNumberGenerator, step: int) -> bool:
	match step % 4:
		0:
			var a := Vector2(rng.randf_range(-100, 100), rng.randf_range(-100, 100))
			return h.scatter_add(LiveHarness.SPRUCE, [a, a + Vector2(1, 1)])
		1:
			return h.doc.scatter.count() > 0 and h.scatter_erase(PackedInt32Array([rng.randi() % h.doc.scatter.count()]))
		2:
			return h.path_set(PIDS[step % 4], PackedVector2Array([Vector2(rng.randf_range(-50, 0), 0), Vector2(rng.randf_range(1, 50), 9)]))
	return h.rules(10 + rng.randi() % 50)


func test_random_sequence_of_operations_matches_after_every_operation() -> void:
	var h := _h()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261002
	var ids: Array[String] = []
	var done := 0
	var step := 0
	while done < 70:
		step += 1
		var ok := false
		match rng.randi() % 4:
			0:
				ok = _random_terrain_op(h, rng, rng.randi() % 4)
			1:
				ok = _random_object_op(h, rng, ids, rng.randi() % 3)
			2:
				ok = _random_misc_op(h, rng, step)
			3:
				ok = h.undo() if rng.randi() % 2 == 0 else h.redo()
				ids.clear()
				for id: String in h.doc.objects:
					ids.append(id)
		if ok:
			done += 1
			h.verify(self, "operation %d" % done)
	assert_true(h.sender.stats.snapshots == 1, "one snapshot for the whole run")
	assert_eq(h.sender.stats.gaps, 0)
	assert_eq(h.replica.stats.resyncs, 0, "never needed a resync")
