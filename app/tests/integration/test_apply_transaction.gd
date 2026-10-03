extends ApplyProjectCase
## Apply (ADR 0017 A3-A6, E2E-12..15): staging, the single coordinator transaction, crash recovery at every step,
## preservation of game siblings, refusal on modified generated content, rollback and the mount.

const AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")
const Lock := preload("res://addons/assetstudio/project/as_project_lock.gd")


func _stub_scene() -> PackedScene:
	var dir := world_dir().path_join("_stub")
	DirAccess.make_dir_recursive_absolute(dir)
	var node := Node3D.new()
	node.name = "Prop"
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = BoxMesh.new()
	node.add_child(mesh)
	mesh.owner = node
	var packed := PackedScene.new()
	packed.pack(node)
	node.free()
	assert_eq(ResourceSaver.save(packed, root_res.path_join("_stub/prop.tscn")), OK)
	return load(root_res.path_join("_stub/prop.tscn")) as PackedScene


## A world with one remote object, its delivery installed and locked, and a stub scene standing in for the GLB import.
func _remote_world() -> Dictionary:
	var doc := ApplyTestKit.make_doc(catalog)
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	var binding_id := ApplyTestKit.add_remote_object(doc, item, 20.0, -20.0)
	installed_keys.append(item.binding.asset_key)
	ApplyTestKit.install_delivery(project, item)
	refresh_ctx()
	ctx.deliveries.overrides[binding_id] = _stub_scene()
	return {"doc": doc, "item": item, "binding_id": binding_id}


func _next_revision(doc: WorldDocument, extra_objects: int = 1) -> WorldDocument:
	var next := doc.duplicate_deep()
	next.document_revision += 1
	for i in extra_objects:
		next.put_object(ApplyTestKit._record(next, ApplyTestKit.BOULDER, -50.0 + 7.0 * next.document_revision, 30.0, 0.3, 1.0))
	return next


func _summary_of(dir_name: String) -> Dictionary:
	return WorldSceneCheck.summarize(ApplyLayout.generation_res(binding_world, dir_name).path_join("generated/world.tscn"), tree)


var binding_world := ""


func test_apply_installs_a_complete_generation_and_points_the_binding_at_it() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	binding_world = doc.world_id
	var review := review_of(doc)
	assert_eq(review.blockers, PackedStringArray(), "no blockers")
	assert_true(review.can_apply(), "applicable")
	assert_eq(review.revision, 7)
	assert_true(review.destination.begins_with(root_res), "destination below the accepted root: " + review.destination)
	var result := await apply_review(review)
	assert_true(result.ok, str(result.get("error")))
	assert_eq(str(result.get("post_verify", "?")), "", "the installed world reproduces the snapshot")
	var binding := binding_of(doc.world_id)
	assert_eq(binding.generation_id, review.generation_id)
	assert_eq(binding.authored_hash, review.authored_hash)
	assert_eq(binding.source_snapshot_hash, review.source_snapshot_hash)
	var gen := ApplyLayout.abs_of(review.destination)
	for rel in ["source/manifest.json", "source/objects.json", "apply_receipt.json", "generated/world.tscn", "generated/terrain/assets.tres"]:
		assert_true(FileAccess.file_exists(gen.path_join(rel)), rel)
	assert_false(FileAccess.get_file_as_string(gen.path_join("generated/world.tscn")).contains(".world_painter"), "no staged path left")
	assert_false(DirAccess.dir_exists_absolute(project.path_join(".world_painter/staging/" + review.staging_id)), "staging is gone")
	assert_eq(ApplyReceipt.generated_state(review.dir_name, gen.path_join("generated")).state, "intact", "installation receipt")
	assert_eq(WorldSceneCheck.compare(_summary_of(review.dir_name), doc), PackedStringArray(), "scene equals document")


func test_the_binding_resource_mounts_the_baked_world() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	binding_world = doc.world_id
	var review := review_of(doc)
	assert_true((await apply_review(review)).ok)
	var binding := ResourceLoader.load(ApplyLayout.binding_res(doc.world_id), "", ResourceLoader.CACHE_MODE_IGNORE) as WPAcceptedWorldBinding
	assert_true(binding != null and binding.scene != null, "binding.tres loads with its scene")
	assert_eq(binding.world_id, doc.world_id)
	assert_eq(binding.generation_id, review.generation_id)
	var mount := WPAcceptedWorldMount.new()
	mount.binding = binding
	tree.root.add_child(mount)
	assert_true(mount.mounted != null and mount.mounted.get_node_or_null("Objects") != null, "mounted scene has the objects")
	assert_eq(mount.mounted.get_node("Objects").get_child_count(), 3)
	tree.root.remove_child(mount)
	mount.free()


func test_an_unchanged_snapshot_applies_as_a_no_op() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	var first := review_of(doc)
	assert_true((await apply_review(first)).ok)
	var again := review_of(doc)
	assert_true(again.already_applied, "same inputs, intact output: nothing to do")
	var result := await apply_review(again)
	assert_true(result.ok and result.get("unchanged", false))
	assert_eq(again.generation_id, first.generation_id)


func test_preview_isolation_before_apply_nothing_is_written() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	var review := review_of(doc)
	assert_false(DirAccess.dir_exists_absolute(world_dir()), "no accepted world root yet")
	assert_false(FileAccess.file_exists(project.path_join("assetstudio.lock.json")), "no lock")
	assert_true(DirAccess.dir_exists_absolute(review.staged_source_abs()), "only editor-owned staging exists")
	review.discard_staging()
	assert_false(DirAccess.dir_exists_absolute(review.staged_dir_abs()))


func test_dependencies_are_reviewed_and_root_added_without_touching_other_roots() -> void:
	var w := _remote_world()
	var doc: WorldDocument = w.doc
	binding_world = doc.world_id
	var review := review_of(doc)
	assert_eq(review.blockers, PackedStringArray(), "installed delivery: no blockers")
	assert_eq(review.dependencies.size(), 1)
	assert_eq(review.dependencies[0].state, "ok")
	assert_eq(review.dependencies[0].change, "unchanged", "the lock already pins it")
	var before: Dictionary = Lock.parse_bytes(FileAccess.get_file_as_bytes(project.path_join("assetstudio.lock.json"))).value.doc
	var result := await apply_review(review)
	assert_true(result.ok, str(result.get("error")))
	var after: Dictionary = Lock.parse_bytes(FileAccess.get_file_as_bytes(project.path_join("assetstudio.lock.json"))).value.doc
	var owner_id := ApplyLayout.lock_owner_id(doc.world_id, review.dir_name)
	assert_true(Lock.OWNER_KINDS.has("world_generation") and owner_id.length() <= 64, "owner id is a slug")
	var roots: Array = after.roots
	assert_eq(roots.size(), (before.roots as Array).size() + 1, "one root added")
	assert_true(roots.has({"owner_kind": "world_generation", "owner_id": owner_id, "asset_keys": [review.dependencies[0].asset_key]}))
	for r in before.roots:
		assert_true(roots.has(r), "existing root kept: " + str(r))
	assert_eq(after.dependencies, before.dependencies, "dependencies untouched")
	assert_eq(WorldSceneCheck.compare(_summary_of(review.dir_name), doc), PackedStringArray())


func test_missing_and_mismatching_deliveries_block_apply() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	ApplyTestKit.add_remote_object(doc, item, 20.0, -20.0)
	var review := review_of(doc)
	assert_false(review.can_apply(), "not locked, not installed")
	assert_eq(review.dependencies[0].change, "new")
	assert_true(review.missing.size() == 1, "missing desktop delivery listed")
	assert_false((await apply_review(review)).ok)
	assert_false(DirAccess.dir_exists_absolute(world_dir()), "a blocked Apply writes nothing")
	installed_keys.append(item.binding.asset_key)
	ApplyTestKit.install_delivery(project, item)
	refresh_ctx()
	var other := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	other.binding.deliveries.portable_glb_v1.delivery_id = "dlv_00000000000000d2"
	other.binding.finalize()
	var doc2 := ApplyTestKit.make_doc(catalog)
	ApplyTestKit.add_remote_object(doc2, other, 20.0, -20.0)
	assert_true(review_of(doc2).blockers.size() > 0, "a different delivery than the locked one blocks")
	var bytes := FileAccess.get_file_as_bytes(project.path_join(ApplyLayout.rel_of("res://assets/library")).path_join(
		item.binding.asset_key).path_join(item.binding.deliveries.portable_glb_v1.manifest_sha256).path_join("portable.glb"))
	FileAccess.open(project.path_join("assets/library").path_join(item.binding.asset_key).path_join(
		item.binding.deliveries.portable_glb_v1.manifest_sha256).path_join("portable.glb"), FileAccess.WRITE).store_buffer(bytes + PackedByteArray([1]))
	var modified := review_of(doc)
	assert_true(modified.missing.size() == 1 and modified.dependencies[0].state == "modified", "modified delivery detected")


func test_unsaved_scenes_and_pending_imports_block_apply() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	ctx.import_busy = func() -> bool: return true
	var busy := review_of(doc)
	assert_false(busy.can_apply(), "importer running")
	ctx.import_busy = Callable()
	var scene := ApplyLayout.generation_res(doc.world_id, "x".repeat(0) + "0".repeat(32)).path_join("generated/world.tscn")
	ctx.unsaved_scenes = func() -> PackedStringArray: return PackedStringArray([scene])
	var unsaved := review_of(doc)
	assert_false(unsaved.can_apply(), "unsaved target scene")
	assert_true("; ".join(unsaved.blockers).contains("unsaved"))
	ctx.unsaved_scenes = func() -> PackedStringArray: return PackedStringArray(["res://elsewhere/other.tscn"])
	assert_true(review_of(doc).can_apply(), "an unrelated unsaved scene does not block")


func test_game_siblings_survive_and_modified_generated_content_blocks_replacement() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	binding_world = doc.world_id
	var first := review_of(doc)
	assert_true((await apply_review(first)).ok)
	var game := world_dir().get_base_dir().path_join("game_%s" % StorageFs.random_hex(2))
	DirAccess.make_dir_recursive_absolute(game)
	FileAccess.open(game.path_join("player.gd"), FileAccess.WRITE).store_string("extends Node3D\nfunc hello() -> int:\n\treturn 1\n")
	var scene := Node3D.new()
	scene.name = "Game"
	var mount := WPAcceptedWorldMount.new()
	mount.name = "World"
	mount.binding = ResourceLoader.load(ApplyLayout.binding_res(doc.world_id), "", ResourceLoader.CACHE_MODE_IGNORE) as WPAcceptedWorldBinding
	scene.add_child(mount)
	mount.owner = scene
	for sibling: Node in [DirectionalLight3D.new(), Node3D.new()]:
		sibling.name = "Light" if sibling is DirectionalLight3D else "Player"
		scene.add_child(sibling)
		sibling.owner = scene
	(scene.get_node("Player") as Node3D).set_script(load(game.path_join("player.gd")))
	var packed := PackedScene.new()
	packed.pack(scene)
	scene.free()
	var game_scene := game.path_join("main.tscn")
	assert_eq(ResourceSaver.save(packed, game_scene), OK)
	var hashes := {}
	for f in [game_scene, game.path_join("player.gd")]:
		hashes[f] = FileAccess.get_sha256(f)
	var next := _next_revision(doc)
	var second := review_of(next)
	assert_true(second.can_apply(), "an untouched generated directory does not block")
	assert_true((await apply_review(second)).ok)
	for f: String in hashes:
		assert_eq(FileAccess.get_sha256(f), hashes[f], "game file kept: " + f.get_file())
	assert_eq(binding_of(doc.world_id).generation_id, second.generation_id)
	var generated := ApplyLayout.abs_of(second.destination).path_join("generated/world.tscn")
	FileAccess.open(generated, FileAccess.READ_WRITE).store_string("[gd_scene format=3]\n")
	var third_doc := _next_revision(next)
	var third := review_of(third_doc)
	assert_false(third.can_apply(), "modified generated content blocks the replacement")
	assert_true("; ".join(third.soft_blockers).contains("generated"), "reason names the generated content")
	var refused := await apply_review(third)
	assert_false(refused.ok, "refused without an explicit discard")
	assert_eq(binding_of(doc.world_id).generation_id, second.generation_id, "binding untouched")
	assert_true(third.can_apply(true), "explicit discard lifts it")
	var discarded := await apply_review(third, true)
	assert_true(discarded.ok, str(discarded.get("error")))
	assert_eq(binding_of(doc.world_id).generation_id, third.generation_id)
	assert_true(DirAccess.dir_exists_absolute(ApplyLayout.abs_of(second.destination)), "the replaced generation stays for rollback")


func test_rollback_restores_the_previous_generation_and_its_lock_root() -> void:
	var w := _remote_world()
	var doc: WorldDocument = w.doc
	binding_world = doc.world_id
	var first := review_of(doc)
	assert_true((await apply_review(first)).ok)
	var lock_after_first := FileAccess.get_file_as_bytes(project.path_join("assetstudio.lock.json"))
	var next := _next_revision(doc)
	var second := review_of(next)
	assert_true((await apply_review(second)).ok)
	var tx := ApplyTransaction.new(ctx)
	var listed := tx.list_generations(doc.world_id)
	assert_eq(listed.size(), 2, "both generations are kept")
	assert_eq(listed.filter(func(g: Dictionary) -> bool: return g.active)[0].dir_name, second.dir_name, "newest is active")
	var back := tx.rollback(doc.world_id, first.dir_name)
	assert_true(back.ok, str(back.get("error")))
	assert_eq(binding_of(doc.world_id).generation_id, first.generation_id, "binding points at the earlier generation")
	var lock: Dictionary = Lock.parse_bytes(FileAccess.get_file_as_bytes(project.path_join("assetstudio.lock.json"))).value.doc
	var owners: Array = (lock.roots as Array).map(func(r: Dictionary) -> String: return r.owner_id)
	assert_true(owners.has(ApplyLayout.lock_owner_id(doc.world_id, first.dir_name)), "root of the restored generation present")
	var first_lock: Dictionary = Lock.parse_bytes(lock_after_first).value.doc
	for r in first_lock.roots:
		assert_true((lock.roots as Array).has(r), "root as before the second Apply: " + str(r))
	assert_eq(WorldSceneCheck.compare(_summary_of(first.dir_name), doc), PackedStringArray(), "restored scene is the earlier world")
	assert_true(tx.rollback(doc.world_id, first.dir_name).get("unchanged", false), "rolling back to the active generation is a no-op")
	assert_false(tx.rollback(doc.world_id, "f".repeat(32)).ok, "unknown generation refused")


func test_crash_at_every_coordinator_step_leaves_the_old_or_the_new_complete_state() -> void:
	var w := _remote_world()
	var doc: WorldDocument = w.doc
	binding_world = doc.world_id
	var first := review_of(doc)
	assert_true((await apply_review(first)).ok)
	var lock_old := FileAccess.get_file_as_bytes(project.path_join("assetstudio.lock.json"))
	var next := _next_revision(doc)
	var crashes := 0
	var finished := false
	var step := 1
	var new_dir := ""
	while step < 40 and not finished:
		var review := review_of(next)
		new_dir = review.dir_name
		Coordinator.fail_after_step = step
		var result := await apply_review(review)
		Coordinator.fail_after_step = -1
		finished = result.ok
		if not finished:
			assert_eq(str(result.get("code")), "simulated_crash", "step %d crashed as injected" % step)
			crashes += 1
		var recovered := ApplyTransaction.recover()
		assert_true(recovered.ok, "recover after step %d: %s" % [step, str(recovered.error)])
		_assert_complete(doc, next, first.dir_name, new_dir, lock_old, step)
		step += 1
	assert_true(finished, "an Apply without a crash finished")
	assert_true(crashes >= 10, "the transaction has at least ten crash points (%d)" % crashes)
	assert_eq(binding_of(doc.world_id).generation_id.left(32), new_dir, "the uncrashed Apply switched")
	assert_false(DirAccess.dir_exists_absolute(project.path_join(".world_painter/staging")) and
			not DirAccess.get_directories_at(project.path_join(".world_painter/staging")).is_empty(), "recovery removes staging")


func _assert_complete(old_doc: WorldDocument, new_doc: WorldDocument, old_dir: String, new_dir: String,
		lock_old: PackedByteArray, step: int) -> void:
	var binding := binding_of(old_doc.world_id)
	var active := str(binding.get("generation_id", "")).left(32)
	var note := "after crash at step %d" % step
	assert_true(active == old_dir or active == new_dir, note + ": binding points at a known generation")
	var scene := ApplyLayout.generation_res(old_doc.world_id, active).path_join("generated/world.tscn")
	assert_true(FileAccess.file_exists(ApplyLayout.abs_of(scene)), note + ": the pointed generation is complete")
	var expected := new_doc if active == new_dir else old_doc
	assert_eq(WorldSceneCheck.compare(WorldSceneCheck.summarize(scene, tree), expected), PackedStringArray(), note + ": it reproduces its world")
	var lock := FileAccess.get_file_as_bytes(project.path_join("assetstudio.lock.json"))
	var owner_new := ApplyLayout.lock_owner_id(old_doc.world_id, new_dir)
	var has_new_root := lock.get_string_from_utf8().contains(owner_new)
	if active == old_dir:
		assert_eq(lock, lock_old, note + ": old state keeps the old lock bytes")
		assert_false(DirAccess.dir_exists_absolute(ApplyLayout.abs_of(ApplyLayout.generation_res(old_doc.world_id, new_dir))),
				note + ": no partial new generation directory")
	else:
		assert_true(has_new_root, note + ": new state has the new lock root")


func test_recover_removes_abandoned_staging() -> void:
	var stale := project.path_join(ApplyLayout.STAGING_REL).path_join("deadbeef/source")
	DirAccess.make_dir_recursive_absolute(stale)
	FileAccess.open(stale.path_join("x"), FileAccess.WRITE).store_string("x")
	var result := ApplyTransaction.recover()
	assert_true(result.ok, str(result.error))
	assert_false(DirAccess.dir_exists_absolute(project.path_join(ApplyLayout.STAGING_REL)), "staging removed")


func test_recover_keeps_the_staging_of_an_open_review() -> void:
	var review := review_of(ApplyTestKit.make_doc(catalog))
	var other := project.path_join(ApplyLayout.STAGING_REL).path_join("abandoned")
	DirAccess.make_dir_recursive_absolute(other)
	var result := ApplyTransaction.recover("", PackedStringArray([review.staging_id]))
	assert_true(result.ok, str(result.error))
	assert_true(DirAccess.dir_exists_absolute(review.staged_source_abs()), "the open review keeps its staging")
	assert_false(DirAccess.dir_exists_absolute(other), "abandoned staging is removed")
	review.discard_staging()
