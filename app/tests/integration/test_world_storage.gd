extends TestCase
## Checkpoint storage (spec §17.3/§17.4): recovery, IO-03..IO-06, pruning, coalescing, and the
## real worker thread. Desktop evidence only; the on-device kill test (IO-03) is NOT RUN here.

const WAIT_LIMIT_MS := 20000

var _catalog: AssetCatalog
var _root := ""
var _storage: WorldStorage


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_root = "user://wp_storage_tests/%s_%s" % [current_test.replace("::", "_"), StorageFs.random_hex(4)]


func after_each() -> void:
	_drop_storage()
	StorageFs.remove_tree(_root)


func _make_storage(keep_count: int = 3) -> WorldStorage:
	_drop_storage()
	_storage = WorldStorage.new()
	_storage.import_tmp_root = _root.path_join("import_tmp")  # user:// is shared across sandboxes
	tree.root.add_child(_storage)
	assert_empty_string(_storage.configure(_root, keep_count, _catalog), "configure")
	return _storage


func _drop_storage() -> void:
	if _storage == null:
		return
	_storage.shutdown()
	if _storage.is_inside_tree():
		tree.root.remove_child(_storage)
	_storage.free()
	_storage = null


func _doc(revision: int = 1) -> WorldDocument:
	var doc := WorldDocument.create_flat(4.0, ControlCodec.grass_value(), null, _catalog)
	doc.document_revision = revision
	var r := ObjectRecord.new()
	r.object_id = "33333333-3333-4333-8333-333333333333"
	r.binding_id = doc.assets.bundled_binding_for("nature.rock.boulder_a")
	r.set_position(1.25, 4.0, -2.5)
	doc.put_object(r)
	return doc


## `doc` with every bundled binding replaced by the same asset of a catalog with another content hash.
func _foreign_catalog(doc: WorldDocument) -> WorldDocument:
	var foreign := {}
	for id in doc.assets.referenced_ids(doc):
		var b := AssetBinding.bundled_default(_catalog, _catalog.get_asset(doc.assets.get_binding(id).asset_id))
		b.catalog_sha256 = "cd".repeat(32)
		b.finalize()
		foreign[id] = doc.assets.add(b)
	for object_id in doc.sorted_object_ids():
		doc.get_object(object_id).binding_id = foreign[doc.get_object(object_id).binding_id]
	return doc


## Simulates a committed edit: changes content and bumps the revision.
func _edit(doc: WorldDocument) -> void:
	doc.get_region(Vector2i(0, 0)).heights[doc.document_revision] = 5.0 + doc.document_revision * 0.25
	doc.bump_revision()


func _gens(world_id: String) -> Array[int]:
	return GenerationStore.complete_generations(GenerationStore.generations_dir(_root, world_id))


func _gen_dir(world_id: String, n: int) -> String:
	return GenerationStore.generations_dir(_root, world_id).path_join(GenerationStore.generation_name(n))


func _wait_idle() -> bool:
	var t0 := Time.get_ticks_msec()
	while _storage.is_busy():
		if Time.get_ticks_msec() - t0 > WAIT_LIMIT_MS:
			fail("storage worker did not finish within %d ms" % WAIT_LIMIT_MS)
			return false
		await tree.process_frame
	return true


func test_checkpoint_and_recover_equality() -> void:
	var s := _make_storage()
	var doc := _doc(4)
	var res := s.checkpoint_now(doc)
	if not assert_true(res.ok, str(res.error)):
		return
	assert_eq(res.generation, 1)
	assert_eq(s.status_text(4), "Saved revision 4")
	assert_eq(s.latest_world_id(), doc.world_id)
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	assert_empty_string(rec.error, "recover")
	assert_eq(rec.generation, 1)
	assert_eq(rec.skipped, [])
	var back: WorldDocument = rec.doc
	assert_eq(CanonicalEncoder.authored_hash(back), CanonicalEncoder.authored_hash(doc), "authored hash")
	assert_eq(back.document_revision, 4)
	assert_eq(back.world_id, doc.world_id)
	var again := s.checkpoint_now(doc)
	assert_true(again.ok and again.skipped, "same revision is not rewritten")
	assert_eq(_gens(doc.world_id), [1] as Array[int])


func test_io03_interrupted_checkpoint_keeps_previous_generation() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	assert_true(s.checkpoint_now(doc).ok)
	_edit(doc)
	s.fault_injection = {"stop_before_rename": true}
	var res := s.checkpoint_now(doc)
	assert_false(res.ok, "interrupted checkpoint is not reported as saved")
	var tmp := GenerationStore.generations_dir(_root, doc.world_id).path_join("00000002.tmp")
	assert_true(DirAccess.dir_exists_absolute(tmp), ".tmp generation left behind")
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq(rec.generation, 1, "previous generation recovers")
	assert_eq((rec.doc as WorldDocument).document_revision, 1)
	assert_eq(rec.skipped, [], ".tmp is ignored, not reported as corrupt")
	# Restart: configure() removes the stale .tmp and numbering continues from the last complete one.
	var s2 := _make_storage()
	assert_false(DirAccess.dir_exists_absolute(tmp), "stale .tmp removed at configure")
	var next := s2.checkpoint_now(doc)
	assert_true(next.ok, str(next.error))
	assert_eq(next.generation, 2)


func test_io04_write_failure_reports_and_keeps_old_generations() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	assert_true(s.checkpoint_now(doc).ok)
	_edit(doc)
	assert_true(s.checkpoint_now(doc).ok)
	var manifest_before := FileAccess.get_file_as_bytes(_gen_dir(doc.world_id, 2).path_join("manifest.json"))
	_edit(doc)
	for failing in ["objects.json", "regions/r_0_0.control.u32le", "manifest.json"]:
		s.fault_injection = {"fail_on_file": failing}
		var res := s.checkpoint_now(doc)
		assert_false(res.ok, "failure on " + failing)
		assert_error_contains(res.error, "injected fault", failing)
		assert_eq(s.get_save_state().state, WorldStorage.STATE_FAILED)
		var text := s.status_text(3)
		assert_true(text.begins_with("Save failed: "), text)
		assert_true(text.ends_with("Your last valid save (revision 2) is unchanged."), text)
		assert_eq(_gens(doc.world_id), [2, 1] as Array[int], "older generations untouched")
		assert_eq(StorageFs.list_dirs(GenerationStore.generations_dir(_root, doc.world_id)).size(), 2, "failed .tmp removed")
	assert_eq(FileAccess.get_file_as_bytes(_gen_dir(doc.world_id, 2).path_join("manifest.json")), manifest_before)
	assert_eq((s.recover_latest_valid(doc.world_id, _catalog).doc as WorldDocument).document_revision, 2)
	s.fault_injection = {}
	assert_true(s.checkpoint_now(doc).ok, "retry after failure")
	assert_eq(s.status_text(3), "Saved revision 3")


func test_io05_older_revision_finishing_is_not_saved_for_active_state() -> void:
	var s := _make_storage()
	var doc := _doc(5)
	assert_empty_string(s.request_checkpoint(doc))
	assert_eq(s.status_text(5), "Saving revision 5")
	_edit(doc)  # active document is now revision 6
	if not await _wait_idle():
		return
	assert_eq(s.status_text(6), "Unsaved", "revision 5 finishing must not mark revision 6 saved")
	assert_eq(s.status_text(5), "Saved revision 5")
	assert_eq(s.get_save_state().saved_revision, 5)


func test_io06_corrupt_newest_falls_back_and_reports() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	assert_true(s.checkpoint_now(doc).ok)
	_edit(doc)
	assert_true(s.checkpoint_now(doc).ok)
	_edit(doc)
	s.fault_injection = {"corrupt_after_write": "regions/r_0_0.height.f32le"}
	assert_true(s.checkpoint_now(doc).ok)
	s.fault_injection = {}
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq(rec.generation, 2, "falls back to the next valid generation")
	assert_eq((rec.doc as WorldDocument).document_revision, 2)
	assert_true(rec.doc != doc, "recovery returns a new document")
	assert_eq(rec.skipped.size(), 1, "fallback is reported")
	if rec.skipped.size() == 1:
		assert_eq(rec.skipped[0].generation, 3)
		assert_error_contains(rec.skipped[0].error, "sha256 does not match")
	assert_eq(_gens(doc.world_id), [3, 2, 1] as Array[int], "recovery neither deletes nor repairs generations")
	assert_eq(s.status_text(2), "Saved revision 2", "save state follows the recovered generation")


func test_recovery_with_no_valid_generation() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	s.fault_injection = {"corrupt_after_write": "objects.json"}
	assert_true(s.checkpoint_now(doc).ok)
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq(rec.doc, null)
	assert_error_contains(rec.error, "no valid saved generation")
	assert_eq(rec.skipped.size(), 1)
	assert_error_contains(s.recover_latest_valid("../../etc", _catalog).error, "invalid world id")


func test_pruning_keeps_three_valid_generations() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	for i in 5:
		assert_true(s.checkpoint_now(doc).ok)
		_edit(doc)
	assert_eq(_gens(doc.world_id), [5, 4, 3] as Array[int])
	# A corrupt newest generation does not count as valid, so the fallback survives pruning.
	s.fault_injection = {"corrupt_after_write": "objects.json"}
	assert_true(s.checkpoint_now(doc).ok)
	assert_eq(_gens(doc.world_id), [6, 5, 4, 3] as Array[int], "nothing pruned for a corrupt checkpoint")
	s.fault_injection = {}
	_edit(doc)
	assert_true(s.checkpoint_now(doc).ok)
	assert_eq(_gens(doc.world_id), [7, 6, 5, 4] as Array[int], "keeps 3 valid (7, 5, 4) plus the newer corrupt one")


func test_coalescing_persists_newest_without_stale_overwrite() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	var states: Array = []
	s.save_state_changed.connect(func(st: Dictionary) -> void: states.append(st))
	# Hold the worker's IO lock so all requests arrive while at most one job is in flight.
	s._io_mutex.lock()
	for i in 5:
		assert_empty_string(s.request_checkpoint(doc))
		if i < 4:
			_edit(doc)
	s._io_mutex.unlock()
	if not await _wait_idle():
		return
	var gens := _gens(doc.world_id)
	assert_true(gens.size() >= 1 and gens.size() <= 2, "coalesced to at most 2 writes, got %s" % str(gens))
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq((rec.doc as WorldDocument).document_revision, 5, "newest revision persisted")
	assert_eq(s.status_text(5), "Saved revision 5")
	assert_eq(states.back().state, WorldStorage.STATE_SAVED)
	# Race: the worker has taken revision 6 but a newer checkpoint_now (revision 7) writes first.
	# The older job must be skipped, not written as the newest generation or reported Saved.
	_edit(doc)
	var older := doc.duplicate_deep()
	s._io_mutex.lock()
	assert_empty_string(s.request_checkpoint(older))
	if not _wait_worker_took_job(s):
		s._io_mutex.unlock()
		return
	_edit(doc)
	var now := s.checkpoint_now(doc)  # Mutex is recursive, so this runs while the worker waits
	s._io_mutex.unlock()
	assert_true(now.ok and now.durable, str(now.error))
	if not await _wait_idle():
		return
	var newest := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq((newest.doc as WorldDocument).document_revision, 7, "stale job skipped")
	assert_eq(s.status_text(7), "Saved revision 7")


## Busy-waits (without letting _process run) until the worker has taken every pending job.
func _wait_worker_took_job(s: WorldStorage) -> bool:
	var t0 := Time.get_ticks_msec()
	while true:
		s._mutex.lock()
		var empty := s._pending.is_empty()
		s._mutex.unlock()
		if empty:
			return true
		if Time.get_ticks_msec() - t0 > WAIT_LIMIT_MS:
			fail("worker did not take the job")
			return false
		OS.delay_msec(1)
	return false


## Busy-waits (without letting _process apply it) until the worker has posted a result.
func _wait_result_posted(s: WorldStorage) -> bool:
	var t0 := Time.get_ticks_msec()
	while true:
		s._mutex.lock()
		var posted := not s._results.is_empty()
		s._mutex.unlock()
		if posted:
			return true
		if Time.get_ticks_msec() - t0 > WAIT_LIMIT_MS:
			fail("worker did not post a result")
			return false
		OS.delay_msec(1)
	return false


func test_async_worker_emits_on_main_thread() -> void:
	var s := _make_storage()
	var doc := _doc(9)
	var calls: Array = []
	s.save_state_changed.connect(func(st: Dictionary) -> void:
		calls.append([st.state, OS.get_thread_caller_id() == OS.get_main_thread_id()]))
	assert_empty_string(s.request_checkpoint(doc))
	if not await _wait_idle():
		return
	assert_eq(calls.front(), [WorldStorage.STATE_SAVING, true])
	assert_eq(calls.back(), [WorldStorage.STATE_SAVED, true])
	assert_eq(s.status_text(9), "Saved revision 9")
	assert_eq(_gens(doc.world_id), [1] as Array[int])
	assert_true(FileAccess.file_exists(_gen_dir(doc.world_id, 1).path_join("manifest.json")))


func test_async_failure_state() -> void:
	var s := _make_storage()
	var doc := _doc(2)
	s.fault_injection = {"fail_on_file": "objects.json"}
	assert_empty_string(s.request_checkpoint(doc))
	if not await _wait_idle():
		return
	assert_eq(s.get_save_state().state, WorldStorage.STATE_FAILED)
	assert_true(s.status_text(2).begins_with("Save failed: "), s.status_text(2))
	assert_true(s.status_text(2).ends_with("No valid save exists yet."), s.status_text(2))


func test_shutdown_drains_pending_job() -> void:
	var s := _make_storage()
	var doc := _doc(3)
	assert_empty_string(s.request_checkpoint(doc))
	s.shutdown()
	assert_eq(_gens(doc.world_id), [1] as Array[int], "pending checkpoint written before join")


func test_export_latest_round_trip() -> void:
	var s := _make_storage()
	var doc := _doc(7)
	assert_true(s.checkpoint_now(doc).ok)
	var ex := s.export_latest(doc.world_id, _catalog)
	if not assert_empty_string(ex.error, "export"):
		return
	var expected := _root.path_join(doc.world_id).path_join("exports").path_join("%s-rev-00000007.worldpoc" % doc.world_id)
	assert_eq(ex.path, expected)
	var r := WorldPackage.import_package(ex.path, _catalog)
	assert_empty_string(r[1], "import")
	if r[0] != null:
		assert_eq(CanonicalEncoder.authored_hash(r[0]), CanonicalEncoder.authored_hash(doc))
	assert_error_contains(s.export_latest(ObjectRecord.new_uuid_v4(), _catalog).error, "no valid saved generation")


## After an in-session fallback, the next edit reuses the corrupt generation's revision number
## with new content; it must be written, not skipped and reported Saved.
func test_edit_after_fallback_is_written_not_skipped() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	assert_true(s.checkpoint_now(doc).ok)
	_edit(doc)
	assert_true(s.checkpoint_now(doc).ok)
	_edit(doc)
	s.fault_injection = {"corrupt_after_write": "regions/r_0_0.height.f32le"}
	assert_true(s.checkpoint_now(doc).ok)
	s.fault_injection = {}
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	var back: WorldDocument = rec.doc
	assert_eq(back.document_revision, 2)
	var unchanged := s.checkpoint_now(back)
	assert_true(unchanged.ok and unchanged.skipped and unchanged.durable, "recovered content is already durable")
	back.get_region(Vector2i(0, 0)).heights[5] = 9.5
	back.bump_revision()  # revision 3 again, new content
	var res := s.checkpoint_now(back)
	assert_true(res.ok and not res.skipped and res.durable, "new content is written: %s" % str(res))
	assert_eq(res.generation, 4)
	assert_eq(s.status_text(3), "Saved revision 3")
	var again := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq(again.generation, 4)
	assert_eq((again.doc as WorldDocument).get_region(Vector2i(0, 0)).heights[5], 9.5, "the edit is durable")


## An older lineage of the same world (e.g. an imported older package) is newer work, not stale.
func test_lower_revision_of_new_lineage_is_written() -> void:
	var s := _make_storage()
	var doc := _doc(8)
	assert_true(s.checkpoint_now(doc).ok)
	var older := _doc(5)
	older.world_id = doc.world_id
	older.get_region(Vector2i(-1, 0)).heights[7] = 2.5
	var res := s.checkpoint_now(older)
	assert_true(res.ok and not res.skipped, str(res))
	assert_eq(s.status_text(5), "Saved revision 5")
	var rec := s.recover_latest_valid(doc.world_id, _catalog)
	assert_eq(CanonicalEncoder.authored_hash(rec.doc), CanonicalEncoder.authored_hash(older))


## A generation that passes hash checks but not recovery's content checks is never Saved, and
## prune never counts one toward the generations it keeps.
func test_invalid_content_is_not_saved_or_counted_by_prune() -> void:
	var s := _make_storage()
	var doc := _doc(1)
	assert_true(s.checkpoint_now(doc).ok)
	for i in 3:
		doc.get_region(Vector2i(0, 0)).heights[0] = 64.5
		doc.bump_revision()
		var res := s.checkpoint_now(doc)
		assert_false(res.ok, "invalid revision %d is not saved" % doc.document_revision)
		assert_error_contains(res.error, "checkpoint content is invalid")
		assert_error_contains(res.error, "64.5")
		assert_true(s.status_text(doc.document_revision).ends_with("Your last valid save (revision 1) is unchanged."))
	assert_eq(_gens(doc.world_id), [1] as Array[int])
	assert_eq(StorageFs.list_dirs(GenerationStore.generations_dir(_root, doc.world_id)).size(), 1, "no .tmp left")
	# Generations that verify by hash but fail recovery (a schema 2 file of another catalog) do not count as kept.
	var bad := _foreign_catalog(_doc(2))
	bad.world_id = doc.world_id
	for n in [2, 3, 4]:
		assert_empty_string(LegacyWorldWriter.write(_gen_dir(doc.world_id, n), bad))
	var good := _doc(10)
	good.world_id = doc.world_id
	assert_true(s.checkpoint_now(good).ok)
	assert_eq(_gens(doc.world_id), [5, 4, 3, 2, 1] as Array[int], "only 2 loadable generations: nothing pruned")
	for i in 2:
		_edit(good)
		assert_true(s.checkpoint_now(good).ok)
	assert_eq(_gens(doc.world_id), [7, 6, 5] as Array[int], "3 loadable generations kept")


## Coalescing replaces only the same world's pending job.
func test_coalescing_keeps_other_worlds_pending_job() -> void:
	var s := _make_storage()
	var x := _doc(1)
	var y := _doc(1)
	s._io_mutex.lock()
	assert_empty_string(s.request_checkpoint(x))
	_edit(x)
	assert_empty_string(s.request_checkpoint(x))
	assert_empty_string(s.request_checkpoint(y))
	s._io_mutex.unlock()
	if not await _wait_idle():
		return
	assert_eq((s.recover_latest_valid(x.world_id, _catalog).doc as WorldDocument).document_revision, 2, "X rev 2 kept")
	assert_eq((s.recover_latest_valid(y.world_id, _catalog).doc as WorldDocument).document_revision, 1, "Y saved")


## An older job's failure applied after a newer successful save must not flip the state.
func test_older_failure_after_newer_save_is_ignored() -> void:
	var s := _make_storage()
	var doc := _doc(5)
	s.fault_injection = {"fail_on_file": "objects.json"}
	assert_empty_string(s.request_checkpoint(doc))
	if not _wait_result_posted(s):
		return
	s.fault_injection = {}
	_edit(doc)
	assert_true(s.checkpoint_now(doc).ok)
	if not await _wait_idle():
		return
	assert_eq(s.get_save_state().state, WorldStorage.STATE_SAVED)
	assert_eq(s.status_text(6), "Saved revision 6")


## configure() removes what a killed export or import left behind.
func test_configure_removes_interrupted_export_and_import_leftovers() -> void:
	var s := _make_storage()
	var doc := _doc(2)
	assert_true(s.checkpoint_now(doc).ok)
	var exports := _root.path_join(doc.world_id).path_join(GenerationStore.EXPORTS_DIR)
	var partial := exports.path_join("x.worldpoc.partial")
	var kept := exports.path_join("done.worldpoc")
	var import_dir := s.import_tmp_root.path_join("abc123")
	DirAccess.make_dir_recursive_absolute(exports)
	DirAccess.make_dir_recursive_absolute(import_dir.path_join("regions"))
	for path in [partial, kept, import_dir.path_join("regions/r_0_0.height.f32le")]:
		StorageFs.write_bytes(path, PackedByteArray([1, 2, 3]))
	_make_storage()
	assert_false(FileAccess.file_exists(partial), "*.partial export removed")
	assert_true(FileAccess.file_exists(kept), "finished export kept")
	assert_false(DirAccess.dir_exists_absolute(_storage.import_tmp_root), "import temp root removed")
	assert_eq(_gens(doc.world_id), [1] as Array[int])
