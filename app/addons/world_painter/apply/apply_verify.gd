class_name ApplyVerify
extends RefCounted
## `verify --offline` (ADR 0017 A7): for every accepted world, its tracked receipt inputs and dependencies are
## present and unchanged: source snapshot, consumer profile, toolchain pins, installed deliveries and the project
## lock root, plus the generated content against its installation receipt. Pure file inspection, no network.

var ctx: ApplyContext


func _init(p_ctx: ApplyContext) -> void:
	ctx = p_ctx


## {ok, worlds: [{world_id, generation, ok, problems}], problems}.
func verify_all() -> Dictionary:
	ctx.deliveries.reload()
	var root := ApplyLayout.abs_of(ApplyLayout.accepted_root())
	var results: Array = []
	var problems := PackedStringArray()
	for world_id in (DirAccess.get_directories_at(root) if DirAccess.dir_exists_absolute(root) else PackedStringArray()):
		if not ApplyLayout.is_world_id(world_id):
			continue
		var one := verify_world(world_id)
		results.append(one)
		for p: String in one.problems:
			problems.append("%s: %s" % [world_id, p])
	return {"ok": problems.is_empty(), "worlds": results, "problems": Array(problems)}


func verify_world(world_id: String) -> Dictionary:
	var out := {"world_id": world_id, "generation": "", "ok": true, "problems": []}
	var binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id)))
	if binding.is_empty():
		return _problem(out, "binding.tres is missing or is not a World Painter binding")
	var dir_name := SnapshotIdentity.dir_name(str(binding.generation_id))
	out.generation = dir_name
	var review := ApplyReview.for_existing(world_id, dir_name, ctx)
	for b in review.blockers:
		_problem(out, b)
	if not review.blockers.is_empty():
		return out
	var mismatch := review.input_mismatch()
	if mismatch != "":
		_problem(out, mismatch)
	_check_pointer(out, binding, review)
	_check_lock_root(out, review)
	_check_generated(out, review)
	return out


func _check_pointer(out: Dictionary, binding: Dictionary, review: ApplyReview) -> void:
	var scene := review.destination.path_join(ApplyLayout.GENERATED_DIR).path_join(ApplyLayout.WORLD_SCENE)
	if binding.scene != scene or binding.generation_id != review.generation_id \
			or binding.authored_hash != review.authored_hash or binding.source_snapshot_hash != review.source_snapshot_hash:
		_problem(out, "binding.tres does not match the receipt of generation %s" % review.dir_name.left(12))


func _check_lock_root(out: Dictionary, review: ApplyReview) -> void:
	var keys := review.lock_keys()
	if keys.is_empty() or ctx.deliveries.lock == null:
		return
	var owner := ApplyLayout.lock_owner_id(review.world_id, review.dir_name)
	for root: Dictionary in ctx.deliveries.lock.doc["roots"]:
		if root.owner_kind == "world_generation" and root.owner_id == owner:
			if Array(keys) != root.asset_keys and Array(keys).hash() != (root.asset_keys as Array).hash():
				_problem(out, "the lock root %s lists other asset keys than the receipt" % owner)
			return
	_problem(out, "the project lock has no world_generation root %s" % owner)


func _check_generated(out: Dictionary, review: ApplyReview) -> void:
	var gen := ApplyLayout.abs_of(review.destination)
	var state := ApplyReceipt.generated_state(review.dir_name, gen.path_join(ApplyLayout.GENERATED_DIR))
	if state.state == "absent":
		_problem(out, "generated content is absent (run bake --locked)")
	elif state.state != "intact":
		_problem(out, "generated content is %s: %s" % [state.state, state.detail])
	elif not FileAccess.file_exists(gen.path_join(ApplyLayout.GENERATED_DIR).path_join(ApplyLayout.WORLD_SCENE)):
		_problem(out, "generated/world.tscn is missing")


static func _problem(out: Dictionary, message: String) -> Dictionary:
	out.ok = false
	(out.problems as Array).append(message)
	return out
