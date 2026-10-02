extends UiTestCase
## Session wiring of the overview and the per-cell LOD (rendering spec §4.2, §9, §15.1): the overview exists and
## serves the select tool's area pick, area focus moves the orbit camera, profile switches reach the LOD,
## and the bench step carries render stats.


func test_session_owns_an_overview_and_hooks_the_select_tool() -> void:
	var s := await _start("flat")
	var overview := s.get_node_or_null("overview") as OverviewRenderer
	assert_true(overview != null, "the overview is a child of the session")
	assert_eq(overview.world_rect(), s.document.layout.world_rect())
	assert_true(s._tool_ctx.area_pick.is_valid() and s._tool_ctx.focus_area.is_valid(), "tap hooks are set")
	var summary := s.render_summary()
	assert_true(summary.has("batches") and summary.has("estimated_triangles") and summary.has("overview"))
	assert_true((summary.overview as Dictionary).has("proxy_triangles"))
	assert_true((summary.overview as Dictionary).has("pending_builds"))


func test_area_focus_pivots_on_the_terrain_and_reaches_individual_detail() -> void:
	var s := await _start("flat")
	var rig := s.rig
	var before := rig.controller.get_pose()
	var area := AABB(Vector3(32.0, 0.0, -64.0), Vector3(128.0, 10.0, 128.0))
	s._render.focus_area(area)
	var pose := rig.controller.get_pose()
	var center := area.get_center()
	assert_near(pose.pivot.x, center.x, 1e-4)
	assert_near(pose.pivot.z, center.z, 1e-4)
	assert_near(pose.pivot.y, s.document.sample_height(center.x, center.z), 1e-3, "on the terrain")
	var radius := float(s.render_profiles.active_profile().tree_detail_radius_m)
	assert_near(pose.distance, clampf(radius * SessionRender.AREA_FOCUS_FACTOR, 3.0, rig.controller.distance_max()), 1e-3)
	assert_true(pose.distance < radius, "individual detail range")
	assert_near(pose.yaw, before.yaw, 1e-6, "the viewing angle is kept")
	assert_eq(s.last_message, SessionRender.AREA_FOCUS_MESSAGE)
	assert_eq(s.tools.selected_id(), "", "nothing selected")


func test_profile_switch_reaches_the_per_cell_lod_and_the_overview() -> void:
	var s := await _start("stress_100")
	var id := s.document.sorted_object_ids()[0]
	var pos := s.document.get_object(id).get_position_v3()
	s.rig.controller.set_pose({"pivot": pos, "distance": 15.0, "yaw": 0.3, "pitch": 0.8})
	s.rig.reset_to(s.rig.controller.get_pose())
	var world := s.presenter.render_world()
	for i in 300:
		await _frames(1)
		if world.owner_of(id).ends_with("|mid"):
			break
	var role := world.owner_of(id).get_slice("|", 1)
	assert_true(role == "mid", "Performance draws the object next to the camera as mid, got " + role)
	assert_eq(s.request_profile("balanced").status, "applied")
	for i in 300:
		await _frames(1)
		if world.owner_of(id).ends_with("|near"):
			break
	assert_true(world.owner_of(id).ends_with("|near"), "Balanced allows the near tier once navigation settled: " + world.owner_of(id))


func test_active_edit_pins_reach_the_object_lod_and_survive_a_presenter_reset() -> void:
	var s := await _start("flat")
	var world := s.presenter.render_world()
	assert_false(world._pinned(Vector2i(0, 0)))
	s.render_state().active_edit.begin("pin-test", Vector3(5, 0, 5), 4.0)
	assert_true(world._pinned(Vector2i(0, 0)), "session pins are the world's pin check")
	s.presenter.setup(s.catalog, s.render_state().registry(), s.render_cache())
	assert_true(s.presenter.render_world()._pinned(Vector2i(0, 0)), "a new render world keeps the pin check")
	s.render_state().active_edit.end("pin-test", "finished")


func test_catalog_rebind_recreates_groups_for_the_same_world_extent() -> void:
	var s := await _start("flat")
	var overview := s.render_state().overview
	var rect := overview.world_rect()
	var groups := int(overview.stats().groups)
	assert_true(groups > 0)
	var attachment := BenchAttach.new(s)
	assert_empty_string(attachment.attach("bench"))
	s.render_state().service_frame(0.0)
	assert_eq(overview.world_rect(), rect)
	assert_eq(int(overview.stats().groups), groups, "same-sized catalog swaps retain the overview grid")
	attachment.restore()
	s.render_state().service_frame(0.0)
	assert_eq(int(overview.stats().groups), groups, "restoring the editor also rebuilds the grid")


func test_benchmark_readiness_rejects_an_enabled_missing_overview_grid() -> void:
	var s := await _start("flat")
	var overview := s.render_state().overview
	var rect := overview.world_rect()
	assert_empty_string(s.render_state().set_comparison_flags({"forced_view": "regional"}))
	overview.reset()
	var missing := BenchReadiness.capture(s)
	assert_true(missing.overview)
	assert_true(missing.overview_work.missing_grid)
	assert_empty_string(s.render_state().set_comparison_flags({"hlod_enabled": false, "forced_view": "regional"}))
	assert_false(BenchReadiness.capture(s).overview)
	overview.set_world_rect(rect)
