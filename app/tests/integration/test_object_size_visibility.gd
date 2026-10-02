extends TestCase
## Object screen-size policy preserves document membership while submitted slots stay dense.

var fx: OverviewFixture


func before_each() -> void:
	fx = OverviewFixture.new(tree)
	fx.set_profile(fx.profile.merged({"size_policy_enabled": true, "near_min_role": "near", "settle_ms": 0}, true))
	fx.aim(Vector3(16.0, 10.0, 60.0), Vector3(16.0, 5.0, 16.0))


func after_each() -> void:
	fx.release()


func _put(id: String, scale: float, position: Vector3 = Vector3(16.0, 0.0, 16.0)) -> void:
	fx.world.upsert(id, OverviewFixture.SPRUCE, Transform3D(Basis.from_scale(Vector3.ONE * scale), position))


func _settle() -> void:
	assert_true(fx.run_until(func() -> bool: return not fx.world.has_pending_work()), "object projection settles")


func test_same_cell_has_distinct_roles_and_tiny_record_has_no_slot() -> void:
	_put("large", 2.0)
	_put("small", 0.1)
	_put("tiny", 0.001)
	_settle()
	assert_eq(fx.world.owner_of("large").get_slice("|", 1), "near")
	assert_eq(fx.world.owner_of("small").get_slice("|", 1), "far")
	assert_eq(fx.world.owner_of("tiny"), "")
	assert_false(fx.world.is_object_visible("tiny"))
	assert_eq(int(fx.world.stats().canonical_instances), 3)
	assert_eq(int(fx.world.stats().instances), 2)
	assert_eq(fx.world.overview_members(Rect2(0.0, 0.0, 32.0, 32.0)).size(), 3)
	var batch := fx.world.batch_of("small")
	assert_eq(batch.multimesh().visible_instance_count, batch.count)


func test_hidden_record_transform_reappears_then_delete_clears_state() -> void:
	_put("tiny", 0.001)
	_settle()
	assert_eq(fx.world.owner_of("tiny"), "")
	_put("tiny", 1.0)
	_settle()
	assert_true(fx.world.is_object_visible("tiny"))
	assert_true(fx.world.batch_of("tiny") != null)
	fx.world.remove("tiny")
	assert_false(fx.world.is_object_visible("tiny"))
	assert_eq(int(fx.world.stats().canonical_instances), 0)
	_put("tiny", 1.0)
	_settle()
	assert_true(fx.world.is_object_visible("tiny"))


func test_view_suppression_masks_selected_and_restores_other_visibility_reasons() -> void:
	_put("visible", 1.0)
	_settle()
	fx.world.set_selected("visible")
	fx.world.set_view_suppressed(true)
	assert_false(fx.world.promoted_node().visible)
	assert_false(fx.world.is_object_visible("visible"))
	assert_eq(int(fx.world.stats().visible_instances), 0)
	fx.world.set_cells_covered(Rect2(0.0, 0.0, 32.0, 32.0), true)
	fx.world.set_view_suppressed(false)
	assert_false(fx.world.promoted_node().visible)
	fx.world.set_cells_covered(Rect2(0.0, 0.0, 32.0, 32.0), false)
	assert_true(fx.world.promoted_node().visible)
	fx.world.set_selected("")
	assert_true(fx.world.batch_of("visible") != null)


func test_no_camera_still_upgrades_ready_placeholder() -> void:
	fx.world.set_camera(null)
	_put("headless", 1.0)
	_settle()
	assert_eq(fx.world.owner_of("headless").get_slice("|", 1), "near")


func test_zero_budget_defers_projection_and_delete_during_pass_is_safe() -> void:
	for index in 300:
		_put("item_%d" % index, 1.0)
	var before := int(fx.world.stats().lod_evaluations)
	fx.world.service_frame(0.0)
	assert_eq(int(fx.world.stats().lod_evaluations), before)
	assert_eq(fx.world.owner_of("item_0"), "")
	fx.world.service_frame(0.1)
	for index in 300:
		fx.world.remove("item_%d" % index)
	_settle()
	assert_eq(int(fx.world.stats().canonical_instances), 0)


func test_promoting_hidden_record_preserves_size_reason_on_demote() -> void:
	_put("tiny", 0.001)
	_settle()
	assert_eq(fx.world.owner_of("tiny"), "")
	fx.world.set_selected("tiny")
	assert_true(fx.world.promoted_node().visible)
	fx.world.set_selected("")
	assert_eq(fx.world.owner_of("tiny"), "")
	assert_false(fx.world.is_object_visible("tiny"))
	assert_eq(int(fx.world.stats().canonical_instances), 1)


func test_ready_downgrade_is_prompt_upgrade_waits_for_settle_and_pin_keeps_tier() -> void:
	_put("tree", 2.0)
	_settle()
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "near")
	fx.set_profile(fx.profile.merged({"settle_ms": 250}, true))
	fx.aim(Vector3(16.0, 10.0, 1500.0), Vector3(16.0, 5.0, 16.0))
	fx.world.service_frame(10.0)
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "far")
	fx.aim(Vector3(16.0, 10.0, 60.0), Vector3(16.0, 5.0, 16.0))
	fx.world.service_frame(10.0)
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "far")
	OS.delay_msec(260)
	_settle()
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "near")
	var pinned := {Vector2i(0, 0): true}
	fx.world.set_pin_check(func(cell: Vector2i) -> bool: return pinned.has(cell))
	fx.aim(Vector3(16.0, 10.0, 1500.0), Vector3(16.0, 5.0, 16.0))
	fx.world.service_frame(10.0)
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "near")
	pinned.clear()
	fx.world.service_frame(10.0)
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "far")


func test_comparison_policy_toggle_converges_without_losing_membership() -> void:
	_put("large", 2.0)
	_put("tiny", 0.001)
	_settle()
	fx.set_profile(fx.profile.merged({"size_policy_enabled": false}, true))
	_settle()
	assert_true(fx.world.batch_of("tiny") != null)
	fx.set_profile(fx.profile.merged({"size_policy_enabled": true}, true))
	_settle()
	assert_eq(fx.world.owner_of("tiny"), "")
	assert_eq(int(fx.world.stats().canonical_instances), 2)
	assert_true(fx.world.batch_of("large") != null)


func test_queued_record_is_not_pickable_until_it_has_a_submitted_owner() -> void:
	var record := fx.add(OverviewFixture.SPRUCE, Vector3(16.0, 0.0, 16.0))
	fx.sync_all()
	var bounds := fx.presenter.world_bounds(record.object_id)
	var center := bounds.get_center()
	var origin := center + Vector3(0.0, 0.0, 50.0)
	assert_eq(fx.world.owner_of(record.object_id), "")
	assert_false(fx.world.is_object_visible(record.object_id))
	assert_eq(fx.presenter.pick(origin, Vector3.FORWARD).id, "")
	_settle()
	assert_true(fx.world.is_object_visible(record.object_id))
	assert_eq(fx.presenter.pick(origin, Vector3.FORWARD).id, record.object_id)


func test_behind_and_size_hidden_counters_are_distinct_and_reset_on_remove() -> void:
	_put("tiny", 0.001)
	_put("behind", 1.0, Vector3(16.0, 0.0, 200.0))
	_settle()
	assert_eq(int(fx.world.stats().size_hidden_instances), 1)
	assert_eq(int(fx.world.stats().behind_hidden_instances), 1)
	assert_false(fx.world.is_object_visible("behind"))
	_put("behind", 1.0)
	_settle()
	assert_eq(int(fx.world.stats().size_hidden_instances), 1)
	assert_eq(int(fx.world.stats().behind_hidden_instances), 0)
	fx.world.remove("tiny")
	assert_eq(int(fx.world.stats().size_hidden_instances), 0)
	fx.world.clear()
	assert_eq(int(fx.world.stats().behind_hidden_instances), 0)


func test_deferred_upgrade_retries_only_held_record_instead_of_whole_world() -> void:
	_put("tree", 2.0)
	for index in 32:
		_put("small_%d" % index, 0.1)
	_settle()
	fx.set_profile(fx.profile.merged({"settle_ms": 250}, true))
	fx.aim(Vector3(16.0, 10.0, 1500.0), Vector3(16.0, 5.0, 16.0))
	fx.world.service_frame(100.0)
	fx.aim(Vector3(16.0, 10.0, 60.0), Vector3(16.0, 5.0, 16.0))
	fx.world.service_frame(100.0)
	var before := int(fx.world.stats().lod_evaluations)
	var state: Dictionary = fx.world.stats().classification
	assert_eq(int(state.remaining), 0)
	assert_false(bool(state.pass_requested))
	assert_eq(int(state.retries), 1)
	fx.world.service_frame(100.0)
	assert_eq(int(fx.world.stats().lod_evaluations), before)
	OS.delay_msec(260)
	fx.world.service_frame(100.0)
	assert_eq(int(fx.world.stats().lod_evaluations), before + 1)
	assert_false(fx.world.has_pending_work())
	assert_eq(fx.world.owner_of("tree").get_slice("|", 1), "near")


func test_focus_record_appended_last_precedes_world_pass_without_starving_distant_records() -> void:
	for index in 1024:
		_put("distant_%d" % index, 1.0, Vector3(1000.0, 0.0, 16.0))
	_put("focus_last", 1.0)
	fx.world.service_frame(1000.0)
	assert_true(fx.world._size_visibility.roles.has("focus_last"))
	assert_true(fx.world._size_visibility.roles.has("distant_0"))
	assert_false(fx.world._size_visibility.roles.has("distant_1023"))
	assert_true(fx.world.has_pending_work())


func test_selected_edit_cell_precedes_distant_world_pass() -> void:
	for index in 1024:
		_put("distant_%d" % index, 1.0, Vector3(1000.0, 0.0, 16.0))
	_put("edit_neighbor", 1.0, Vector3(-1000.0, 0.0, 16.0))
	_put("selected", 1.0, Vector3(-1000.0, 0.0, 16.0))
	fx.world.set_selected("selected")
	fx.world.service_frame(1000.0)
	assert_true(fx.world._size_visibility.roles.has("edit_neighbor"))
	assert_false(fx.world._size_visibility.roles.has("distant_1023"))
	assert_eq(fx.world.owner_of("selected"), "promoted")


func test_single_record_turns_rotate_between_priority_global_and_held_pin() -> void:
	_put("distant", 1.0, Vector3(1000.0, 0.0, 16.0))
	_put("focus", 1.0)
	var visibility := fx.world._size_visibility
	visibility._remaining = 2
	visibility._again = false
	visibility._pinned_retries["focus"] = true
	visibility._priority_lane.set_focus(Vector2i.ZERO, null)
	var deadline := Time.get_ticks_usec() + 1000000
	assert_eq(visibility._next_record(true, deadline), "focus")
	# Simulate a frame that can classify only one ID before its deadline.
	assert_eq(visibility._next_record(true, deadline), "distant")
	assert_eq(visibility._next_record(true, deadline), "focus")
	visibility._pinned_retries["focus"] = true
	assert_eq(visibility._next_record(true, deadline), "")
	assert_eq(visibility._next_record(true, deadline), "")
	assert_eq(visibility._next_record(true, deadline), "focus")
	assert_eq(visibility._remaining, 0)


func test_priority_cell_index_tracks_move_delete_and_reinsert() -> void:
	var lane := ObjectVisibilityPriority.new()
	var cells := {Vector2i.ZERO: true, Vector2i(30, 0): true}
	lane.upsert("moved", Vector2i(30, 0))
	lane.upsert("removed", Vector2i.ZERO)
	lane.upsert("moved", Vector2i.ZERO)
	lane.remove("removed")
	lane.set_focus(Vector2i.ZERO, null)
	var deadline := Time.get_ticks_usec() + 1000000
	assert_eq(lane.next(cells, {}, deadline), "moved")
	assert_eq(lane.next(cells, {}, deadline), "")
	lane.remove("moved")
	lane.upsert("reinserted", Vector2i.ZERO)
	lane.restart()
	assert_eq(lane.next(cells, {}, deadline), "reinserted")


func test_camera_change_rechecks_focus_before_world_pass_completes() -> void:
	_zoom_during_pass(5.0)


func test_camera_change_with_same_focus_rechecks_old_generation_before_world_pass_completes() -> void:
	_zoom_during_pass(0.0)


func _zoom_during_pass(target_y: float) -> void:
	_put("focus_first", 0.01)
	for index in 1024:
		_put("distant_%d" % index, 1.0, Vector3(1000.0, 0.0, 16.0))
	fx.aim(Vector3(16.0, 100.0 if target_y == 0.0 else 10.0, 1500.0), Vector3(16.0, target_y, 16.0))
	fx.world.service_frame(1000.0)
	assert_true(fx.world._size_visibility.hidden.has("focus_first"))
	assert_true(int(fx.world.stats().classification.remaining) > 0)
	var previous_focus := fx.world._focus
	var bounds := fx.world._bounds(OverviewFixture.SPRUCE)
	fx.aim(Vector3(16.0, 6.0, 20.0), Vector3(16.0, target_y, 16.0))
	var snapshot := RenderCameraSnapshot.capture(fx.camera)
	var measure := ProjectedBounds.measure((fx.world._xf["focus_first"] as Transform3D) * bounds, snapshot)
	assert_true(float(measure.reference_px) > 3.0 or measure.conservative, "near fixture footprint=%s" % measure.reference_px)
	fx.world.service_frame(1000.0)
	assert_true(int(fx.world.stats().classification.remaining) > 0)
	if target_y == 0.0:
		assert_true(previous_focus.is_equal_approx(fx.world._focus), "old focus=%s new focus=%s" % [previous_focus, fx.world._focus])
	assert_false(fx.world._size_visibility.hidden.has("focus_first"), "focus object must reclassify under changed camera before the background pass completes")


func test_priority_generation_changes_preserve_near_record_rotation() -> void:
	var lane := ObjectVisibilityPriority.new()
	var cells := {Vector2i.ZERO: true}
	var seen: Dictionary = {}
	for id: String in ["first", "second", "third"]:
		lane.upsert(id, Vector2i.ZERO)
	lane.set_focus(Vector2i.ZERO, null)
	var deadline := Time.get_ticks_usec() + 1000000
	for generation in range(1, 5):
		var expected: String = ["first", "second", "third", "first"][generation - 1]
		var id := lane.next(cells, seen, deadline, generation)
		assert_eq(id, expected)
		seen[id] = generation
