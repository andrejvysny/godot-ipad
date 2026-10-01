extends TestCase
## ObjectChunkCache (docs/rendering-performance-spec.md §16.6): the incremental checkpoint snapshot must
## be byte-identical to the full one, through random edits, undo, redo and document replacement.

const BOULDER := "nature.rock.boulder_a"
const SPRUCE := "nature.tree.spruce_a"

var _catalog: AssetCatalog
var _created_with := {"godot": "t", "terrain3d": "t", "world_painter": "t"}


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func _record(rng: RandomNumberGenerator, layout: WorldLayout, id: String) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = id
	r.asset_id = BOULDER if rng.randf() < 0.5 else SPRUCE
	r.asset_version = 1
	var lo := layout.world_min()
	var hi := layout.world_max_sample()
	r.set_position(rng.randf_range(lo.x, hi.x), rng.randf_range(-5.0, 20.0), rng.randf_range(lo.y, hi.y))
	var q := Quaternion(Vector3.UP, rng.randf_range(0.0, TAU))
	r.rotation_xyzw = PackedFloat64Array([q.x, q.y, q.z, q.w])
	r.uniform_scale = rng.randf_range(0.5, 1.5)
	r.grounding = WorldConstants.GROUNDING_FIXED if rng.randf() < 0.5 else WorldConstants.GROUNDING_FOLLOW
	r.height_offset_m = rng.randf_range(-0.5, 0.5)
	if rng.randf() < 0.2:
		r.origin = WorldConstants.ORIGIN_SCATTER
		r.scatter_operation_id = ObjectRecord.new_uuid_v4()
	return r


func _id(n: int) -> String:
	return "%08x-0000-4000-8000-%012d" % [(n * 2654435761) & 0xFFFFFFFF, n]


## Compares the cached snapshot with the plain one: every file, the hash, and the digests.
func _assert_same(doc: WorldDocument, cache: ObjectChunkCache, what: String) -> void:
	var cached := WorldCodec.snapshot(doc, _created_with, cache)
	var plain := WorldCodec.snapshot(doc, _created_with)
	assert_false(cached.files.has(WorldCodec.OBJECTS_FILE), "%s: objects are left to the worker" % what)
	WorldCodec.finalize_snapshot(cached)
	assert_eq(cached.files[WorldCodec.OBJECTS_FILE], plain.files[WorldCodec.OBJECTS_FILE], "%s: objects.json bytes" % what)
	assert_eq(cached.authored_content_hash, plain.authored_content_hash, "%s: authored hash" % what)
	assert_eq(plain.authored_content_hash, CanonicalEncoder.authored_hash(doc), "%s: plain hash" % what)
	for path: String in plain.files:
		assert_eq(cached.files[path], plain.files[path], "%s: %s" % [what, path])
		assert_eq((cached.digests[path] as PackedByteArray).hex_encode(), CanonicalEncoder.sha256_hex(plain.files[path]), "%s: digest %s" % [what, path])


func test_matches_full_encoding_on_every_fixture() -> void:
	for fixture in SessionWorldOps.FIXTURES:
		var loaded := SessionWorldOps.load_fixture(fixture, _catalog)
		assert_empty_string(str(loaded[1]), fixture)
		var cache := ObjectChunkCache.new()
		_assert_same(loaded[0], cache, fixture)
		_assert_same(loaded[0], cache, fixture + " again")
		assert_eq(cache.last_encoded, 0, "%s: a second snapshot re-encodes nothing" % fixture)


func test_empty_and_single_object_documents() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var cache := ObjectChunkCache.new()
	_assert_same(doc, cache, "empty")
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	doc.put_object(_record(rng, doc.layout, _id(1)))
	_assert_same(doc, cache, "one")
	doc.remove_object(_id(1))
	_assert_same(doc, cache, "empty again")


func test_random_edit_sequences_on_both_layouts() -> void:
	for layout in [WorldLayout.legacy(), WorldLayout.km1()]:
		var steps := 12 if layout.is_legacy() else 3  # a km1 snapshot hashes 48 MiB of terrain
		var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, layout)
		doc.catalog_id = _catalog.catalog_id
		doc.catalog_version = _catalog.catalog_version
		doc.catalog_sha256 = _catalog.sha256
		var cache := ObjectChunkCache.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 99
		var next := 0
		for step in steps:
			var edits := rng.randi_range(0, 40)
			var touched := 0
			for _i in edits:
				var roll := rng.randf()
				if roll < 0.5 or doc.objects.is_empty():
					doc.put_object(_record(rng, layout, _id(next)))
					next += 1
				elif roll < 0.8:
					var ids := doc.sorted_object_ids()
					var id := ids[rng.randi_range(0, ids.size() - 1)]
					doc.put_object(_record(rng, layout, id))  # replace under the same id
				else:
					var ids2 := doc.sorted_object_ids()
					doc.remove_object(ids2[rng.randi_range(0, ids2.size() - 1)])
				touched += 1
			_assert_same(doc, cache, "%s step %d" % [layout.name(), step])
			assert_true(cache.last_encoded <= touched, "only touched objects are re-encoded (%d <= %d)" % [cache.last_encoded, touched])


func test_stays_identical_through_edit_undo_and_redo() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 30:
		doc.put_object(_record(rng, doc.layout, _id(i)))
	var cache := ObjectChunkCache.new()
	var history := CommandHistory.new()
	_assert_same(doc, cache, "initial")
	for round in 6:
		var tx := EditTransaction.new()
		tx.begin(doc, "place", "edit")
		var victim := _id(round * 3)
		assert_true(tx.capture_object(victim))
		var edited := doc.get_object(victim).clone()
		edited.uniform_scale += 0.25
		edited.set_position(edited.position[0] + 1.0, edited.position[1], edited.position[2])
		doc.put_object(edited)
		var fresh := _id(100 + round)
		assert_true(tx.capture_object(fresh))
		doc.put_object(_record(rng, doc.layout, fresh))
		var gone := _id(round * 3 + 1)
		assert_true(tx.capture_object(gone))
		doc.remove_object(gone)
		var change := tx.finish()
		doc.bump_revision()
		history.push_already_applied(change)
		_assert_same(doc, cache, "edit %d" % round)
	for i in 6:
		history.undo(doc)
		_assert_same(doc, cache, "undo %d" % i)
	for i in 6:
		history.redo(doc)
		_assert_same(doc, cache, "redo %d" % i)


func test_rollback_restores_through_the_journal() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	doc.put_object(_record(rng, doc.layout, _id(1)))
	var cache := ObjectChunkCache.new()
	_assert_same(doc, cache, "before")
	var tx := EditTransaction.new()
	tx.begin(doc, "place", "edit")
	tx.capture_object(_id(1))
	tx.capture_object(_id(2))
	doc.put_object(_record(rng, doc.layout, _id(2)))
	doc.put_object(_record(rng, doc.layout, _id(1)))
	_assert_same(doc, cache, "mid-operation")
	tx.rollback()
	_assert_same(doc, cache, "rolled back")
	assert_eq(doc.objects.size(), 1)


func test_replaced_document_and_direct_writes_fall_back_to_a_rebuild() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var a := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var b := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	for i in 5:
		a.put_object(_record(rng, a.layout, _id(i)))
		b.put_object(_record(rng, b.layout, _id(10 + i)))
	var cache := ObjectChunkCache.new()
	_assert_same(a, cache, "a")
	_assert_same(b, cache, "b after a")
	assert_eq(cache.last_encoded, 5, "a new document is encoded in full")
	_assert_same(a, cache, "a after b")
	assert_eq(cache.last_encoded, 5)
	a.objects.erase(_id(2))  # bypasses the journal: the count check notices
	_assert_same(a, cache, "direct erase")
	_assert_same(a.duplicate_deep(), cache, "deep copy")


func test_two_caches_on_one_document_stay_correct() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL)
	var first := ObjectChunkCache.new()
	var second := ObjectChunkCache.new()
	for round in 4:
		doc.put_object(_record(rng, doc.layout, _id(round)))
		_assert_same(doc, first, "first %d" % round)
		doc.put_object(_record(rng, doc.layout, _id(round + 50)))
		_assert_same(doc, second, "second %d" % round)


func test_50k_snapshot_timing_after_warm_up() -> void:
	var layout := WorldLayout.km1()
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, layout)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 50000:
		doc.put_object(_record(rng, layout, _id(i)))
	var cache := ObjectChunkCache.new()
	var t0 := Time.get_ticks_usec()
	WorldCodec.snapshot(doc, _created_with, cache)
	var first_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var worst := 0.0
	var total := 0.0
	for k in 5:
		var id := _id(k * 997)
		doc.put_object(_record(rng, layout, id))
		var t := Time.get_ticks_usec()
		var snap := WorldCodec.snapshot(doc, _created_with, cache)
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		worst = maxf(worst, ms)
		total += ms
		assert_eq(cache.last_encoded, 1)
		assert_eq((snap.object_chunks.json as Array).size(), 50000)
	print("    TIMING 50k-object km1 snapshot: first full encode %.1f ms, warm %.2f ms avg / %.2f ms worst (desktop headless)" % [first_ms, total / 5.0, worst])
	assert_true(worst < 50.0, "warm snapshot stays far below a frame-stall budget (%.2f ms)" % worst)
