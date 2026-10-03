class_name ApplyTransaction
extends RefCounted
## Installs an accepted generation through one AssetStudio coordinator transaction (ADR 0017 A5): the staged
## generation directory, the tracked binding.tres and the project lock with the world's generation root move together
## or not at all. Rollback is the same kind of transaction without the directory. Recovery runs on plugin enable.

const Coordinator := preload("res://addons/assetstudio/project/as_mutation_coordinator.gd")
const ProjectLock := preload("res://addons/assetstudio/project/as_project_lock.gd")

var ctx: ApplyContext
## `(label: String) -> void`, called at the phases of an Apply.
var progress := Callable()
## Wait one frame between phases (editor UI); tests and the CLI leave it off.
var yield_frames := false


func _init(p_ctx: ApplyContext) -> void:
	ctx = p_ctx


## {ok, error, unchanged, generation_id, dir_name, stats, post_verify}. A coroutine: always `await` it.
func apply(review: ApplyReview, discard_modified: bool = false) -> Dictionary:
	if review.already_applied:
		review.discard_staging()
		return {"ok": true, "error": "", "unchanged": true, "generation_id": review.generation_id, "dir_name": review.dir_name}
	if not review.can_apply(discard_modified):
		var reasons := review.blockers + review.soft_blockers
		return _fail(reasons[0] if not reasons.is_empty() else "the review is not applicable")
	var reuse := _reusable(review)
	var stats := {}
	if not reuse:
		await _phase("Baking the world")
		var baked := ApplyStager.bake_generated(review.doc, review.staging_id, review.destination, ctx,
				_identity(review), review.profile)
		if baked.error != "":
			review.discard_staging()
			return _fail(baked.error)
		stats = baked.stats
		var err := StorageFs.write_bytes(review.staged_dir_abs().path_join(ApplyLayout.RECEIPT_FILE),
				ApplyReceipt.encode(ApplyReceipt.build(review, baked.content)))
		if err != "":
			review.discard_staging()
			return _fail(err)
	await _phase("Installing the generation")
	var committed := _switch(review, reuse)
	if not committed.ok:
		if committed.get("code", "") != "simulated_crash":
			review.discard_staging()
		return committed
	review.discard_staging()
	await _phase("Verifying the installed world")
	return _finish(review, stats)


## Points binding.tres and the lock root of `dir_name` back at an earlier generation of `world_id`.
func rollback(world_id: String, dir_name: String, discard_modified: bool = false) -> Dictionary:
	var review := ApplyReview.for_existing(world_id, dir_name, ctx)
	if not review.blockers.is_empty():
		return _fail(review.blockers[0])
	if review.active.get("dir_name", "") == dir_name:
		return {"ok": true, "error": "", "unchanged": true, "generation_id": review.generation_id, "dir_name": dir_name}
	if not review.can_apply(discard_modified):
		return _fail(review.soft_blockers[0])
	var generated := ApplyLayout.abs_of(review.destination).path_join(ApplyLayout.GENERATED_DIR)
	if not DirAccess.dir_exists_absolute(generated):
		var rebuilt := LockedBake.new(ctx).bake(world_id, dir_name)
		if not rebuilt.ok:
			return _fail("the generated content of the earlier generation is absent and cannot be rebuilt: " + rebuilt.error)
	var committed := _switch(review, true)
	if committed.ok:
		committed["dir_name"] = dir_name
		committed["generation_id"] = review.generation_id
	return committed


## Complete generations of `world_id`, newest installation first: {dir_name, generation_id, revision, authored_hash,
## active, generated_state}.
func list_generations(world_id: String, root_res: String = "") -> Array[Dictionary]:
	var root := root_res if root_res != "" else ApplyLayout.accepted_root()
	var revisions := ApplyLayout.abs_of(ApplyLayout.world_res(world_id, root).path_join(ApplyLayout.REVISIONS))
	var binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id, root)))
	var out: Array[Dictionary] = []
	for dir_name in DirAccess.get_directories_at(revisions):
		var parsed := ApplyReceipt.read(revisions.path_join(dir_name))
		if parsed[1] != "" or not ApplyLayout.is_generation_dir_name(dir_name):
			continue
		var receipt: Dictionary = parsed[0]
		var state := ApplyReceipt.generated_state(dir_name, revisions.path_join(dir_name).path_join(ApplyLayout.GENERATED_DIR))
		out.append({"dir_name": dir_name, "generation_id": receipt.generation_id, "revision": int(receipt.document_revision),
			"authored_hash": receipt.authored_hash, "active": binding.get("generation_id", "") == receipt.generation_id,
			"generated_state": state.state, "installed_unix": state.installed_unix})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.installed_unix > b.installed_unix or (a.installed_unix == b.installed_unix and a.revision > b.revision))
	return out


## Completes or rolls back an interrupted transaction and removes abandoned staging (plugin enable, before run/export),
## except the staging directories named in `keep` (a review the user is looking at). {ok, notes, error}.
static func recover(project_root: String = "", keep: PackedStringArray = PackedStringArray()) -> Dictionary:
	var root := project_root if project_root != "" else ApplyLayout.project_root()
	var c: RefCounted = Coordinator.new(root)
	var opened: RefCounted = c.call("open", "world_recover")
	if not opened.ok:
		return {"ok": false, "notes": PackedStringArray(), "error": str(opened.message)}
	var staging := root.path_join(ApplyLayout.STAGING_REL)
	for id in StorageFs.list_dirs(staging):
		if not keep.has(id):
			StorageFs.remove_tree(staging.path_join(id))
	DirAccess.remove_absolute(staging)  # only when empty
	var notes: PackedStringArray = c.get("notes")
	c.call("close")
	return {"ok": true, "notes": notes, "error": ""}


func _switch(review: ApplyReview, reuse: bool) -> Dictionary:
	var c: RefCounted = Coordinator.new(ctx.project_root)
	var opened: RefCounted = c.call("open", "world_apply")
	if not opened.ok:
		return _fail(str(opened.message))
	var lock := _lock_bytes(review)
	if lock[1] != "":
		c.call("close")
		return _fail(lock[1])
	c.set("summary", {"kind": "world_apply", "world_id": review.world_id, "generation_id": review.generation_id})
	var root_res := str(review.profile.accepted_world_root)
	if not reuse:
		c.call("add_dir", ApplyLayout.staging_rel(review.staging_id), ApplyLayout.rel_of(review.destination),
				CanonicalEncoder.sha256_hex(FileAccess.get_file_as_bytes(review.staged_dir_abs().path_join(ApplyLayout.RECEIPT_FILE))))
		c.call("add_write", ApplyReceipt.installation_rel(review.dir_name), ApplyReceipt.installation_bytes(
				review.staged_dir_abs().path_join(ApplyLayout.GENERATED_DIR), review.generation_id))
	var scene_res := review.destination.path_join(ApplyLayout.GENERATED_DIR).path_join(ApplyLayout.WORLD_SCENE)
	c.call("add_write", ApplyLayout.rel_of(ApplyLayout.binding_res(review.world_id, root_res)),
			ApplyBindingFile.encode(review.world_id, review.source_snapshot_hash, review.authored_hash, review.generation_id, scene_res))
	if lock[2]:
		c.call("add_write", ApplyLayout.LOCK_FILE, lock[0])
	var result: RefCounted = c.call("commit")
	c.call("close")
	if not result.ok:
		return {"ok": false, "error": str(result.message), "code": str(result.code)}
	return {"ok": true, "error": ""}


## [bytes, error, changed]: the project lock with this generation's root added (every other root untouched).
func _lock_bytes(review: ApplyReview) -> Array:
	var keys := review.lock_keys()
	if keys.is_empty():
		return [PackedByteArray(), "", false]
	var raw := FileAccess.get_file_as_bytes(ctx.project_root.path_join(ApplyLayout.LOCK_FILE))
	var parsed: RefCounted = ProjectLock.parse_bytes(raw)
	if raw.is_empty() or not parsed.ok:
		return [PackedByteArray(), "the project lock cannot be read: %s" % (str(parsed.message) if not raw.is_empty() else "missing"), false]
	var lock: RefCounted = parsed.value
	lock.call("add_root", "world_generation", ApplyLayout.lock_owner_id(review.world_id, review.dir_name), Array(keys))
	var encoded: RefCounted = lock.call("to_bytes")
	if not encoded.ok:
		return [PackedByteArray(), str(encoded.message), false]
	return [encoded.value, "", encoded.value != raw]


func _finish(review: ApplyReview, stats: Dictionary) -> Dictionary:
	var generated := review.destination.path_join(ApplyLayout.GENERATED_DIR)
	var verify := WorldSceneCheck.compare(WorldSceneCheck.summarize(generated.path_join(ApplyLayout.WORLD_SCENE), ctx.tree),
			review.doc, generated.path_join("terrain"))
	return {"ok": true, "error": "", "unchanged": false, "generation_id": review.generation_id, "dir_name": review.dir_name,
		"stats": stats, "post_verify": "; ".join(verify.slice(0, 3))}


func _reusable(review: ApplyReview) -> bool:
	if not review.destination_exists:
		return false
	var parsed := ApplyReceipt.read(ApplyLayout.abs_of(review.destination))
	if parsed[1] != "" or parsed[0].generation_id != review.generation_id:
		return false
	return ApplyReceipt.generated_state(review.dir_name, ApplyLayout.abs_of(review.destination).path_join(ApplyLayout.GENERATED_DIR)).state == "intact"


static func _identity(review: ApplyReview) -> Dictionary:
	return {"world_id": review.world_id, "authored_hash": review.authored_hash,
		"source_snapshot_hash": review.source_snapshot_hash, "generation_id": review.generation_id}


func _phase(label: String) -> void:
	if progress.is_valid():
		progress.call(label)
	if yield_frames and ctx.tree != null:
		await ctx.tree.process_frame


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}
