extends TestCase
## Place / select / move / object edits through ToolController (spec §14; OB-01..OB-05, TE-10).

var h: ToolHarness


func before_each() -> void:
	h = ToolHarness.new()
	var err := h.setup(tree)
	assert_empty_string(err, "harness setup")


func after_each() -> void:
	h.teardown()


func _place_tool(asset_id: String = ToolHarness.BOULDER) -> void:
	assert_empty_string(h.ctrl.set_setting("place", "asset_id", asset_id))
	assert_empty_string(h.ctrl.set_active_tool(ToolController.TOOL_PLACE))


func _selected_boulder(offset: float = 0.0) -> ObjectRecord:
	var rec := h.add_object(ToolHarness.BOULDER, 40.0, 40.0, offset)
	h.ctrl.select(rec.object_id)
	return rec


func _above(rec: ObjectRecord, t: float, dx: float = 0.0, dz: float = 0.0) -> PointerSample:
	return h.aim(rec.get_position_v3() + Vector3(dx, 0.3, dz), t)


func _yaw_deg(rec: ObjectRecord) -> float:
	return rad_to_deg(rec.get_yaw())


# --- Place -------------------------------------------------------------------------------

func test_place_snaps_selects_and_returns_to_select_tool() -> void:
	_place_tool()
	h.act("tool_begin", h.at(40.2, 40.3, 1.0))
	h.act("tool_move", h.at(40.2, 40.3, 1.02))
	assert_true(h.presenter.has_ghost_visible(), "ghost during drag")
	assert_eq(h.doc.objects.size(), 0, "document untouched during the drag")
	h.act("tool_end", h.at(40.2, 40.3, 1.04))
	assert_eq(h.doc.objects.size(), 1)
	assert_eq(h.commits.size(), 1)
	var rec: ObjectRecord = h.doc.objects.values()[0]
	assert_eq(h.commits[0].label, "Place " + h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	assert_eq(rec.position[0], 40.0, "x snapped")
	assert_eq(rec.position[2], 40.5, "z snapped")
	assert_near(rec.position[1], h.doc.sample_height(40.0, 40.5), 1e-9, "y on terrain")
	assert_eq(rec.grounding, WorldConstants.GROUNDING_FOLLOW)
	assert_eq(rec.origin, WorldConstants.ORIGIN_MANUAL)
	assert_eq(h.ctrl.selected_id(), rec.object_id)
	assert_eq(h.ctrl.active_tool(), ToolController.TOOL_SELECT)
	assert_false(h.presenter.has_ghost_visible())
	var anchor := h.catalog.get_asset(ToolHarness.BOULDER).anchor_local
	assert_vec_near(h.presenter.node_for(rec.object_id).transform * anchor, rec.get_position_v3(), 1e-5, "OB-01")
	h.history.undo(h.doc)
	assert_eq(h.doc.objects.size(), 0, "undo removes the object")


func test_place_without_snap_keeps_hit_position() -> void:
	h.ctrl.set_snap_enabled(false)
	_place_tool()
	var s := h.at(40.2, 40.3, 1.0)
	h.act("tool_begin", s)
	h.act("tool_end", s)
	var rec: ObjectRecord = h.doc.objects.values()[0]
	assert_near(rec.position[0], h.ctrl.last_hit().position.x, 1e-9)
	assert_near(rec.position[2], h.ctrl.last_hit().position.z, 1e-9)


func test_place_released_over_ui_or_sky_creates_nothing() -> void:
	_place_tool()
	h.act("tool_begin", h.at(40, 40, 1.0))
	h.act("tool_end", h.at(40, 40, 1.02), true)
	assert_eq(h.doc.objects.size(), 0, "over UI")
	assert_eq(h.diagnostics, ["Placement cancelled: lift the Pencil over terrain to place."])
	assert_false(h.presenter.has_ghost_visible())
	h.act("tool_begin", h.at(40, 40, 2.0))
	h.act("tool_move", h.sky(2.02))
	assert_false(h.presenter.ghost_valid(), "ghost turns invalid")
	h.act("tool_end", h.sky(2.04))
	assert_eq(h.doc.objects.size(), 0, "sky")
	assert_eq(h.commits.size(), 0)
	assert_eq(h.ctrl.active_tool(), ToolController.TOOL_PLACE, "tool stays for another try")


func test_place_after_sculpt_uses_the_new_height() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_SCULPT)
	h.act("tool_begin", h.at(40, 40, 1.0))
	var t := 1.0
	while t < 1.5:
		t += 1.0 / 60.0
		h.ctrl.advance(t)
	h.act("tool_end", h.at(40, 40, t + 0.01))
	var raised := h.doc.sample_height(40, 40)
	_place_tool()
	h.act("tool_begin", h.at(40, 40, 3.0))
	h.act("tool_end", h.at(40, 40, 3.02))
	var rec: ObjectRecord = h.doc.objects.values()[0]
	assert_near(rec.position[1], raised, 1e-9, "TE-10")


func test_place_without_asset_is_refused() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PLACE)
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_eq(h.diagnostics, ["Choose an asset in the Library first."])
	assert_false(h.ctrl.has_active_operation())
	h.act("tool_move", h.at(41, 40, 1.02))
	h.act("tool_end", h.at(41, 40, 1.04))
	assert_eq(h.doc.objects.size(), 0)


func test_place_ignores_existing_objects() -> void:
	h.add_object(ToolHarness.LODGE, 40.0, 40.0)
	_place_tool(ToolHarness.SPRUCE)
	var s := h.at(40, 40, 1.0)
	h.act("tool_begin", s)
	h.act("tool_end", s)
	assert_eq(h.doc.objects.size(), 2, "OB-04: overlap does not block placement")
	assert_near(h.doc.get_object(h.ctrl.selected_id()).position[1], h.doc.sample_height(40, 40), 1e-9)


# --- Select and move -----------------------------------------------------------------------

func test_tap_selects_and_tap_on_terrain_clears() -> void:
	var rec := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	var changes: Array[String] = []
	h.ctrl.selection_changed.connect(func(id: String) -> void: changes.append(id))
	var on := _above(rec, 1.0)
	h.act("tool_begin", on)
	h.act("tool_end", on)
	assert_eq(h.ctrl.selected_id(), rec.object_id)
	assert_eq(h.presenter.selected_id(), rec.object_id)
	assert_eq(h.ctrl.selected_record().object_id, rec.object_id)
	var off := h.at(25, 25, 2.0)
	h.act("tool_begin", off)
	h.act("tool_end", off, true)
	assert_eq(h.ctrl.selected_id(), rec.object_id, "tap over UI changes nothing")
	h.act("tool_begin", off)
	h.act("tool_end", off)
	assert_eq(h.ctrl.selected_id(), "")
	assert_eq(changes, [rec.object_id, ""])
	assert_eq(h.commits.size(), 0, "selection is not history")


func test_drag_from_off_centre_moves_by_exact_hit_delta() -> void:
	h.ctrl.set_snap_enabled(false)
	var rec := _selected_boulder(0.2)
	var before := rec.clone()
	h.act("tool_begin", _above(rec, 1.0, 0.3, 0.2))
	var h0 := h.ctrl.last_hit().position
	h.act("tool_move", _above(rec, 1.02, 0.3, 0.2))
	assert_true(h.doc.get_object(rec.object_id).equals(before), "no movement inside the tap threshold")
	h.act("tool_move", h.at(52.0, 44.0, 1.04))
	var h1 := h.ctrl.last_hit().position
	var moved := h.doc.get_object(rec.object_id)
	assert_near(moved.position[0], before.position[0] + h1.x - h0.x, 1e-9, "no pivot jump x")
	assert_near(moved.position[2], before.position[2] + h1.z - h0.z, 1e-9, "no pivot jump z")
	assert_near(moved.position[1], h.doc.sample_height(moved.position[0], moved.position[2]) + 0.2, 1e-9)
	assert_eq(h.ctrl.stroke_state(), "Moving")
	h.act("tool_end", h.at(52.0, 44.0, 1.06))
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Move " + h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	h.history.undo(h.doc)
	assert_true(h.doc.get_object(rec.object_id).equals(before))


func test_cancel_mid_drag_restores_exact_record() -> void:
	var rec := _selected_boulder(0.4)
	var before := rec.clone()
	h.act("tool_begin", _above(rec, 1.0))
	h.act("tool_move", h.at(55.0, 55.0, 1.02))
	assert_false(h.doc.get_object(rec.object_id).equals(before), "moved during drag")
	h.ctrl.handle_tool_action({"type": "tool_cancel", "reason": "native_cancel"})
	assert_true(h.doc.get_object(rec.object_id).equals(before), "OB-03 exact restore")
	assert_eq(h.commits.size(), 0)
	assert_false(h.ctrl.has_active_operation())


func test_drop_over_ui_or_sky_reverts_move() -> void:
	var rec := _selected_boulder()
	var before := rec.clone()
	h.act("tool_begin", _above(rec, 1.0))
	h.act("tool_move", h.at(55.0, 55.0, 1.02))
	h.act("tool_end", h.at(55.0, 55.0, 1.04), true)
	assert_true(h.doc.get_object(rec.object_id).equals(before))
	assert_eq(h.diagnostics, ["Move cancelled: lift the Pencil over terrain to drop the object."])
	assert_eq(h.commits.size(), 0)
	h.act("tool_begin", _above(rec, 2.0))
	h.act("tool_move", h.at(55.0, 55.0, 2.02))
	h.act("tool_end", h.sky(2.04))
	assert_true(h.doc.get_object(rec.object_id).equals(before), "sky drop reverts")


func test_drag_of_unselected_object_does_not_move_it() -> void:
	var rec := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	var before := rec.clone()
	h.act("tool_begin", _above(rec, 1.0))
	h.act("tool_move", h.at(55.0, 55.0, 1.02))
	h.act("tool_end", h.at(55.0, 55.0, 1.04))
	assert_true(h.doc.get_object(rec.object_id).equals(before))


# --- Object edits ----------------------------------------------------------------------------

func test_slider_drag_is_one_change_and_cancel_restores_exactly() -> void:
	var rec := _selected_boulder()
	var before := rec.clone()
	assert_empty_string(h.ctrl.begin_object_edit("yaw"))
	assert_true(h.ctrl.has_object_edit())
	assert_true(h.ctrl.has_active_operation())
	assert_eq(h.ctrl.stroke_state(), "Editing object")
	for deg in [10.0, 20.0, 37.0, 91.0]:
		assert_empty_string(h.ctrl.update_object_edit(deg))
	assert_near(_yaw_deg(h.doc.get_object(rec.object_id)), 90.0, 1e-9, "snapped to 15 degrees")
	h.ctrl.end_object_edit()
	assert_eq(h.commits.size(), 1, "one drag = one action")
	assert_eq(h.commits[0].label, "Rotate " + h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	assert_false(h.ctrl.has_object_edit())
	assert_empty_string(h.ctrl.begin_object_edit("scale"))
	assert_empty_string(h.ctrl.update_object_edit(2.0))
	var mid := h.doc.get_object(rec.object_id).clone()
	h.ctrl.cancel_object_edit()
	assert_eq(h.doc.get_object(rec.object_id).uniform_scale, 1.0, "scale restored")
	assert_false(h.doc.get_object(rec.object_id).equals(before), "earlier committed yaw stays")
	assert_eq(mid.uniform_scale, 2.0)
	assert_eq(h.commits.size(), 1, "cancel commits nothing")
	assert_eq(h.ctrl.selected_record().uniform_scale, 1.0)


func test_scale_is_clamped_and_non_finite_rejected() -> void:
	var rec := _selected_boulder()
	assert_empty_string(h.ctrl.begin_object_edit("scale"))
	assert_empty_string(h.ctrl.update_object_edit(100.0))
	assert_eq(h.doc.get_object(rec.object_id).uniform_scale, 3.0, "clamped to scale_max")
	assert_empty_string(h.ctrl.update_object_edit(0.01))
	assert_eq(h.doc.get_object(rec.object_id).uniform_scale, 0.3, "clamped to scale_min")
	assert_ne(h.ctrl.update_object_edit(NAN), "")
	assert_ne(h.ctrl.update_object_edit(INF), "")
	assert_ne(h.ctrl.update_object_edit(0.0), "")
	assert_ne(h.ctrl.update_object_edit(-2.0), "")
	assert_eq(h.doc.get_object(rec.object_id).uniform_scale, 0.3, "rejected values change nothing")
	h.ctrl.cancel_object_edit()


func test_height_edit_moves_object_with_offset() -> void:
	var rec := _selected_boulder()
	var y0 := rec.position[1]
	assert_empty_string(h.ctrl.begin_object_edit("height"))
	assert_empty_string(h.ctrl.update_object_edit(0.5))
	assert_empty_string(h.ctrl.update_object_edit(9.0))
	var edited := h.doc.get_object(rec.object_id)
	assert_eq(edited.height_offset_m, 1.5, "clamped to asset range")
	assert_near(edited.position[1], y0 + 1.5, 1e-9)
	h.ctrl.end_object_edit()
	assert_eq(h.commits.size(), 1)


func test_yaw_normalization_and_snap_off() -> void:
	var rec := ObjectRecord.new()
	ObjectEdits.apply_yaw(rec, 190.0, 0.0)
	assert_near(rad_to_deg(rec.get_yaw()), -170.0, 1e-9)
	ObjectEdits.apply_yaw(rec, 180.0, 0.0)
	assert_near(rad_to_deg(rec.get_yaw()), 180.0, 1e-9)
	ObjectEdits.apply_yaw(rec, -540.0, 15.0)
	assert_near(absf(rad_to_deg(rec.get_yaw())), 180.0, 1e-9)
	var s := _selected_boulder()
	h.ctrl.set_snap_enabled(false)
	h.ctrl.begin_object_edit("yaw")
	h.ctrl.update_object_edit(37.0)
	assert_near(_yaw_deg(h.doc.get_object(s.object_id)), 37.0, 1e-9, "no snap when off")
	h.ctrl.cancel_object_edit()


func test_nudge_is_one_action_and_clamped_nudge_is_a_no_op() -> void:
	var rec := _selected_boulder()
	assert_empty_string(h.ctrl.nudge("scale", 0.1))
	assert_near(h.doc.get_object(rec.object_id).uniform_scale, 1.1, 1e-12)
	assert_empty_string(h.ctrl.nudge("yaw", 15.0))
	assert_near(_yaw_deg(h.doc.get_object(rec.object_id)), 15.0, 1e-9)
	assert_empty_string(h.ctrl.nudge("height", 0.1))
	assert_near(h.doc.get_object(rec.object_id).height_offset_m, 0.1, 1e-12)
	assert_eq(h.commits.size(), 3)
	for i in 30:
		h.ctrl.nudge("scale", 0.1)
	var count := h.commits.size()
	assert_empty_string(h.ctrl.nudge("scale", 0.1))
	assert_eq(h.commits.size(), count, "no change at the limit commits nothing")
	assert_ne(h.ctrl.nudge("sparkle", 1.0), "")


func test_set_grounding_regrounds_and_undoes() -> void:
	var lodge := h.add_object(ToolHarness.LODGE, 40.0, 40.0, 0.5)
	h.ctrl.select(lodge.object_id)
	h.doc.get_region(Vector2i(0, 0)).heights[80 * 256 + 80] += 2.0
	var before := h.doc.get_object(lodge.object_id).clone()
	assert_empty_string(h.ctrl.set_grounding(WorldConstants.GROUNDING_FOLLOW))
	var now := h.doc.get_object(lodge.object_id)
	assert_eq(now.grounding, WorldConstants.GROUNDING_FOLLOW)
	assert_near(now.position[1], h.doc.sample_height(40, 40) + 0.5, 1e-9)
	assert_eq(h.commits.size(), 1)
	assert_empty_string(h.ctrl.set_grounding(WorldConstants.GROUNDING_FIXED))
	assert_eq(h.doc.get_object(lodge.object_id).position[1], now.position[1], "FIXED keeps y")
	assert_ne(h.ctrl.set_grounding("FLOATING"), "")
	h.history.undo(h.doc)
	h.history.undo(h.doc)
	assert_true(h.doc.get_object(lodge.object_id).equals(before))


func test_delete_and_undo_restore_same_id_and_transform() -> void:
	var rec := _selected_boulder(0.3)
	rec = h.doc.get_object(rec.object_id)
	h.ctrl.begin_object_edit("yaw")
	h.ctrl.update_object_edit(45.0)
	h.ctrl.end_object_edit()
	var before := h.doc.get_object(rec.object_id).clone()
	assert_empty_string(h.ctrl.delete_selected())
	assert_eq(h.doc.objects.size(), 0)
	assert_eq(h.ctrl.selected_id(), "")
	assert_true(h.presenter.node_for(rec.object_id) == null, "node removed")
	assert_eq(h.commits.back().label, "Delete " + h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	h.history.undo(h.doc)
	h.presenter.sync_object(h.doc, rec.object_id)
	assert_true(h.doc.get_object(rec.object_id).equals(before), "OB-05 same id and transform")
	assert_ne(h.ctrl.delete_selected(), "", "nothing selected")


func test_validate_selection_clears_vanished_object() -> void:
	var rec := _selected_boulder()
	h.doc.remove_object(rec.object_id)
	h.ctrl.validate_selection()
	assert_eq(h.ctrl.selected_id(), "")
	h.ctrl.select("not-an-object")
	assert_eq(h.ctrl.selected_id(), "")


# --- Controller guards -----------------------------------------------------------------------

func test_tool_switch_refused_while_operation_active() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_eq(h.ctrl.stroke_state(), "Painting")
	assert_ne(h.ctrl.set_active_tool(ToolController.TOOL_SELECT), "")
	assert_eq(h.ctrl.active_tool(), ToolController.TOOL_PAINT)
	assert_ne(h.ctrl.begin_object_edit("yaw"), "")
	assert_ne(h.ctrl.set_document(h.doc), "")
	h.act("tool_end", h.at(40, 40, 1.02))
	assert_eq(h.ctrl.stroke_state(), "Idle")
	assert_empty_string(h.ctrl.set_active_tool(ToolController.TOOL_SELECT))
	assert_error_contains(h.ctrl.set_active_tool("lasso"), "lasso")


func test_object_edit_refused_without_selection_or_during_edit() -> void:
	assert_ne(h.ctrl.begin_object_edit("yaw"), "")
	_selected_boulder()
	assert_empty_string(h.ctrl.begin_object_edit("yaw"))
	assert_ne(h.ctrl.begin_object_edit("scale"), "")
	assert_ne(h.ctrl.nudge("scale", 0.1), "")
	assert_ne(h.ctrl.set_active_tool(ToolController.TOOL_PAINT), "")
	h.ctrl.cancel_active("test")
	assert_false(h.ctrl.has_active_operation())


func test_editing_disabled_ignores_begin_but_not_cancel() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	h.ctrl.editing_enabled = false
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_false(h.ctrl.has_active_operation())
	h.ctrl.editing_enabled = true
	var before := h.control_snapshot()
	h.act("tool_begin", h.at(40, 40, 2.0))
	h.ctrl.editing_enabled = false
	h.act("tool_move", h.at(44, 40, 2.02))
	h.ctrl.handle_tool_action({"type": "tool_cancel", "reason": "disabled"})
	assert_false(h.ctrl.has_active_operation())
	assert_eq(h.control_snapshot(), before, "cancel still rolls back")


func test_cancel_active_rolls_back_pointer_operation() -> void:
	var before := CanonicalEncoder.authored_hash(h.doc)
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_ne(CanonicalEncoder.authored_hash(h.doc), before)
	h.ctrl.cancel_active("background")
	assert_eq(CanonicalEncoder.authored_hash(h.doc), before)
	assert_false(h.ctrl.has_active_operation())


# --- Library drops -------------------------------------------------------------------------

func _pos(x: float, z: float) -> Vector2:
	return h.at(x, z, 0.0).position_viewport


func test_library_drop_places_selects_and_ignores_router_actions() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.BOULDER))
	assert_true(h.ctrl.has_drop() and h.ctrl.has_active_operation())
	assert_eq(h.ctrl.settings("place").asset_id, ToolHarness.BOULDER, "drop remembers the asset")
	assert_eq(h.ctrl.stroke_state(), "Placing")
	h.ctrl.update_drop(_pos(40.2, 40.3), false)
	assert_true(h.presenter.has_ghost_visible() and h.presenter.ghost_valid())
	h.ctrl.update_drop(_pos(40.2, 40.3), true)
	assert_false(h.presenter.ghost_valid(), "over a panel the ghost is invalid")
	h.act("tool_begin", h.at(10, 10, 1.0))
	h.act("tool_end", h.at(10, 10, 1.02))
	assert_true(h.ctrl.has_drop(), "router tool actions never touch a drop")
	assert_eq(h.doc.objects.size(), 0, "document untouched during the drag")
	h.ctrl.update_drop(_pos(40.2, 40.3), false)
	h.ctrl.finish_drop(_pos(40.2, 40.3), false)
	assert_false(h.ctrl.has_drop() or h.ctrl.has_active_operation())
	assert_eq(h.commits.size(), 1)
	var rec: ObjectRecord = h.doc.objects.values()[0]
	assert_eq(rec.position[0], 40.0, "x snapped")
	assert_eq(rec.position[2], 40.5, "z snapped")
	assert_eq(h.ctrl.selected_id(), rec.object_id)
	assert_eq(h.ctrl.active_tool(), ToolController.TOOL_SELECT)
	assert_false(h.presenter.has_ghost_visible())
	h.ctrl.finish_drop(_pos(40, 40), false)
	assert_eq(h.commits.size(), 1, "finish after close is a no-op")


func test_library_drop_over_ui_sky_or_cancel_creates_nothing() -> void:
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.SPRUCE))
	h.ctrl.update_drop(_pos(40, 40), false)
	h.ctrl.finish_drop(_pos(40, 40), true)
	assert_eq(h.doc.objects.size(), 0, "released over a panel")
	assert_false(h.presenter.has_ghost_visible())
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.SPRUCE))
	h.ctrl.finish_drop(h.sky(1.0).position_viewport, false)
	assert_eq(h.doc.objects.size(), 0, "released over sky without a valid hit")
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.SPRUCE))
	h.ctrl.update_drop(_pos(40, 40), false)
	h.ctrl.cancel_active("ui_cancel")
	assert_false(h.ctrl.has_drop() or h.presenter.has_ghost_visible())
	h.ctrl.finish_drop(_pos(40, 40), false)
	assert_eq(h.doc.objects.size(), 0, "finish after cancel is a no-op")
	assert_eq(h.commits.size(), 0)


func test_library_drop_refused_when_busy_disabled_or_unknown() -> void:
	assert_ne(h.ctrl.begin_drop("nature.rock.missing"), "")
	h.ctrl.editing_enabled = false
	assert_ne(h.ctrl.begin_drop(ToolHarness.BOULDER), "")
	h.ctrl.editing_enabled = true
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_eq(h.ctrl.begin_drop(ToolHarness.BOULDER), ToolController.BUSY)
	h.act("tool_end", h.at(40, 40, 1.02))
	assert_false(h.ctrl.has_drop())
