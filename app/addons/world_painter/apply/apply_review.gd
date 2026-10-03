class_name ApplyReview
extends RefCounted
## The candidate of an Apply (ADR 0017 A1-A3): the frozen snapshot copied into editor-owned staging, re-validated,
## its identities and destination, the dependency changes against the project lock and every reason Apply must refuse.
## Building a review changes nothing outside `.world_painter/staging/<id>/`.

var staging_id := ""
var doc: WorldDocument
var world_id := ""
var revision := 0
var authored_hash := ""
var source_snapshot_hash := ""
var generation_id := ""  # full 64 hex
var dir_name := ""
var profile := {}
var profile_hash := ""
var pins := {}
var destination := ""  # res:// directory of the generation
var dependencies: Array[Dictionary] = []  # {asset_key, name, binding_ids, change, state, detail, deliveries}
var missing := PackedStringArray()
var blockers := PackedStringArray()
## Reasons that only an explicit discard of the modified generated content lifts.
var soft_blockers := PackedStringArray()
var notes := PackedStringArray()
## The currently active generation of this world: {generation_id, dir_name, generated_state, detail}; empty when none.
var active := {}
## The same generation is already active and intact: Apply has nothing to do.
var already_applied := false
## The destination directory already exists on disk (an earlier Apply of the same inputs).
var destination_exists := false
## Set for the review of an installed generation (rollback, locked bake): its tracked source directory.
var source_override_abs := ""


func staged_dir_abs() -> String:
	return ApplyLayout.project_root().path_join(ApplyLayout.staging_rel(staging_id))


func staged_source_abs() -> String:
	return source_override_abs if source_override_abs != "" else staged_dir_abs().path_join(ApplyLayout.SOURCE_DIR)


func can_apply(discard_modified: bool = false) -> bool:
	return blockers.is_empty() and (soft_blockers.is_empty() or discard_modified)


## [{asset_key, binding_ids, deliveries}] sorted by key: the tracked part of the dependency record.
func dependency_pins() -> Array:
	var out: Array = []
	for row in dependencies:
		out.append({"asset_key": row.asset_key, "binding_ids": row.binding_ids, "deliveries": row.deliveries})
	return out


func lock_keys() -> PackedStringArray:
	var keys := PackedStringArray()
	for row in dependencies:
		keys.append(row.asset_key)
	return keys


## Lines of the dock's review panel.
func summary_lines() -> PackedStringArray:
	var lines := PackedStringArray(["World %s" % world_id, "Revision %d   authored hash %s" % [revision, authored_hash.left(16)],
		"Source snapshot %s   generation %s" % [source_snapshot_hash.left(16), dir_name.left(16)], "Destination %s" % destination])
	for row in dependencies:
		lines.append("Dependency %s: %s (%s)" % [row.name, row.change, row.state])
	if dependencies.is_empty():
		lines.append("No AssetStudio dependencies (bundled assets only)")
	for m in missing:
		lines.append("Missing desktop delivery: " + m)
	for b in blockers:
		lines.append("Blocked: " + b)
	for b in soft_blockers:
		lines.append("Blocked unless discarded: " + b)
	if already_applied:
		lines.append("This generation is already the accepted one.")
	lines.append_array(notes)
	return lines


## Copies the frozen generation at `frozen_dir` into staging, re-validates it and reviews it. `expected` may carry the
## hashes the child announced ({authored_hash, source_snapshot_hash}); a mismatch means the snapshot changed in transit.
static func build(frozen_dir: String, expected: Dictionary, ctx: ApplyContext) -> ApplyReview:
	ctx.deliveries.reload()
	var review := ApplyReview.new()
	review.staging_id = StorageFs.random_hex(8)
	var err := review._stage_source(frozen_dir, ctx)
	if err == "":
		err = review._validate(expected, ctx)
	if err != "":
		review.blockers.append(err)
		return review
	review._identify(ctx)
	review._review_dependencies(ctx)
	review._preflight(ctx)
	return review


## The review of an installed generation, read from its tracked apply_receipt.json and source/ (rollback and
## `bake --locked`). Identities come from the receipt, never from this machine.
static func for_existing(p_world_id: String, p_dir_name: String, ctx: ApplyContext) -> ApplyReview:
	ctx.deliveries.reload()
	var review := ApplyReview.new()
	review.world_id = p_world_id
	review.dir_name = p_dir_name
	var root_res := ApplyLayout.accepted_root()
	review.destination = ApplyLayout.generation_res(p_world_id, p_dir_name, root_res)
	var gen_abs := ApplyLayout.abs_of(review.destination)
	review.destination_exists = DirAccess.dir_exists_absolute(gen_abs)
	review.source_override_abs = gen_abs.path_join(ApplyLayout.SOURCE_DIR)
	var err := review._load_receipt(gen_abs) if review.destination_exists else "generation %s of world %s is not installed" % [p_dir_name.left(12), p_world_id]
	if err == "":
		err = review._reload_source(ctx)
	if err != "":
		review.blockers.append(err)
		return review
	review._review_dependencies(ctx)
	var binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(p_world_id, root_res)))
	if not binding.is_empty():
		review._check_active(binding)
	review._check_destination()
	return review


func _load_receipt(gen_abs: String) -> String:
	var parsed := ApplyReceipt.read(gen_abs)
	if parsed[1] != "":
		return parsed[1]
	var r: Dictionary = parsed[0]
	if r.world_id != world_id or SnapshotIdentity.dir_name(str(r.generation_id)) != dir_name:
		return "apply_receipt.json does not belong to generation %s of world %s" % [dir_name.left(12), world_id]
	revision = int(r.document_revision)
	authored_hash = r.authored_hash
	source_snapshot_hash = r.source_snapshot_hash
	generation_id = r.generation_id
	profile = r.consumer_profile
	profile_hash = r.consumer_profile_hash
	pins = r.pins
	notes.append("receipt: %d dependencies" % (r.dependencies as Array).size())
	return ""


func _reload_source(ctx: ApplyContext) -> String:
	var hashed := SnapshotIdentity.source_snapshot_hash(source_override_abs)
	if hashed[1] != "":
		return hashed[1]
	if hashed[0] != source_snapshot_hash:
		return "the tracked source of generation %s changed (source snapshot hash differs from its receipt)" % dir_name.left(12)
	var read := WorldCodec.read_generation(source_override_abs, ctx.catalog)
	if read[1] != "":
		return "the tracked source does not validate: " + str(read[1])
	doc = read[0]
	if CanonicalEncoder.authored_hash(doc) != authored_hash:
		return "the tracked source does not reproduce the authored hash of its receipt"
	return ""


## "" when this machine still matches every recorded input of the installed generation (consumer profile, toolchain
## pins, dependencies); otherwise the first difference. A change is a new Apply, never a silent rebuild.
func input_mismatch() -> String:
	var current := SnapshotIdentity.consumer_profile()
	if SnapshotIdentity.profile_hash(current) != profile_hash:
		return "the consumer profile changed since the Apply (new Apply required): %s" % JSON.stringify(current)
	var current_pins := SnapshotIdentity.current_pins()
	for key: String in SnapshotIdentity.PIN_KEYS:
		if str(current_pins[key]) != str(pins.get(key, "")):
			return "pin %s changed since the Apply (new Apply required)" % key
	if not missing.is_empty():
		return "locked dependencies are unavailable: " + missing[0]
	return ""


func discard_staging() -> void:
	if staging_id != "":
		StorageFs.remove_tree(staged_dir_abs())


func _stage_source(frozen_dir: String, ctx: ApplyContext) -> String:
	var verified := WorldCodec.load_verified(frozen_dir)
	if verified.error != "":
		return "the frozen snapshot is not a valid generation: " + verified.error
	var dest := staged_source_abs()
	var files: Dictionary = verified.files
	files[WorldCodec.MANIFEST_FILE] = FileAccess.get_file_as_bytes(frozen_dir.path_join(WorldCodec.MANIFEST_FILE))
	for rel: String in files:
		var err := StorageFs.make_dir(dest.path_join(rel).get_base_dir())
		err = err if err != "" else StorageFs.write_bytes(dest.path_join(rel), files[rel])
		if err != "":
			return err
	return ""


func _validate(expected: Dictionary, ctx: ApplyContext) -> String:
	var read := WorldCodec.read_generation(staged_source_abs(), ctx.catalog)
	if read[1] != "":
		return "the snapshot does not validate: " + str(read[1])
	doc = read[0]
	world_id = doc.world_id
	revision = doc.document_revision
	authored_hash = CanonicalEncoder.authored_hash(doc)
	var hashed := SnapshotIdentity.source_snapshot_hash(staged_source_abs())
	if hashed[1] != "":
		return hashed[1]
	source_snapshot_hash = hashed[0]
	for key: String in ["authored_hash", "source_snapshot_hash"]:
		if str(expected.get(key, "")) != "" and str(expected[key]) != get(key):
			return "the staged snapshot differs from the frozen one (%s)" % key
	return ""


func _identify(_ctx: ApplyContext) -> void:
	profile = SnapshotIdentity.consumer_profile()
	profile_hash = SnapshotIdentity.profile_hash(profile)
	pins = SnapshotIdentity.current_pins()
	generation_id = SnapshotIdentity.generation_id(source_snapshot_hash, profile_hash, pins)
	dir_name = SnapshotIdentity.dir_name(generation_id)
	var root_error := ApplyLayout.root_error(str(profile.accepted_world_root))
	if root_error != "":
		blockers.append(root_error)
	destination = ApplyLayout.generation_res(world_id, dir_name, str(profile.accepted_world_root))
	destination_exists = DirAccess.dir_exists_absolute(ApplyLayout.abs_of(destination))


func _review_dependencies(ctx: ApplyContext) -> void:
	var by_key := {}
	for id in doc.assets.referenced_ids(doc):
		var binding := doc.assets.get_binding(id)
		if binding != null and not binding.is_bundled():
			var row: Dictionary = by_key.get(binding.asset_key, {})
			if row.is_empty():
				row = _row_of(binding, ctx)
				by_key[binding.asset_key] = row
			(row.binding_ids as Array).append(id)
	var keys := PackedStringArray(by_key.keys())
	keys.sort()
	for key in keys:
		var row: Dictionary = by_key[key]
		dependencies.append(row)
		if row.state != ApplyDeliveries.OK:
			missing.append("%s - %s" % [row.name, row.detail])
			blockers.append("a required desktop delivery is unavailable: %s (asset key %s)" % [row.name, key.left(12)])


static func _row_of(binding: AssetBinding, ctx: ApplyContext) -> Dictionary:
	var state := ctx.deliveries.state_of(binding)
	var change := "new"
	if ctx.deliveries.lock != null:
		var locked: Variant = (ctx.deliveries.lock.call("dependencies") as Dictionary).get(binding.asset_key)
		if locked != null:
			change = "unchanged" if state.state == ApplyDeliveries.OK else "changed"
	return {"asset_key": binding.asset_key, "name": str(binding.asset_ref.get("asset_id", binding.asset_key.left(12))),
		"binding_ids": [], "change": change, "state": state.state, "detail": state.detail,
		"deliveries": binding.deliveries.duplicate(true)}


func _preflight(ctx: ApplyContext) -> void:
	if ctx.importing():
		blockers.append("an import or filesystem scan is still running")
	var world_dir := ApplyLayout.world_res(world_id, str(profile.accepted_world_root))
	for scene in ctx.unsaved():
		if scene.begins_with(world_dir):
			blockers.append("the scene %s has unsaved changes" % scene)
	var binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id, str(profile.accepted_world_root))))
	if not binding.is_empty():
		_check_active(binding)
	if destination_exists:
		_check_destination()


func _check_active(binding: Dictionary) -> void:
	var active_dir := SnapshotIdentity.dir_name(str(binding.generation_id))
	var gen_abs := ApplyLayout.abs_of(ApplyLayout.generation_res(world_id, active_dir, str(profile.accepted_world_root)))
	var state := ApplyReceipt.generated_state(active_dir, gen_abs.path_join(ApplyLayout.GENERATED_DIR))
	active = {"generation_id": binding.generation_id, "dir_name": active_dir, "generated_state": state.state,
		"detail": state.detail}
	if state.state == "modified" or state.state == "unverifiable":
		soft_blockers.append("generated content of the accepted generation %s: %s" % [active_dir.left(12), state.detail])
	already_applied = binding.generation_id == generation_id and state.state == "intact" and destination_exists


func _check_destination() -> void:
	var state := ApplyReceipt.generated_state(dir_name, ApplyLayout.abs_of(destination).path_join(ApplyLayout.GENERATED_DIR))
	if state.state == "modified" or state.state == "unverifiable":
		soft_blockers.append("generated content already at the destination: %s" % state.detail)
	elif state.state == "absent":
		notes.append("The destination exists without generated content; it is rebuilt.")
