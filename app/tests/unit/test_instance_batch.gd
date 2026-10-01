extends TestCase
## InstanceBatch (spec §7.3, §7.4): BATCH-01, BATCH-02, BATCH-04 and the upload/bounds counters.

const MESH_AABB := AABB(Vector3(-1.4, 0.0, -1.4), Vector3(2.8, 7.0, 2.8))

var _batches: Array[InstanceBatch] = []


func after_each() -> void:
	for b in _batches:
		b.node.free()
	_batches.clear()


func _batch(origin: Vector3 = Vector3.ZERO) -> InstanceBatch:
	var b := InstanceBatch.new(origin, BoxMesh.new())
	_batches.append(b)
	return b


func _xf(rng: RandomNumberGenerator, center: Vector3, spread: float) -> Transform3D:
	var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * rng.randf_range(0.5, 2.5))
	return Transform3D(basis, center + Vector3(rng.randf_range(-spread, spread), rng.randf_range(0.0, 8.0),
			rng.randf_range(-spread, spread)))


func _slot_world(b: InstanceBatch, id: String) -> Transform3D:
	var local := b.local_transform(b.slot_of[id])
	return Transform3D(local.basis, local.origin + b.origin)


func _assert_maps(b: InstanceBatch, expected: Dictionary, msg: String) -> void:
	assert_eq(b.count, expected.size(), msg + ": count")
	assert_eq(b.slot_of.size(), b.count, msg + ": slot_of size")
	assert_true(b.capacity >= b.count and b.capacity & (b.capacity - 1) == 0, msg + ": power-of-two capacity")
	for slot in b.count:
		var id := b.ids[slot]
		assert_true(expected.has(id), msg + ": slot %d holds a live id" % slot)
		assert_eq(b.slot_of.get(id, -1), slot, msg + ": slot_of[ids[slot]]")
	for id: String in expected:
		assert_true(b.slot_of.has(id), msg + ": %s has a slot" % id)
		assert_eq(b.ids[b.slot_of[id]], id, msg + ": ids[slot_of[id]]")
	assert_eq(b.multimesh().visible_instance_count, b.count, msg + ": visible == count")


func test_random_add_update_remove_keep_maps_consistent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7001
	var b := _batch(Vector3(64, 0, -32))
	var expected := {}
	for step in 2000:
		var id := "id%d" % rng.randi_range(0, 120)
		var op := rng.randi_range(0, 2)
		var xf := _xf(rng, Vector3(80, 0, -20), 14.0)
		if op == 0 or not expected.has(id):
			b.add(id, xf, MESH_AABB)
			expected[id] = xf
		elif op == 1:
			b.update(id, xf, MESH_AABB)
			expected[id] = xf
		else:
			assert_true(b.remove(id))
			expected.erase(id)
		if step % 50 == 0:
			b.flush()
			_assert_maps(b, expected, "step %d" % step)
	b.flush()
	_assert_maps(b, expected, "end")
	for id: String in expected:
		var got := _slot_world(b, id)
		var want: Transform3D = expected[id]
		assert_vec_near(got.origin, want.origin, 1e-4, id + " origin")
		assert_true(got.basis.is_equal_approx(want.basis), id + " basis")
	assert_false(b.remove("absent"))


func test_growth_keeps_every_transform_and_never_draws_inactive_capacity() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7002
	var b := _batch(Vector3(32, 0, 32))
	var expected := {}
	for i in 512:
		var xf := _xf(rng, Vector3(48, 0, 48), 15.0)
		b.add("t%d" % i, xf, MESH_AABB)
		expected["t%d" % i] = xf
		if i == 15 or i == 16 or i == 100:
			b.flush()
			assert_eq(b.multimesh().visible_instance_count, i + 1, "visible_instance_count == count at %d" % (i + 1))
			assert_true(b.multimesh().instance_count >= i + 1)
	assert_eq(b.capacity, 512)
	b.flush()
	assert_eq(b.multimesh().instance_count, 512)
	assert_eq(b.multimesh().visible_instance_count, 512)
	for id: String in expected:
		var got := _slot_world(b, id)
		var want: Transform3D = expected[id]
		assert_vec_near(got.origin, want.origin, 1e-4, id + " origin after growth")
		assert_true(got.basis.is_equal_approx(want.basis), id + " basis after growth")
	# Engine readback is only compared when the active renderer stores instance data (the dummy one does not).
	var probe := b.multimesh().get_instance_transform(511)
	if probe.origin.distance_to(b.local_transform(511).origin) < 1e-4:
		for slot in 512:
			assert_vec_near(b.multimesh().get_instance_transform(slot).origin, b.local_transform(slot).origin, 1e-4, "GPU slot %d" % slot)
	for i in 400:
		b.remove("t%d" % i)
	b.flush()
	assert_eq(b.count, 112)
	assert_eq(b.multimesh().visible_instance_count, 112, "inactive capacity is not drawn after removals")
	assert_eq(b.capacity, 512, "capacity only grows")


func test_cell_local_storage_reproduces_world_transforms_everywhere() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7003
	var extremes: Array[Vector2i] = [Vector2i(-16, -16), Vector2i(15, 15), Vector2i(-1, -1), Vector2i(0, 0), Vector2i(-16, 15), Vector2i(15, -16)]
	for cell in extremes:
		var origin := Vector3(cell.x * 32.0, 0.0, cell.y * 32.0)
		var b := _batch(origin)
		assert_eq(b.node.position, origin)
		for i in 20:
			var xf := _xf(rng, origin + Vector3(16, 0, 16), 15.9)
			b.add("c%d" % i, xf, MESH_AABB)
			var got := _slot_world(b, "c%d" % i)
			assert_vec_near(got.origin, xf.origin, 1e-4, "cell %s origin" % cell)
			assert_true(got.basis.is_equal_approx(xf.basis), "cell %s basis" % cell)
			assert_true(absf(b.local_transform(i).origin.x) <= 32.0 + 1e-3, "local x stays small")


func test_uploads_are_partial_when_few_slots_change_and_full_otherwise() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7004
	var b := _batch()
	for i in 100:
		b.add("u%d" % i, _xf(rng, Vector3.ZERO, 10.0), MESH_AABB)
	b.flush()
	assert_eq(b.full_uploads, 1)
	assert_eq(b.partial_uploads, 0)
	assert_false(b.is_dirty())
	b.flush()
	assert_eq(b.full_uploads + b.partial_uploads, 1, "flushing a clean batch uploads nothing")
	for i in 5:
		b.update("u%d" % i, _xf(rng, Vector3.ZERO, 10.0), MESH_AABB)
	b.flush()
	assert_eq(b.partial_uploads, 1)
	assert_eq(b.full_uploads, 1)
	for i in 40:
		b.update("u%d" % i, _xf(rng, Vector3.ZERO, 10.0), MESH_AABB)
	b.flush()
	assert_eq(b.full_uploads, 2, "more than 32 dirty slots use one full buffer")


func test_custom_aabb_grows_immediately_and_shrinks_lazily() -> void:
	var b := _batch(Vector3(32, 0, 0))
	for i in 9:
		b.add("near%d" % i, Transform3D(Basis.IDENTITY, Vector3(32 + 1, 0, 0)), MESH_AABB)
	b.add("far", Transform3D(Basis.IDENTITY, Vector3(32 + 10, 0, 0)), MESH_AABB)
	var box := b.custom_aabb
	assert_true(box.has_point(Vector3(10.0, 3.0, 0.0)), "cell-local bounds include the far member before any flush")
	assert_vec_near(b.world_aabb().position, box.position + b.origin, 1e-6)
	b.remove("far")
	for i in 5:
		b.remove("near%d" % i)
	b.flush()
	assert_true(b.custom_aabb.size.x < box.size.x, "bounds shrink once fewer than half of the members remain")
	assert_true(b.custom_aabb.encloses(AABB(Vector3(1.0 - 1.4, 0, -1.4), Vector3(2.8, 7.0, 2.8)).grow(-0.01)), "never undersized")
