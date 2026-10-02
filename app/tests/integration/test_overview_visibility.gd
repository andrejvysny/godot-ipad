extends TestCase

var fx: OverviewFixture


func test_disabled_hlod_stays_disabled_during_moving_and_settled_service() -> void:
	fx = OverviewFixture.new(tree, Rect2(0.0, 0.0, 256.0, 256.0))
	fx.add(OverviewFixture.SPRUCE, Vector3(50.0, 0.0, 50.0))
	fx.add(OverviewFixture.CABIN, Vector3(80.0, 0.0, 80.0))
	fx.aim(Vector3(64.0, 1600.0, 64.0), Vector3(64.0, 0.0, 64.0))
	fx.sync_all()
	assert_true(fx.settle())
	assert_true(fx.overview.stats().proxy_submissions > 0)
	fx.overview.set_enabled(false)
	fx.set_profile(fx.profile.merged({"settle_ms": 250}, true))
	var meshes: int = fx.overview.stats().mesh_builds
	for step in 6:
		fx.camera.global_position.x += 1.0
		fx.overview.service(fx.camera, 10.0)
	fx.overview._cam.last_move_ms -= 1000
	for step in 6:
		fx.overview.service(fx.camera, 10.0)
	var stats := fx.overview.stats()
	assert_eq(stats.active.get(256, 0), 0)
	assert_eq(stats.proxy_submissions, 0)
	assert_eq(stats.cells_covered, 0)
	assert_eq(stats.mesh_builds, meshes)
	assert_true(fx.overview._capture.is_empty())
	assert_false(fx.overview.has_pending_work())
	fx.overview._on_changed(Rect2(32.0, 32.0, 64.0, 64.0))
	for step in 3:
		fx.overview.service(fx.camera, 10.0)
	assert_true(fx.overview._capture.is_empty())
	assert_false(fx.overview.has_pending_work())
	fx.overview.set_enabled(true)
	fx.set_profile(fx.profile.merged({"settle_ms": 0}, true))
	assert_true(fx.settle())
	assert_true(fx.overview.stats().proxy_submissions > 0)


func after_each() -> void:
	if fx != null:
		fx.release()
		fx = null


func test_disabling_hlod_abandons_partial_capture_and_blocks_direct_build_paths() -> void:
	fx = OverviewFixture.new(tree, Rect2(0.0, 0.0, 128.0, 128.0), PackedFloat32Array([128.0]))
	fx.add(OverviewFixture.SPRUCE, Vector3(50.0, 0.0, 50.0))
	fx.aim(Vector3(64.0, 1600.0, 64.0), Vector3(64.0, 0.0, 64.0))
	fx.sync_all()
	fx.overview.service(fx.camera, 10.0)
	var g := fx.overview.group(0, Vector2i.ZERO)
	assert_false(fx.overview._capture.is_empty())
	assert_true(g.building)
	fx.overview.set_enabled(false)
	assert_false(g.building)
	assert_true(fx.overview._capture.is_empty())
	g.result = OverviewClusterBuilder.empty_result()
	fx.overview._make_one_mesh(true)
	fx.overview._apply_activation(true)
	fx.overview._start_capture(Time.get_ticks_msec(), true)
	fx.overview._set_active(g, true)
	assert_false(g.current or g.active)
	assert_false(g.result.is_empty(), "disabled renderer retains CPU result without publishing")
	assert_true(fx.overview._capture.is_empty())
	assert_eq(fx.world.covered_cell_count(), 0)
	assert_false(fx.overview.has_pending_work())


func test_suppression_preserves_cut_but_masks_pick_mesh_and_vegetation_changes() -> void:
	fx = OverviewFixture.new(tree, Rect2(0.0, 0.0, 256.0, 256.0))
	fx.add(OverviewFixture.SPRUCE, Vector3(50.0, 0.0, 50.0))
	fx.add(OverviewFixture.CABIN, Vector3(80.0, 0.0, 80.0))
	fx.aim(Vector3(64.0, 1600.0, 64.0), Vector3(64.0, 0.0, 64.0))
	fx.sync_all()
	assert_true(fx.settle())
	var g := fx.overview.group(1, Vector2i.ZERO)
	var coverage := fx.world.covered_cell_count()
	var before := fx.overview.stats()
	assert_true(g.active and g.canopy != null and g.solid != null)
	fx.overview.set_view_suppressed(true)
	fx.overview._set_active(g, false)
	fx.overview._set_active(g, true)
	fx.overview.set_vegetation_hidden(true)
	fx.overview.set_vegetation_hidden(false)
	fx.overview.service(fx.camera, 10.0)
	assert_false(g.canopy.visible or g.solid.visible)
	assert_true(g.active)
	assert_eq(fx.world.covered_cell_count(), coverage)
	assert_true(fx.overview.pick(Vector3(50.0, 1600.0, 50.0), Vector3.DOWN).is_empty())
	var suppressed := fx.overview.stats()
	assert_eq(suppressed.proxy_triangles, 0)
	assert_eq(suppressed.proxy_submissions, 0)
	assert_eq(suppressed.retained_proxy_triangles, before.proxy_triangles)
	assert_eq(suppressed.mesh_builds, before.mesh_builds)
	fx.overview.set_vegetation_hidden(true)
	fx.overview.set_view_suppressed(false)
	assert_false(g.canopy.visible)
	assert_true(g.solid.visible)
	fx.overview.set_vegetation_hidden(false)
	assert_true(g.canopy.visible)


func test_suppressed_dirty_group_waits_to_capture_and_publish() -> void:
	fx = OverviewFixture.new(tree, Rect2(0.0, 0.0, 128.0, 128.0), PackedFloat32Array([128.0]))
	fx.add(OverviewFixture.SPRUCE, Vector3(50.0, 0.0, 50.0))
	fx.aim(Vector3(64.0, 1600.0, 64.0), Vector3(64.0, 0.0, 64.0))
	fx.overview.set_view_suppressed(true)
	fx.sync_all()
	for index in 10:
		fx.frame()
	assert_eq(fx.overview.stats().mesh_builds, 0)
	assert_true(fx.overview._capture.is_empty() and fx.overview._jobs.is_empty())
	assert_false(fx.overview.group(0, Vector2i.ZERO).current)
	fx.overview.set_view_suppressed(false)
	assert_true(fx.settle())
	assert_true(fx.overview.group(0, Vector2i.ZERO).active)


func test_zero_budget_does_not_capture_or_publish() -> void:
	fx = OverviewFixture.new(tree, Rect2(0.0, 0.0, 128.0, 128.0), PackedFloat32Array([128.0]))
	fx.aim(Vector3(64.0, 1600.0, 64.0), Vector3(64.0, 0.0, 64.0))
	fx.overview.service(fx.camera, 0.0)
	assert_true(fx.overview._capture.is_empty())
	assert_eq(fx.overview.stats().mesh_builds, 0)


func test_moving_offscreen_groups_do_not_build_but_idle_prefetch_remains() -> void:
	fx = OverviewFixture.new(tree, Rect2(0.0, 0.0, 128.0, 128.0), PackedFloat32Array([128.0]))
	fx.set_profile(fx.profile.merged({"settle_ms": 250}, true))
	fx.aim(Vector3(64.0, 300.0, -300.0), Vector3(64.0, 0.0, -1300.0))
	fx.overview.service(fx.camera, 10.0)
	assert_true(fx.overview._capture.is_empty())
	assert_true(fx.overview._jobs.is_empty())
	fx.overview._cam.last_move_ms -= 1000
	fx.overview.service(fx.camera, 10.0)
	assert_false(fx.overview._capture.is_empty(), "settled navigation retains idle prefetch")
