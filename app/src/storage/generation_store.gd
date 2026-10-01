class_name GenerationStore
extends RefCounted
## Checkpoint protocol on plain values (spec §17.3). Runs on the storage worker thread, so it
## never sees a WorldDocument, node, or Terrain3D object. Layout:
## <root>/<world_id>/generations/<NNNNNNNN>[.tmp]/ and <root>/<world_id>/exports/.

const GENERATIONS_DIR := "generations"
const EXPORTS_DIR := "exports"
const TMP_SUFFIX := ".tmp"
const LAST_WORLD_FILE := "last_world_id"
const PARTIAL_SUFFIX := ".partial"


static func generations_dir(root: String, world_id: String) -> String:
	return root.path_join(world_id).path_join(GENERATIONS_DIR)


static func generation_name(n: int) -> String:
	return "%08d" % n


static func _is_gen_number(s: String) -> bool:
	return s.length() == 8 and s.is_valid_int()


## Complete (renamed) generation numbers, newest first. `.tmp` directories are ignored.
static func complete_generations(gens_dir: String) -> Array[int]:
	var out: Array[int] = []
	for d in StorageFs.list_dirs(gens_dir):
		if _is_gen_number(d):
			out.append(d.to_int())
	out.sort()
	out.reverse()
	return out


static func _max_generation(gens_dir: String) -> int:
	var hi := 0
	for d in StorageFs.list_dirs(gens_dir):
		var stem := d.trim_suffix(TMP_SUFFIX)
		if _is_gen_number(stem):
			hi = maxi(hi, stem.to_int())
	return hi


## Removes what an interrupted process leaves under `root`: unfinished *.tmp generations,
## *.partial exports, and a half-written last-world pointer. Only safe while no checkpoint or
## export is running (WorldStorage calls it from configure()).
static func remove_stale_tmp(root: String) -> PackedStringArray:
	var removed := PackedStringArray()
	for world in StorageFs.list_dirs(root):
		var gens := root.path_join(world).path_join(GENERATIONS_DIR)
		for d in StorageFs.list_dirs(gens):
			if d.ends_with(TMP_SUFFIX) and StorageFs.remove_tree(gens.path_join(d)) == "":
				removed.append(gens.path_join(d))
		var exports := DirAccess.open(root.path_join(world).path_join(EXPORTS_DIR))
		if exports == null:
			continue
		for f in exports.get_files():
			if f.ends_with(PARTIAL_SUFFIX) and exports.remove(f) == OK:
				removed.append(exports.get_current_dir().path_join(f))
	var pointer_tmp := root.path_join(LAST_WORLD_FILE + TMP_SUFFIX)
	if FileAccess.file_exists(pointer_tmp) and DirAccess.remove_absolute(pointer_tmp) == OK:
		removed.append(pointer_tmp)
	return removed


## job = {snap, root, keep, fault, seq, catalog (AssetCatalog.to_plain())}.
## Returns {ok, skipped, durable, world_id, revision, seq, generation, path, error}.
## `last` = {seq, revision, hash} of the newest durable job for this world ({} if none). A job
## issued before it (lower seq) is stale and skipped without being durable; a job with the same
## revision AND authored hash is already durable and is skipped as such.
static func write_checkpoint(job: Dictionary, last: Dictionary) -> Dictionary:
	var snap: Dictionary = job.snap
	var fault: Dictionary = job.get("fault", {})
	WorldCodec.finalize_snapshot(snap)
	var res := {"ok": false, "skipped": false, "durable": false, "world_id": snap.world_id,
		"revision": int(snap.document_revision), "seq": int(job.get("seq", 0)), "generation": -1,
		"path": "", "error": ""}
	if not last.is_empty():
		var duplicate: bool = res.revision == int(last.revision) and snap.authored_content_hash == last.hash
		if res.seq < int(last.seq) or duplicate:
			res.ok = true
			res.skipped = true
			res.durable = duplicate
			return res
	if job.get("catalog", {}).is_empty():
		res.error = "no trusted catalog to validate the checkpoint"
		return res
	var catalog := AssetCatalog.from_plain(job.catalog)
	var gens := generations_dir(job.root, snap.world_id)
	var err := StorageFs.make_dir(gens)
	if err != "":
		res.error = err
		return res
	var n := _max_generation(gens) + 1
	var tmp := gens.path_join(generation_name(n) + TMP_SUFFIX)
	var final := gens.path_join(generation_name(n))
	err = WorldCodec.write_snapshot(tmp, snap, str(fault.get("fail_on_file", "")))
	if err == "":
		err = _verify_written(tmp, snap, catalog)
	if err != "":
		StorageFs.remove_tree(tmp)
		res.error = err
		return res
	if fault.get("stop_before_rename", false):
		res.error = "checkpoint interrupted before rename (injected fault)"
		return res
	if DirAccess.rename_absolute(tmp, final) != OK:
		StorageFs.remove_tree(tmp)
		res.error = "cannot rename '%s' to '%s'" % [tmp, final]
		return res
	var corrupt := str(fault.get("corrupt_after_write", ""))
	if corrupt != "":
		_corrupt_file(final.path_join(corrupt))
	_write_last_world(job.root, snap.world_id)
	prune(gens, int(job.keep), catalog, n if corrupt == "" else -1)
	res.ok = true
	res.durable = true
	res.generation = n
	res.path = final
	return res


## Reopens the written generation and applies the same checks recovery applies, so a
## generation reported Saved is one recovery can load.
static func _verify_written(dir: String, snap: Dictionary, catalog: AssetCatalog) -> String:
	var v := WorldCodec.load_verified(dir)
	if v.error != "":
		return "verification of the written checkpoint failed: " + v.error
	var m: Dictionary = v.manifest
	if m.world_id != snap.world_id or int(m.document_revision) != int(snap.document_revision) \
			or m.authored_content_hash != snap.authored_content_hash:
		return "verification of the written checkpoint failed: manifest does not match the snapshot"
	var content := WorldCodec.read_generation(dir, catalog)
	if content[1] != "":
		return "checkpoint content is invalid: " + content[1]
	return ""


## Keeps the newest `keep` generations that fully load (hashes, catalog, content) and deletes
## every complete generation older than the oldest kept one. Deletes nothing while fewer than
## `keep` loadable generations exist. `known_valid` is a generation just verified this way.
static func prune(gens_dir: String, keep: int, catalog: AssetCatalog, known_valid: int = -1) -> void:
	var valid := 0
	for n in complete_generations(gens_dir):
		var dir := gens_dir.path_join(generation_name(n))
		if valid >= keep:
			StorageFs.remove_tree(dir)
		elif n == known_valid or WorldCodec.read_generation(dir, catalog)[1] == "":
			valid += 1


## Newest-first recovery. Returns {doc, generation, dir, skipped: [{generation, error}], error}.
static func find_latest_valid(root: String, world_id: String, catalog: AssetCatalog) -> Dictionary:
	var out := {"doc": null, "generation": -1, "dir": "", "skipped": [], "error": ""}
	var gens := generations_dir(root, world_id)
	for n in complete_generations(gens):
		var dir := gens.path_join(generation_name(n))
		var r := WorldCodec.read_generation(dir, catalog)
		if r[1] == "":
			out.doc = r[0]
			out.generation = n
			out.dir = dir
			return out
		out.skipped.append({"generation": n, "error": r[1]})
	out.error = "no valid saved generation for world %s" % world_id
	if not out.skipped.is_empty():
		out.error += " (%d generation(s) failed validation)" % out.skipped.size()
	return out


## World most recently checkpointed under `root`, or "".
static func latest_world_id(root: String) -> String:
	var read := StorageFs.read_bytes(root.path_join(LAST_WORLD_FILE), 64)
	if read[1] == "":
		var id := (read[0] as PackedByteArray).get_string_from_utf8().strip_edges()
		if ObjectRecord.is_uuid(id) and not complete_generations(generations_dir(root, id)).is_empty():
			return id
	var best := ""
	var best_time := -1
	for world in StorageFs.list_dirs(root):
		var gens := complete_generations(generations_dir(root, world))
		if not ObjectRecord.is_uuid(world) or gens.is_empty():
			continue
		var t := FileAccess.get_modified_time(generations_dir(root, world).path_join(generation_name(gens[0])).path_join(WorldCodec.MANIFEST_FILE))
		if t > best_time:
			best_time = t
			best = world
	return best


static func _write_last_world(root: String, world_id: String) -> void:
	var tmp := root.path_join(LAST_WORLD_FILE + TMP_SUFFIX)
	if StorageFs.write_bytes(tmp, world_id.to_utf8_buffer()) == "":
		DirAccess.rename_absolute(tmp, root.path_join(LAST_WORLD_FILE))


## Fault injection (IO-06): flips the first byte of an already written file.
static func _corrupt_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null or f.get_length() == 0:
		return
	var b := f.get_8()
	f.seek(0)
	f.store_8(b ^ 0xFF)
	f.close()
