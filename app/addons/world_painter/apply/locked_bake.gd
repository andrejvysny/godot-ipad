class_name LockedBake
extends RefCounted
## `bake --locked` (ADR 0017 A7): rebuilds the generated directory of an installed generation from its tracked source
## and the installed locked deliveries, after a checkout or restore. It refuses on any input mismatch (source hash,
## consumer profile, toolchain pins, dependencies) and never touches modified generated content: an engine or profile
## change is a new Apply, not a silent rebuild.

const Coordinator := preload("res://addons/assetstudio/project/as_mutation_coordinator.gd")

var ctx: ApplyContext


func _init(p_ctx: ApplyContext) -> void:
	ctx = p_ctx


## {ok, error, unchanged, world_id, dir_name, stats}.
func bake(world_id: String, dir_name: String = "") -> Dictionary:
	var name := dir_name if dir_name != "" else _active_dir(world_id)
	if name == "":
		return _fail("world %s has no accepted generation" % world_id)
	var review := ApplyReview.for_existing(world_id, name, ctx)
	if not review.blockers.is_empty():
		return _fail(review.blockers[0])
	var mismatch := review.input_mismatch()
	if mismatch != "":
		return _fail(mismatch)
	var generated := ApplyLayout.abs_of(review.destination).path_join(ApplyLayout.GENERATED_DIR)
	var state := ApplyReceipt.generated_state(name, generated)
	if state.state == "intact":
		return {"ok": true, "error": "", "unchanged": true, "world_id": world_id, "dir_name": name}
	if state.state != "absent":
		return _fail("generated content of %s is %s: %s" % [name.left(12), state.state, state.detail])
	return _rebuild(review)


func _rebuild(review: ApplyReview) -> Dictionary:
	var stage := StorageFs.random_hex(8)
	var identity := ApplyTransaction._identity(review)
	var baked := ApplyStager.bake_generated(review.doc, stage, review.destination, ctx, identity, review.profile)
	var staged := ApplyLayout.abs_of(ApplyLayout.staging_res(stage))
	if baked.error == "":
		baked.error = _expect_content(review, baked.content)
	var err: String = baked.error
	if err == "":
		err = _install(review, stage)
	StorageFs.remove_tree(staged)
	if err != "":
		return _fail(err)
	return {"ok": true, "error": "", "unchanged": false, "world_id": review.world_id,
		"dir_name": review.dir_name, "stats": baked.stats}


func _install(review: ApplyReview, stage: String) -> String:
	var c: RefCounted = Coordinator.new(ctx.project_root)
	var opened: RefCounted = c.call("open", "world_bake")
	if not opened.ok:
		return str(opened.message)
	c.set("summary", {"kind": "world_bake", "world_id": review.world_id, "generation_id": review.generation_id})
	c.call("add_dir", ApplyLayout.staging_rel(stage).path_join(ApplyLayout.GENERATED_DIR),
			ApplyLayout.rel_of(review.destination).path_join(ApplyLayout.GENERATED_DIR))
	c.call("add_write", ApplyReceipt.installation_rel(review.dir_name), ApplyReceipt.installation_bytes(
			ApplyLayout.abs_of(ApplyLayout.staging_res(stage)).path_join(ApplyLayout.GENERATED_DIR), review.generation_id))
	var result: RefCounted = c.call("commit")
	c.call("close")
	return "" if result.ok else str(result.message)


func _expect_content(review: ApplyReview, content: Dictionary) -> String:
	var parsed := ApplyReceipt.read(ApplyLayout.abs_of(review.destination))
	if parsed[1] != "":
		return parsed[1]
	var recorded := SnapshotIdentity.profile_canonical(parsed[0].content).get_string_from_utf8()
	var rebuilt := SnapshotIdentity.profile_canonical(content).get_string_from_utf8()
	return "" if recorded == rebuilt else "the rebuilt world differs from the recorded content: %s vs %s" % [rebuilt, recorded]


func _active_dir(world_id: String) -> String:
	var binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id)))
	return SnapshotIdentity.dir_name(str(binding.generation_id)) if not binding.is_empty() else ""


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}
