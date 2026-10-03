extends TestCase
## RuntimeGlbLoader: validate first, then GLTFDocument on the main thread, bake into one asset-space ArrayMesh with
## opaque/cutout StandardMaterial3D, free the generated scene.


func _load(bytes: PackedByteArray, loader: RuntimeGlbLoader = null, cancel: RefCounted = null) -> RuntimeGlbLoader.Result:
	var l := loader if loader != null else RuntimeGlbLoader.new()
	return await l.load_glb(bytes, cancel)


func test_contract_glb_bakes_to_one_surface_in_asset_space() -> void:
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var t0 := Time.get_ticks_usec()
	var r := await _load(AssetTestKit.glb(AssetTestKit.GLB_V1))
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("MEASURE primitive_prop.portable.glb load+bake %.2f ms" % ms)
	assert_true(r.ok, r.error)
	assert_eq(r.surfaces, 1)
	assert_eq(r.triangles, 12)
	assert_eq(r.materials_used, 1)
	assert_true(r.scatter_ok)
	assert_true(r.mesh is ArrayMesh)
	assert_vec_near(r.aabb.position, Vector3(-0.5, 0.0, -1.0), 1e-4)
	assert_vec_near(r.aabb.end, Vector3(0.5, 0.5, 1.0), 1e-4)
	assert_true(r.mesh.surface_get_material(0) is StandardMaterial3D)
	assert_eq(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans, "the generated scene is freed")


func test_node_transforms_are_applied_into_one_mesh() -> void:
	var t0 := Time.get_ticks_usec()
	var r := await _load(AssetTestKit.glb(AssetTestKit.GLB_V2))
	print("MEASURE primitive_prop_v2.portable.glb load+bake %.2f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	assert_true(r.ok, r.error)
	assert_eq(r.triangles, 24)
	assert_true(r.surfaces >= 1 and r.surfaces <= 2, "one baked surface per source material (%d)" % r.surfaces)
	assert_vec_near(r.aabb.position, Vector3(-0.5, 0.0, -1.0), 1e-4)
	assert_vec_near(r.aabb.end, Vector3(0.5, 0.5, 1.0), 1e-4)


func test_blend_becomes_cutout_and_textures_survive() -> void:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.8, 0.2, 0.2, 0.5))
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = ImageTexture.create_from_image(image)
	var r := await _load(AssetTestKit.sphere_glb(16, 8, material))
	assert_true(r.ok, r.error)
	var out := r.mesh.surface_get_material(0) as StandardMaterial3D
	assert_true(out != null)
	assert_eq(out.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, "blend is disclosed and converted to cutout")
	assert_true(out.albedo_texture != null, "the embedded texture is decoded")
	assert_true(r.disclosures.size() == 1 and r.disclosures[0].contains("blended"), str(r.disclosures))
	assert_eq(r.max_texture_dim, 8)


func test_scatter_budget_follows_triangles() -> void:
	var r := await _load(AssetTestKit.sphere_glb(64, 32))
	assert_true(r.ok, r.error)
	assert_true(r.triangles > RuntimeGlbValidator.SCATTER_MAX_TRIANGLES)
	assert_false(r.scatter_ok)


func test_hostile_input_is_rejected_before_any_scene_exists() -> void:
	var j := AssetTestKit.fixture_json()
	j.images = [{"uri": "textures/a.png"}]
	var r := await _load(AssetTestKit.build_glb(j, AssetTestKit.fixture_bin()))
	assert_false(r.ok)
	assert_error_contains(r.error, "external image URI")
	assert_true(r.mesh == null)


func test_heavy_gate_defers_and_cancel_ends_with_nothing() -> void:
	var gate := {"open": false}
	var loader := RuntimeGlbLoader.new()
	loader.can_run_heavy = func() -> bool: return bool(gate.open)
	var token := AssetStudioProvider.CancelToken.new()
	var holder := {"result": null}
	var run := func() -> void:
		holder.result = await loader.load_glb(AssetTestKit.glb(AssetTestKit.GLB_V1), token)
	run.call()
	for i in 3:
		await tree.process_frame
	assert_true(holder.result == null, "waits while an operation is active")
	token.cancel()
	await tree.process_frame
	await tree.process_frame
	var r: RuntimeGlbLoader.Result = holder.result
	assert_true(r != null and not r.ok and r.error == "cancelled")
	assert_true(r.mesh == null)
	gate.open = true
	var again := await _load(AssetTestKit.glb(AssetTestKit.GLB_V1), loader)
	assert_true(again.ok, again.error)
