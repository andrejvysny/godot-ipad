extends TestCase
## WORLD-04: a 1 km world with exactly 50,000 valid objects survives checkpoint, recovery, export,
## import and the consumer load path with identical authored hash and object data, and the
## per-commit checkpoint snapshot stays cheap on the main thread (docs/rendering-performance-spec.md
## §16.4, §16.6). Desktop headless evidence only.

const COUNT := 50000
const ASSETS := ["nature.tree.spruce_a", "nature.rock.boulder_a", "built.lodge.cabin_a"]

var _catalog: AssetCatalog
var _root := ""
var _storage: WorldStorage


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_root = scratch_dir()


func after_each() -> void:
	if _storage != null:
		_storage.shutdown()
		if _storage.is_inside_tree():
			tree.root.remove_child(_storage)
		_storage.free()
		_storage = null


## Hills terrain plus exactly COUNT grounded objects over the whole extent, including both sides of
## every region seam and the four corners.
func _world() -> WorldDocument:
	var doc: WorldDocument = SessionWorldOps.new_layout_world(WorldLayout.km1(), "hills", _catalog)[0]
	var lo := doc.layout.world_min()
	var hi := doc.layout.world_max_sample()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var anchors: Array[Vector2] = [Vector2(lo.x, lo.y), Vector2(hi.x, hi.y), Vector2(lo.x, hi.y), Vector2(hi.x, lo.y),
		Vector2(0.0, 0.0), Vector2(-0.5, -0.5), Vector2(127.5, 128.0), Vector2(-128.5, -128.0)]
	for i in COUNT:
		var asset := _catalog.get_asset(ASSETS[i % ASSETS.size()])
		var x := rng.randf_range(lo.x, hi.x)
		var z := rng.randf_range(lo.y, hi.y)
		if i < anchors.size():
			x = anchors[i].x
			z = anchors[i].y
		elif i % 7 == 0:  # a sample row/column either side of a region seam
			x = float(rng.randi_range(-3, 3)) * 128.0 + (-0.5 if i % 2 == 0 else 0.0)
		var r := ObjectRecord.new()
		r.object_id = "%08x-%04x-4%03x-8%03x-%012x" % [(i * 2654435761) & 0xFFFFFFFF, i & 0xFFFF, (i >> 4) & 0xFFF, i & 0xFFF, i]
		r.binding_id = doc.assets.bundled_binding_for(asset.asset_id)
		r.grounding = WorldConstants.GROUNDING_FOLLOW
		r.uniform_scale = rng.randf_range(asset.scale_min, asset.scale_max)
		var q := Quaternion(Vector3.UP, rng.randf_range(0.0, TAU))
		r.rotation_xyzw = PackedFloat64Array([q.x, q.y, q.z, q.w])
		r.set_position(x, doc.sample_height(x, z), z)
		doc.put_object(r)
	return doc


func _storage_for_test() -> WorldStorage:
	_storage = WorldStorage.new()
	_storage.import_tmp_root = _root.path_join("import_tmp")
	tree.root.add_child(_storage)
	assert_empty_string(_storage.configure(_root.path_join("worlds"), 3, _catalog), "configure")
	return _storage


func _assert_same_objects(a: WorldDocument, b: WorldDocument, what: String) -> void:
	assert_eq(b.objects.size(), COUNT, "%s: object count" % what)
	var ids := a.sorted_object_ids()
	var mismatches := 0
	for id in ids:
		var other := b.get_object(id)
		if other == null or not a.get_object(id).equals(other):
			mismatches += 1
	assert_eq(mismatches, 0, "%s: every object is equal" % what)


func test_50k_objects_round_trip_through_storage_export_import_and_the_consumer_loader() -> void:
	var t_build := Time.get_ticks_usec()
	var doc := _world()
	print("    build km1 hills world + %d objects: %.0f ms" % [COUNT, float(Time.get_ticks_usec() - t_build) / 1000.0])
	assert_eq(doc.objects.size(), COUNT)
	assert_eq(WorldValidator.validate(doc, _catalog), PackedStringArray(), "valid world")
	assert_eq(WorldValidator.grounding_report(doc, _catalog).size(), 0, "FOLLOW_TERRAIN heights match the terrain")
	var hash := CanonicalEncoder.authored_hash(doc)
	var storage := _storage_for_test()

	var t_save := Time.get_ticks_usec()
	var saved := storage.checkpoint_now(doc)
	print("    checkpoint_now (snapshot + write + verify): %.0f ms" % (float(Time.get_ticks_usec() - t_save) / 1000.0))
	if not assert_true(saved.ok and saved.durable, str(saved.error)):
		return
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(saved.path).path_join("manifest.json")))
	assert_eq(manifest.authored_content_hash, hash, "manifest hash is the full-encode hash")

	var t_recover := Time.get_ticks_usec()
	var recovered := storage.recover_latest_valid(doc.world_id, _catalog)
	print("    recover_latest_valid (read + validate 50k objects): %.0f ms" % (float(Time.get_ticks_usec() - t_recover) / 1000.0))
	if not assert_empty_string(str(recovered.error), "recover"):
		return
	var back: WorldDocument = recovered.doc
	assert_eq(CanonicalEncoder.authored_hash(back), hash, "recovered authored hash")
	_assert_same_objects(doc, back, "recovered")
	assert_eq(WorldCodec.objects_json_bytes(back), WorldCodec.objects_json_bytes(doc), "objects.json bytes")
	for loc in doc.layout.region_locations():
		assert_eq(back.get_region(loc).height_bytes(), doc.get_region(loc).height_bytes(), "heights %s" % str(loc))
		assert_eq(back.get_region(loc).control_bytes(), doc.get_region(loc).control_bytes(), "control %s" % str(loc))

	var exported := storage.export_latest(doc.world_id, _catalog)
	if not assert_empty_string(str(exported.error), "export"):
		return
	var imported := WorldPackage.import_package(exported.path, _catalog, _root.path_join("import_tmp"))
	if not assert_empty_string(str(imported[1]), "import"):
		return
	assert_eq(CanonicalEncoder.authored_hash(imported[0]), hash, "imported authored hash")
	_assert_same_objects(doc, imported[0], "imported")

	# The consumer load path (MacConsumer --verify-only: WorldLoader.load_world + report) for both forms.
	for source: String in [str(saved.path), str(exported.path)]:
		var loaded := WorldLoader.load_world(source, _catalog, _root.path_join("import_tmp"))
		if not assert_empty_string(str(loaded[1]), "consumer load of %s" % source.get_file()):
			continue
		var report := WorldLoader.report(loaded[0], _catalog)
		assert_eq(report.object_count, COUNT)
		assert_eq(report.authored_hash, hash)
		assert_eq(report.grounding_mismatches, 0)
		assert_eq((report.regions as Dictionary).size(), 64)


func test_checkpoint_request_stays_cheap_on_the_main_thread_with_50k_objects() -> void:
	var doc := _world()
	var storage := _storage_for_test()
	var first := Time.get_ticks_usec()
	assert_empty_string(storage.request_checkpoint(doc))
	var first_ms := float(Time.get_ticks_usec() - first) / 1000.0
	var worst := 0.0
	var total := 0.0
	var runs := 5
	var ids := doc.sorted_object_ids()
	for k in runs:  # the worker keeps writing meanwhile; pending jobs coalesce
		var rec := doc.get_object(ids[k * 1000]).clone()  # replace-only: clone, edit, put
		rec.set_position(rec.position[0], rec.position[1] + 0.001, rec.position[2])
		doc.put_object(rec)
		doc.bump_revision()
		var t := Time.get_ticks_usec()
		assert_empty_string(storage.request_checkpoint(doc))
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		worst = maxf(worst, ms)
		total += ms
	print("    TIMING request_checkpoint main thread, 50k objects km1: first %.1f ms, then %.2f ms avg / %.2f ms worst (desktop headless)" % [first_ms, total / runs, worst])
	assert_true(worst < 50.0, "warm request_checkpoint %.2f ms stays far below a frame-stall budget" % worst)
	while storage.is_busy():
		OS.delay_msec(20)
		storage._process(0.0)
	var recovered := storage.recover_latest_valid(doc.world_id, _catalog)
	assert_empty_string(str(recovered.error), "latest checkpoint recovers")
	if recovered.doc != null:
		assert_eq(CanonicalEncoder.authored_hash(recovered.doc), CanonicalEncoder.authored_hash(doc), "the last edit is durable")
