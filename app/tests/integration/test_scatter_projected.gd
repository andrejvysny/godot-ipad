extends ScatterTestCase
## Submission policy never changes authored scatter arrays.


func test_dense_cell_build_resumes_in_bounded_chunks() -> void:
	doc.scatter = ScatterLayer.new()
	for i in 400:
		doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 10.0 + float(i % 10) * 0.01,
				10.0 + float(i / 10) * 0.01, 0.0, 1.0, 0)
	var bytes := doc.scatter.encode()
	renderer.rebuild_all(doc)
	renderer.service_frame(0.01)
	assert_true(renderer.has_dirty(), "one frame cannot process the dense cell")
	assert_true(renderer.stats().uploads <= 1, "deadline admits at most one bounded chunk")
	assert_true(renderer.settle_now())
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 400)
	for node: Node in renderer.get_children():
		assert_true((node as MultiMeshInstance3D).multimesh.instance_count <= ScatterSubmission.CHUNK_INSTANCES)
	assert_eq(doc.scatter.encode(), bytes)


func test_suppression_composes_with_vegetation_and_keeps_dirty_edits() -> void:
	doc.scatter = _layer_of([SPRUCE, BOULDER])
	_build()
	var rule := RenderConfig.load_from().vegetation_rule()
	renderer.set_vegetation_hidden(true, rule)
	renderer.set_view_suppressed(true)
	var builds: int = renderer.stats().cell_builds
	var uploads: int = renderer.stats().uploads
	doc.scatter.add(doc.assets.bundled_binding_for(BOULDER), 12.0, 10.0, 0.0, 1.0, 0)
	renderer.mark_all()
	renderer.service_frame(100.0)
	assert_eq(renderer.stats().cell_builds, builds)
	assert_eq(renderer.stats().uploads, uploads)
	assert_true(renderer.has_dirty())
	for node: Node in renderer.get_children():
		assert_false((node as Node3D).visible)
	renderer.set_view_suppressed(false)
	assert_true(renderer.settle_now())
	assert_eq(renderer.rendered_count(Vector2i.ZERO, BOULDER), 2)
	assert_false(renderer.multimesh_for(Vector2i.ZERO, SPRUCE).visible)
	assert_true(renderer.multimesh_for(Vector2i.ZERO, BOULDER).visible)


func test_shared_cell_large_scale_does_not_keep_tiny_instances() -> void:
	doc.scatter = ScatterLayer.new()
	doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 10.0, 10.0, 0.0, 0.001, 0)
	doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 11.0, 10.0, 0.0, 10.0, 0)
	var bytes := doc.scatter.encode()
	_camera_at(Vector3(10.0, 300.0, 400.0), Vector3(10.0, 0.0, 10.0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1000.0
	renderer.set_camera(camera)
	var profile := full_profile()
	profile.size_policy_enabled = true
	renderer.set_lod_profile(profile)
	_build()
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 1, "large and tiny classified separately")
	assert_near(renderer.instance_transform(Vector2i.ZERO, SPRUCE, 0).basis.y.length(), 10.0, 0.001)
	assert_eq(doc.scatter.encode(), bytes)


func test_stationary_projection_change_reclassifies_then_stays_idle() -> void:
	doc.scatter = _layer_of([SPRUCE])
	_camera_at(Vector3(10.0, 100.0, 110.0), Vector3(10.0, 0.0, 10.0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10000.0
	renderer.set_camera(camera)
	var profile := full_profile()
	profile.size_policy_enabled = true
	renderer.set_lod_profile(profile)
	_build()
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 0)
	camera.size = 20.0
	renderer.flush()
	assert_true(renderer.settle_now())
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 1, "stationary projection resize restores geometry")
	var before := renderer.stats()
	for i in 50:
		renderer.service_frame(1.0)
	assert_eq(renderer.stats().uploads, before.uploads)
	assert_eq(renderer.stats().cell_builds, before.cell_builds)
	assert_false(renderer.has_dirty())


func test_conservative_projection_restores_hidden_during_motion() -> void:
	doc.scatter = _layer_of([SPRUCE])
	_camera_at(Vector3(10.0, 100.0, 110.0), Vector3(10.0, 0.0, 10.0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10000.0
	renderer.set_camera(camera)
	var profile := full_profile()
	profile.size_policy_enabled = true
	renderer.set_lod_profile(profile)
	_build()
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 0)
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.global_position = Vector3(10.0, doc.sample_height(10.0, 10.0), 10.0) + catalog.get_asset(SPRUCE).bounds.get_center()
	renderer.service_frame(100.0)
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 1, "near-plane ambiguity restores geometry before settling")


func test_partial_tier_replacement_never_duplicates_source_instances() -> void:
	doc.scatter = ScatterLayer.new()
	for i in 400:
		doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 10.0 + float(i % 10) * 0.01,
				10.0 + float(i / 10) * 0.01, 0.0, 40.0 if i % 2 == 0 else 1.0, 0)
	_camera_at(Vector3(10.0, 1000.0, 1010.0), Vector3(10.0, 0.0, 10.0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1000.0
	renderer.set_camera(camera)
	var profile := RenderConfig.load_from().profile("detailed")
	profile.size_policy_enabled = true
	renderer.set_lod_profile(profile)
	_build()
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 400)
	camera.size = 5000.0
	for i in 12:
		renderer.service_frame(0.5)
		assert_true(renderer.rendered_count(Vector2i.ZERO, SPRUCE) <= 400, "old/new tiers replace each source chunk atomically")
	assert_true(renderer.settle_now())
	assert_true(renderer.rendered_count(Vector2i.ZERO, SPRUCE) <= 400)


func test_projection_change_during_initial_dense_build_gets_followup_pass() -> void:
	doc.scatter = ScatterLayer.new()
	for i in 1000:
		doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 10.0 + float(i % 10) * 0.01,
				10.0 + float(i / 10) * 0.01, 0.0, 0.001, 0)
	_camera_at(Vector3(10.0, 100.0, 110.0), Vector3(10.0, 0.0, 10.0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1000.0
	renderer.set_camera(camera)
	var profile := full_profile()
	profile.size_policy_enabled = true
	renderer.set_lod_profile(profile)
	renderer.rebuild_all(doc)
	renderer.service_frame(0.5)
	assert_true(renderer.has_dirty())
	camera.size = 0.1
	assert_true(renderer.settle_now())
	assert_eq(renderer.rendered_count(Vector2i.ZERO, SPRUCE), 1000, "early chunks cannot keep the initial hidden classification")
