extends TestCase


func _snapshot(height: float = 820.0, scale: float = 1.0, orthographic: bool = false) -> RenderCameraSnapshot:
	var result := RenderCameraSnapshot.new()
	result.viewport_size = Vector2(height, height)
	result.internal_size = result.viewport_size * scale
	result.render_scale = scale
	result.near = 0.1
	result.projection = Projection.create_orthogonal(-5.0, 5.0, -5.0, 5.0, 0.1, 1000.0) if orthographic \
			else Projection.create_perspective(60.0, 1.0, 0.1, 1000.0)
	result.valid = true
	return result


func test_projected_size_uses_reference_height_and_internal_scale() -> void:
	var box := AABB(Vector3(-1.0, -1.0, -11.0), Vector3(2.0, 2.0, 2.0))
	var base := ProjectedBounds.measure(box, _snapshot())
	var double := ProjectedBounds.measure(box, _snapshot(1640.0, 0.5))
	assert_true(base.valid)
	assert_false(base.conservative)
	assert_near(base.reference_px, double.reference_px, 0.001)
	assert_near(double.display_px, base.display_px * 2.0, 0.001)
	assert_near(double.internal_px, base.internal_px, 0.001)


func test_near_plane_crossing_invalid_and_behind_are_explicit() -> void:
	var snapshot := _snapshot()
	var crossing := ProjectedBounds.measure(AABB(Vector3(-1.0, -1.0, -1.0), Vector3.ONE * 2.0), snapshot)
	assert_true(crossing.valid)
	assert_true(crossing.conservative)
	assert_eq(crossing.reference_px, INF)
	var behind := ProjectedBounds.measure(AABB(Vector3(-1.0, -1.0, 1.0), Vector3.ONE), snapshot)
	assert_true(behind.behind)
	snapshot.viewport_size = Vector2.ZERO
	assert_false(ProjectedBounds.measure(AABB(), snapshot).valid)
	assert_true(ProjectedBounds.measure(AABB(Vector3.INF, Vector3.ONE), _snapshot()).conservative)
	assert_true(ProjectedBounds.measure(AABB(Vector3(0.0, 0.0, -10.0), Vector3.ZERO), _snapshot()).conservative)
	assert_false(ProjectedBounds.measure(AABB(Vector3(-1.0, -1.0, -10.0), Vector3(2.0, 2.0, 0.0)), _snapshot()).conservative)


func test_unclipped_offscreen_and_orthographic_projection() -> void:
	var snapshot := _snapshot(820.0, 1.0, true)
	var near_box := AABB(Vector3(20.0, -1.0, -10.0), Vector3(2.0, 2.0, 1.0))
	var far_box := near_box
	far_box.position.z = -100.0
	var near_size := ProjectedBounds.measure(near_box, snapshot)
	var far_size := ProjectedBounds.measure(far_box, snapshot)
	assert_near(near_size.reference_px, 164.0, 0.001)
	assert_near(near_size.reference_px, far_size.reference_px, 0.001)
	assert_true(near_size.rect.position.x > 820.0)
	assert_near(near_size.extent_ratio, 0.2, 0.001)


func test_size_visibility_and_roles_keep_threshold_ties() -> void:
	assert_true(LodPolicy.size_visible(2.0, true))
	assert_false(LodPolicy.size_visible(1.99, true))
	assert_false(LodPolicy.size_visible(3.0, false))
	assert_true(LodPolicy.size_visible(3.01, false))
	assert_false(LodPolicy.size_visible(3.99, false, true))
	assert_true(LodPolicy.size_visible(INF, false))
	assert_eq(LodPolicy.size_role(1000.0, {"near_min_role": "mid"}), "mid")
	assert_eq(LodPolicy.size_role(35.2, {"near_min_role": "near"}, "far"), "far")
	assert_eq(LodPolicy.size_role(35.21, {"near_min_role": "near"}, "far"), "mid")
	assert_eq(LodPolicy.size_role(28.8, {"near_min_role": "near"}, "mid"), "mid")
	assert_eq(LodPolicy.size_role(28.79, {"near_min_role": "near"}, "mid"), "far")


func test_view_state_hysteresis_operation_deferral_and_focus() -> void:
	var snapshot := _snapshot(820.0, 1.0, true)
	snapshot.downward_pitch_deg = 60.0
	var world := AABB(Vector3(-5.0, -5.0, -10.0), Vector3(10.0, 10.0, 1.0))
	var state := RenderViewState.new()
	assert_false(state.update(snapshot, world, true))
	assert_eq(state.state, RenderViewState.LOCAL)
	assert_true(state.update(snapshot, world))
	assert_eq(state.state, RenderViewState.TERRAIN_ONLY)
	snapshot.downward_pitch_deg = 35.0
	assert_false(state.update(snapshot, world))
	snapshot.downward_pitch_deg = 34.99
	assert_true(state.update(snapshot, world))
	assert_eq(state.state, RenderViewState.REGIONAL)
	state.force_state(RenderViewState.TERRAIN_ONLY)
	state.force_state("")
	var invalid := RenderCameraSnapshot.new()
	assert_false(state.update(invalid, world, true))
	assert_eq(state.state, RenderViewState.TERRAIN_ONLY)
	assert_true(state.update(invalid, world))
	assert_eq(state.state, RenderViewState.REGIONAL)
	state.clear_for_local_focus()
	snapshot.downward_pitch_deg = 60.0
	assert_false(state.update(snapshot, world))
	assert_eq(state.state, RenderViewState.LOCAL)


func test_snapshot_generation_detects_projection_changes_without_motion() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(820, 820)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	tree.root.add_child(viewport)
	var tracker := LodCameraTracker.new()
	assert_true(tracker.update(camera, 0))
	assert_false(tracker.update(camera, 1))
	var generation := tracker.generation
	camera.near = 0.2
	assert_true(tracker.update(camera, 2))
	assert_eq(tracker.generation, generation + 1)
	camera.fov = 90.0
	assert_true(tracker.update(camera, 3))
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	assert_true(tracker.update(camera, 4))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	assert_true(tracker.update(camera, 5))
	camera.size = 30.0
	assert_true(tracker.update(camera, 6))
	viewport.size = Vector2i(900, 820)
	assert_true(tracker.update(camera, 7))
	viewport.scaling_3d_scale = 0.5
	assert_true(tracker.update(camera, 8))
	assert_eq(tracker.snapshot.generation, tracker.generation)
	viewport.free()
