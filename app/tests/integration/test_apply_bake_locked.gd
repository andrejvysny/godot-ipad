extends ApplyProjectCase
## `bake --locked` and `verify --offline` (ADR 0017 A7): a clean generated/ is rebuilt from the tracked source and the
## installed locked deliveries with the same scene semantics; every input mismatch is refused; verify reports what
## changed. The command scripts are exercised through their run() entry points.

const BAKE := "res://addons/world_painter/cli/bake_command.gd"
const VERIFY := "res://addons/world_painter/cli/verify_command.gd"
const Lock := preload("res://addons/assetstudio/project/as_project_lock.gd")


func _applied() -> Dictionary:
	var doc := ApplyTestKit.make_doc(catalog)
	var review := review_of(doc)
	var result := await apply_review(review)
	assert_true(result.ok, str(result.get("error")))
	return {"doc": doc, "review": review}


func _generation(applied: Dictionary) -> String:
	return ApplyLayout.abs_of((applied.review as ApplyReview).destination)


func _scene_summary(applied: Dictionary) -> Dictionary:
	var review: ApplyReview = applied.review
	return WorldSceneCheck.summarize(review.destination.path_join("generated/world.tscn"), tree)


func test_bake_locked_rebuilds_a_clean_generated_directory_with_the_same_scene() -> void:
	var applied := await _applied()
	var before := _scene_summary(applied)
	assert_eq(WorldSceneCheck.compare(before, applied.doc), PackedStringArray())
	StorageFs.remove_tree(_generation(applied).path_join("generated"))
	assert_eq(ApplyReceipt.generated_state(applied.review.dir_name, _generation(applied).path_join("generated")).state, "absent")
	var result := LockedBake.new(ctx).bake(applied.doc.world_id)
	assert_true(result.ok, str(result.get("error")))
	assert_false(result.get("unchanged", true), "it rebuilt")
	var after := _scene_summary(applied)
	assert_eq(after, before, "same objects, transforms, scatter counts, paths and terrain buffers")
	assert_eq(ApplyReceipt.generated_state(applied.review.dir_name, _generation(applied).path_join("generated")).state, "intact",
			"the installation receipt was restored with the directory")
	assert_false(DirAccess.dir_exists_absolute(project.path_join(ApplyLayout.STAGING_REL)) and
			not DirAccess.get_directories_at(project.path_join(ApplyLayout.STAGING_REL)).is_empty(), "no staging left")
	assert_true(LockedBake.new(ctx).bake(applied.doc.world_id, applied.review.dir_name).get("unchanged", false), "a second bake is a no-op")


func test_bake_locked_refuses_modified_generated_content_and_changed_inputs() -> void:
	var applied := await _applied()
	var world: String = applied.doc.world_id
	var generated := _generation(applied).path_join("generated")
	FileAccess.open(generated.path_join("world.tscn"), FileAccess.READ_WRITE).store_string("[gd_scene format=3]\n")
	var modified := LockedBake.new(ctx).bake(world)
	assert_false(modified.ok, "modified generated content is never overwritten")
	assert_true(str(modified.error).contains("modified"), str(modified.error))
	StorageFs.remove_tree(generated)
	ProjectSettings.set_setting(ApplyLayout.SETTING_COLLISION, PackedStringArray(["b" + "0".repeat(32)]))
	var profile := LockedBake.new(ctx).bake(world)
	assert_false(profile.ok)
	assert_true(str(profile.error).contains("consumer profile"), str(profile.error))
	ProjectSettings.set_setting(ApplyLayout.SETTING_COLLISION, PackedStringArray())
	var objects := _generation(applied).path_join("source/objects.json")
	FileAccess.open(objects, FileAccess.READ_WRITE).store_string("{}")
	var tampered := LockedBake.new(ctx).bake(world)
	assert_false(tampered.ok)
	assert_true(str(tampered.error).contains("source"), str(tampered.error))
	assert_false(DirAccess.dir_exists_absolute(generated), "nothing was rebuilt from refused inputs")


func test_bake_locked_refuses_missing_dependencies_and_unknown_worlds() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	var binding_id := ApplyTestKit.add_remote_object(doc, item, 20.0, -20.0)
	installed_keys.append(item.binding.asset_key)
	ApplyTestKit.install_delivery(project, item)
	refresh_ctx()
	var stub := Node3D.new()
	var packed := PackedScene.new()
	packed.pack(stub)
	stub.free()
	ctx.deliveries.overrides[binding_id] = packed
	var review := review_of(doc)
	assert_true((await apply_review(review)).ok)
	StorageFs.remove_tree(ApplyLayout.abs_of(review.destination).path_join("generated"))
	StorageFs.remove_tree(project.path_join("assets/library").path_join(item.binding.asset_key))
	refresh_ctx()
	var missing := LockedBake.new(ctx).bake(doc.world_id)
	assert_false(missing.ok, "an uninstalled locked delivery stops the bake")
	assert_true(str(missing.error).contains("desktop delivery") or str(missing.error).contains("not installed"), str(missing.error))
	assert_false(LockedBake.new(ctx).bake(ObjectRecord.new_uuid_v4()).ok, "unknown world")


func test_verify_reports_what_changed_and_passes_when_nothing_did() -> void:
	var applied := await _applied()
	var verify := ApplyVerify.new(ctx)
	var ok := verify.verify_all()
	assert_true(ok.ok, str(ok.problems))
	assert_eq((ok.worlds as Array).size(), 1)
	var generated := _generation(applied).path_join("generated")
	StorageFs.remove_tree(generated)
	var absent := verify.verify_all()
	assert_false(absent.ok)
	assert_true("; ".join(absent.problems).contains("absent"), str(absent.problems))
	assert_true(LockedBake.new(ctx).bake(applied.doc.world_id).ok)
	assert_true(verify.verify_all().ok, "bake --locked repairs it")
	FileAccess.open(_generation(applied).path_join("source/paths.bin"), FileAccess.READ_WRITE).store_string("x")
	var source := verify.verify_all()
	assert_false(source.ok)
	assert_true("; ".join(source.problems).contains("source"), str(source.problems))


func test_verify_checks_the_lock_root_of_remote_worlds() -> void:
	var doc := ApplyTestKit.make_doc(catalog)
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	var binding_id := ApplyTestKit.add_remote_object(doc, item, 20.0, -20.0)
	installed_keys.append(item.binding.asset_key)
	ApplyTestKit.install_delivery(project, item)
	refresh_ctx()
	var packed := PackedScene.new()
	var stub := Node3D.new()
	packed.pack(stub)
	stub.free()
	ctx.deliveries.overrides[binding_id] = packed
	assert_true((await apply_review(review_of(doc))).ok)
	var first_verify := ApplyVerify.new(ctx).verify_all()
	assert_true(first_verify.ok, "root present: " + str(first_verify.problems))
	var lock_path := project.path_join("assetstudio.lock.json")
	var lock: RefCounted = Lock.parse_bytes(FileAccess.get_file_as_bytes(lock_path)).value
	lock.doc.roots = (lock.doc.roots as Array).filter(func(r: Dictionary) -> bool: return r.owner_kind != "world_generation")
	var out := FileAccess.open(lock_path, FileAccess.WRITE)
	out.store_buffer(lock.call("to_bytes").value)
	out.close()
	refresh_ctx()
	ctx.deliveries.overrides[binding_id] = packed
	var result := ApplyVerify.new(ctx).verify_all()
	assert_false(result.ok)
	assert_true("; ".join(result.problems).contains("world_generation root"), str(result.problems))


func test_command_scripts_return_exit_codes_and_validate_usage() -> void:
	var bake := load(BAKE) as GDScript
	var verify := load(VERIFY) as GDScript
	assert_eq(bake.call("run", PackedStringArray(["--world", ObjectRecord.new_uuid_v4()])), 2, "bake needs --locked")
	assert_eq(bake.call("run", PackedStringArray(["--locked"])), 2, "bake needs --world")
	assert_eq(bake.call("run", PackedStringArray(["--locked", "--world", "not-a-uuid"])), 2)
	assert_eq(bake.call("run", PackedStringArray(["--locked", "--world", ObjectRecord.new_uuid_v4()])), 1, "unknown world fails")
	assert_eq(verify.call("run", PackedStringArray()), 2, "verify needs --offline")
	assert_eq(verify.call("run", PackedStringArray(["--offline"])), 0, "no accepted world: nothing to fail")


func test_command_scripts_bake_and_verify_an_applied_world() -> void:
	var applied := await _applied()
	var bake := load(BAKE) as GDScript
	var verify := load(VERIFY) as GDScript
	assert_eq(verify.call("run", PackedStringArray(["--offline"])), 0, "verified")
	StorageFs.remove_tree(_generation(applied).path_join("generated"))
	assert_eq(verify.call("run", PackedStringArray(["--offline"])), 1, "absent generated content fails verify")
	assert_eq(bake.call("run", PackedStringArray(["bake", "--locked", "--world", applied.doc.world_id])), 0, "bake rebuilt")
	assert_eq(verify.call("run", PackedStringArray(["--offline"])), 0, "verified again")
	assert_eq(bake.call("run", PackedStringArray(["--locked", "--world=" + applied.doc.world_id, "--generation",
			applied.review.dir_name])), 0, "explicit generation, nothing to do")
