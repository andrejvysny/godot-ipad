class_name WorldStorage
extends Node
## Checkpoint storage with ONE worker thread (spec §17.3, §17.4, §18.2). The main thread
## snapshots a document into plain values; the worker writes, verifies, renames, and prunes.
## Results come back through a mutex-protected queue and are applied in _process, so
## save_state_changed is always emitted on the main thread.
## Save state is honest: a revision is reported Saved only after its generation was
## verified (hashes AND the content checks recovery applies) and renamed, and only while it is
## the active revision (IO-05). Every job carries a main-thread sequence number; ordering by it
## (not by revision) decides which job is stale and which result is newest.

signal save_state_changed(state: Dictionary)

const STATE_UNSAVED := "UNSAVED"
const STATE_SAVING := "SAVING"
const STATE_SAVED := "SAVED"
const STATE_FAILED := "FAILED"

var root := "user://worlds"
var keep := 3
## Test-only fault injection, copied into each job: {fail_on_file: "objects.json"},
## {stop_before_rename: true}, {corrupt_after_write: "regions/r_0_0.height.f32le"}.
var fault_injection: Dictionary = {}
var created_with: Dictionary = {}
## Trusted catalog every checkpoint is validated against (bundled catalog when not given).
var trusted_catalog: AssetCatalog
## Extraction root for export verification; configure() removes leftovers of a killed import.
var import_tmp_root := WorldPackage.IMPORT_TMP_ROOT

var _thread: Thread
var _mutex := Mutex.new()
## Serializes all generation-directory IO (worker jobs, checkpoint_now, recovery, export).
var _io_mutex := Mutex.new()
var _semaphore := Semaphore.new()
# Guarded by _mutex:
var _pending: Array = []  # jobs, oldest first; at most one per world (coalescing)
var _results: Array = []
var _quit := false
var _last_written: Dictionary = {}  # world_id -> {seq, revision, hash} of the newest durable job

# Main thread only:
var _catalog_plain: Dictionary = {}
var _object_cache := ObjectChunkCache.new()
var _job_seq := 0
var _outstanding: Dictionary = {}  # world_id -> jobs whose result has not been applied yet
var _requested_revision := -1
var _saved_revision := -1
var _saved_seq := -1
var _failed_seq := -1
var _last_error := ""
var _world_id := ""


## Returns "" or an error. Removes leftovers of an interrupted process (stale *.tmp
## generations, *.partial exports, the import temp root); no job or import can be running yet.
func configure(root_dir: String = "user://worlds", keep_count: int = 3, trusted: AssetCatalog = null) -> String:
	if _thread != null:
		return "storage is already configured"
	root = root_dir
	keep = maxi(1, keep_count)
	if trusted != null:
		trusted_catalog = trusted
		_catalog_plain = {}
	var err := _ensure_catalog()
	if err != "":
		return err
	if created_with.is_empty():
		created_with = WorldCodec.default_created_with()
	err = StorageFs.make_dir(root)
	if err != "":
		return err
	GenerationStore.remove_stale_tmp(root)
	StorageFs.remove_tree(import_tmp_root)
	_quit = false
	_thread = Thread.new()
	_thread.start(_worker_main)
	return ""


## Queues a checkpoint of `doc`'s current revision. Only the newest pending job per world is
## kept; pending jobs of other worlds are left alone.
func request_checkpoint(doc: WorldDocument) -> String:
	if _thread == null:
		var err := configure(root, keep)
		if err != "":
			return err
	var job := _make_job(doc)
	if job.has("error"):
		return job.error
	var replaced := false
	_mutex.lock()
	for i in _pending.size():
		if _pending[i].snap.world_id == doc.world_id:
			_pending[i] = job  # the replaced job never runs, so no result will arrive for it
			replaced = true
			break
	if not replaced:
		_pending.append(job)
	_mutex.unlock()
	if not replaced:
		_outstanding[doc.world_id] = int(_outstanding.get(doc.world_id, 0)) + 1
	_requested_revision = doc.document_revision
	_semaphore.post()
	_emit_state()
	return ""


## Encodes `doc`'s objects into the incremental snapshot cache now, so the first checkpoint after a
## large world is opened does not stall an edit. Main thread.
func warm_snapshot_cache(doc: WorldDocument) -> void:
	_object_cache.chunks(doc)


## Synchronous checkpoint on the same write path (tests, app deactivation).
## Returns {ok, skipped, durable, world_id, revision, seq, generation, path, error}; `durable`
## means this exact content is in a verified generation.
func checkpoint_now(doc: WorldDocument) -> Dictionary:
	var job := _make_job(doc)
	if job.has("error"):
		return {"ok": false, "skipped": false, "durable": false, "world_id": doc.world_id if doc else "",
			"revision": doc.document_revision if doc else -1, "seq": -1, "generation": -1, "path": "",
			"error": job.error}
	var dropped := 0
	_mutex.lock()
	for i in range(_pending.size() - 1, -1, -1):
		if _pending[i].snap.world_id == doc.world_id:
			_pending.remove_at(i)  # older than this job; superseded
			dropped += 1
	_mutex.unlock()
	_finish_jobs(doc.world_id, dropped)
	var res := _execute_job(job)
	_apply_result(res)
	return res


## Newest-first recovery. Returns {doc, generation, skipped: [{generation, error}], error}.
## The returned document is new; the caller's active document is never touched.
func recover_latest_valid(world_id: String, catalog: AssetCatalog) -> Dictionary:
	if not ObjectRecord.is_uuid(world_id):
		return {"doc": null, "generation": -1, "skipped": [], "error": "invalid world id '%s'" % world_id}
	_io_mutex.lock()
	var found := GenerationStore.find_latest_valid(root, world_id, catalog)
	_io_mutex.unlock()
	if found.doc != null:
		# The recovered generation is now the durable baseline; jobs issued before this point
		# describe a document that is no longer active and become stale.
		var doc: WorldDocument = found.doc
		_job_seq += 1
		_mutex.lock()
		_last_written[world_id] = {"seq": _job_seq, "revision": doc.document_revision,
			"hash": CanonicalEncoder.authored_hash(doc)}
		_mutex.unlock()
		_switch_world(world_id)
		_saved_revision = doc.document_revision
		_saved_seq = _job_seq
		_last_error = ""
		_failed_seq = -1
		_emit_state()
	return {"doc": found.doc, "generation": found.generation, "skipped": found.skipped, "error": found.error}


func latest_world_id() -> String:
	_io_mutex.lock()
	var id := GenerationStore.latest_world_id(root)
	_io_mutex.unlock()
	return id


## Exports the newest valid generation. Returns {path, error}.
func export_latest(world_id: String, catalog: AssetCatalog) -> Dictionary:
	if not ObjectRecord.is_uuid(world_id):
		return {"path": "", "error": "invalid world id '%s'" % world_id}
	_io_mutex.lock()
	var found := GenerationStore.find_latest_valid(root, world_id, catalog)
	var out := {"path": "", "error": found.error}
	if found.doc != null:
		var rev: int = (found.doc as WorldDocument).document_revision
		var path := root.path_join(world_id).path_join(GenerationStore.EXPORTS_DIR) \
			.path_join("%s-rev-%08d.%s" % [world_id, rev, WorldConstants.PACKAGE_EXTENSION])
		out.error = WorldPackage.export_package(found.dir, path, catalog, import_tmp_root)
		out.path = path if out.error == "" else ""
	_io_mutex.unlock()
	return out


## {state: UNSAVED|SAVING|SAVED|FAILED, saving_revision, saved_revision, error}
func get_save_state() -> Dictionary:
	var state := STATE_UNSAVED
	var saving := int(_outstanding.get(_world_id, 0)) > 0
	if saving:
		state = STATE_SAVING
	elif _last_error != "":
		state = STATE_FAILED
	elif _saved_revision >= 0:
		state = STATE_SAVED
	return {"state": state, "saving_revision": _requested_revision if saving else -1,
		"saved_revision": _saved_revision, "error": _last_error}


## User-facing status for the active document revision (spec §17.4).
func status_text(current_revision: int) -> String:
	var s := get_save_state()
	match s.state:
		STATE_SAVING:
			return "Saving revision %d" % s.saving_revision
		STATE_FAILED:
			var reason := _last_error.trim_suffix(".")
			if _saved_revision < 0:
				return "Save failed: %s. No valid save exists yet." % reason
			return "Save failed: %s. Your last valid save (revision %d) is unchanged." % [reason, _saved_revision]
	if _saved_revision >= 0 and _saved_revision == current_revision:
		return "Saved revision %d" % _saved_revision
	return "Unsaved"


## True while any world has a job whose result has not been applied.
func is_busy() -> bool:
	return not _outstanding.is_empty()


func _process(_delta: float) -> void:
	_mutex.lock()
	var results := _results
	_results = []
	_mutex.unlock()
	for r in results:
		_finish_jobs(r.world_id, 1)
		_apply_result(r)


func _exit_tree() -> void:
	shutdown()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		shutdown()


## Lets the worker finish the pending job, then joins it.
func shutdown() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_semaphore.post()
	_thread.wait_to_finish()
	_thread = null


func _ensure_catalog() -> String:
	if trusted_catalog == null:
		var loaded := AssetCatalog.load_from()
		if loaded[1] != "":
			return "cannot load the trusted catalog: " + loaded[1]
		trusted_catalog = loaded[0]
	if _catalog_plain.is_empty():
		_catalog_plain = trusted_catalog.to_plain()
	return ""


func _make_job(doc: WorldDocument) -> Dictionary:
	if doc == null:
		return {"error": "no document to save"}
	if not ObjectRecord.is_uuid(doc.world_id):
		return {"error": "document world_id '%s' is not a lowercase UUID" % doc.world_id}
	if not WorldConstants.host_is_little_endian():
		return {"error": "host is not little-endian; world files cannot be written"}
	var err := _ensure_catalog()
	if err != "":
		return {"error": err}
	if created_with.is_empty():
		created_with = WorldCodec.default_created_with()
	_switch_world(doc.world_id)
	_job_seq += 1
	return {"snap": WorldCodec.snapshot(doc, created_with, _object_cache), "root": root, "keep": keep,
		"fault": fault_injection.duplicate(true), "seq": _job_seq, "catalog": _catalog_plain.duplicate(true)}


## Runs on the worker thread or (checkpoint_now) the main thread; plain values only.
func _execute_job(job: Dictionary) -> Dictionary:
	var world_id: String = job.snap.world_id
	_io_mutex.lock()
	_mutex.lock()
	var last: Dictionary = _last_written.get(world_id, {})
	_mutex.unlock()
	var res := GenerationStore.write_checkpoint(job, last)
	if res.ok and not res.skipped:
		_mutex.lock()
		_last_written[world_id] = {"seq": int(job.seq), "revision": int(res.revision),
			"hash": job.snap.authored_content_hash}
		_mutex.unlock()
	_io_mutex.unlock()
	return res


## Drains every pending job on each wake-up; on quit, drains before returning.
func _worker_main() -> void:
	while true:
		_semaphore.wait()
		while true:
			_mutex.lock()
			var job: Dictionary = _pending.pop_front() if not _pending.is_empty() else {}
			var quit := _quit
			_mutex.unlock()
			if job.is_empty():
				if quit:
					return
				break
			var res := _execute_job(job)
			_mutex.lock()
			_results.append(res)
			_mutex.unlock()


## Results are ordered by job sequence: a durable result newer than the last one sets the
## saved revision; a failure older than the newest durable save is moot; a stale skip (not
## durable) changes nothing.
func _apply_result(r: Dictionary) -> void:
	if r.world_id != _world_id:
		return
	var seq := int(r.seq)
	if r.ok and r.durable:
		if seq >= _saved_seq:
			_saved_seq = seq
			_saved_revision = int(r.revision)
		if seq >= _failed_seq:
			_last_error = ""
			_failed_seq = -1
	elif not r.ok and seq > _saved_seq:
		_last_error = r.error
		_failed_seq = maxi(_failed_seq, seq)
	_emit_state()


func _finish_jobs(world_id: String, count: int) -> void:
	var left := int(_outstanding.get(world_id, 0)) - count
	if left > 0:
		_outstanding[world_id] = left
	else:
		_outstanding.erase(world_id)


func _switch_world(world_id: String) -> void:
	if world_id == _world_id:
		return
	_world_id = world_id
	_saved_revision = -1
	_saved_seq = -1
	_failed_seq = -1
	_last_error = ""


func _emit_state() -> void:
	save_state_changed.emit(get_save_state())
