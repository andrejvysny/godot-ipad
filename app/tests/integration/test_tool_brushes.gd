extends TestCase
## Paint / sculpt / path tools through ToolController (spec §12, §13, §15; TE-09..TE-12, IN-08, PA-00).

const LOC := Vector2i(0, 0)

var h: ToolHarness


func before_each() -> void:
	h = ToolHarness.new()
	var err := h.setup(tree)
	assert_empty_string(err, "harness setup")


func after_each() -> void:
	h.teardown()


## Drags in a straight line along z from x0 to x1 (inclusive), 2 m per move, 20 ms apart.
func _drag(z: float, x0: float, x1: float, t0: float = 1.0) -> float:
	var t := t0
	h.act("tool_begin", h.at(x0, z, t))
	var x := x0
	while x < x1:
		x = minf(x + 2.0, x1)
		t += 0.02
		h.act("tool_move", h.at(x, z, t))
	h.act("tool_end", h.at(x1, z, t + 0.02))
	return t + 0.02


func _changed_samples(before: PackedInt32Array, after: PackedInt32Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in before.size():
		if before[i] != after[i]:
			out.append(Vector2((i % 256) * WorldConstants.SAMPLE_SPACING, (i / 256) * WorldConstants.SAMPLE_SPACING))
	return out


func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))


func _blend(x: float, z: float) -> float:
	return ControlCodec.dirt_blend01(doc_control(x, z))


func doc_control(x: float, z: float) -> int:
	return h.doc.get_control_at_sample(int(roundf(x / 0.5)), int(roundf(z / 0.5))) & 0xFFFFFFFF


func test_paint_dirt_stroke_is_one_change_limited_to_radius_and_undoable() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	var before := h.control_snapshot()
	_drag(40.0, 30.0, 50.0)
	assert_eq(h.commits.size(), 1, "exactly one commit")
	assert_eq(h.finished.size(), 1)
	assert_eq(h.commits[0].label, "Paint dirt")
	assert_eq(h.history.size(), 1)
	var changed := _changed_samples(before[LOC], h.doc.get_region(LOC).control)
	assert_true(changed.size() > 20, "dirt was painted")
	var worst := 0.0
	for p in changed:
		worst = maxf(worst, _dist_to_segment(p, Vector2(30, 40), Vector2(50, 40)))
	assert_true(worst <= 4.05, "changes stay within brush radius, worst %.3f" % worst)
	assert_true(h.terrain.marked(TerrainView.MAP_CONTROL).has(LOC))
	assert_true(h.terrain.marked(TerrainView.MAP_HEIGHT).is_empty(), "paint never marks heights")
	h.history.undo(h.doc)
	assert_eq(h.doc.get_region(LOC).control, before[LOC], "undo restores exact bytes")


func test_paint_grass_target_reduces_blend() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	_drag(40.0, 30.0, 50.0)
	var dirt := _blend(40, 40)
	assert_true(dirt > 0.3, "dirt applied %.3f" % dirt)
	assert_empty_string(h.ctrl.set_setting("paint", "material", "grass"))
	_drag(40.0, 30.0, 50.0, 5.0)
	assert_eq(h.commits.size(), 2)
	assert_eq(h.commits[1].label, "Paint grass")
	assert_true(_blend(40, 40) < dirt, "grass reduced blend")


func test_path_paints_inside_half_width_only_and_never_touches_objects() -> void:
	var rock := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	var lodge := h.add_object(ToolHarness.LODGE, 40.0, 50.0)
	var before_rock := rock.clone()
	var before_lodge := lodge.clone()
	var before := h.control_snapshot()
	h.ctrl.set_active_tool(ToolController.TOOL_PATH)
	_drag(40.0, 30.0, 50.0)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Path")
	assert_true(_blend(40, 40) > 0.9, "centre is dirt")
	assert_eq(doc_control(40, 43), before[LOC][int(43.0 / 0.5) * 256 + 80] & 0xFFFFFFFF, "3 m away untouched")
	for p in _changed_samples(before[LOC], h.doc.get_region(LOC).control):
		assert_true(_dist_to_segment(p, Vector2(30, 40), Vector2(50, 40)) <= 1.55, "inside width/2")
	assert_eq(h.doc.objects.size(), 2, "PA-00: no object deleted")
	assert_true(h.doc.get_object(rock.object_id).equals(before_rock), "PA-00: boulder unchanged")
	assert_true(h.doc.get_object(lodge.object_id).equals(before_lodge), "PA-00: lodge unchanged")
	assert_true(h.commits[0].before_objects.is_empty())
	h.history.undo(h.doc)
	assert_eq(h.doc.get_region(LOC).control, before[LOC])


func test_pause_resume_never_bridges_the_gap() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	h.act("tool_begin", h.at(20, 40, 1.0))
	h.act("tool_move", h.at(21, 40, 1.02))
	h.act("tool_pause", h.at(21, 40, 1.04))
	var mid_before := doc_control(40, 40)
	h.act("tool_resume", h.at(60, 40, 1.5))
	h.act("tool_move", h.at(61, 40, 1.52))
	h.act("tool_end", h.at(61, 40, 1.54))
	assert_eq(doc_control(40, 40), mid_before, "midpoint of the gap unchanged (IN-08)")
	assert_ne(doc_control(20, 40), ControlCodec.grass_value(), "A painted")
	assert_ne(doc_control(60, 40), ControlCodec.grass_value(), "B painted")
	assert_eq(h.commits.size(), 1)


func test_invalid_hit_writes_nothing_and_creates_no_regions() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	h.act("tool_begin", h.at(40, 40, 1.0))
	var snap := h.control_snapshot()
	var marks := h.terrain.marks.size()
	h.act("tool_move", h.sky(1.02))
	assert_false(h.ctrl.last_hit().ok, "sky hit is invalid")
	assert_eq(h.control_snapshot(), snap, "no writes for an invalid hit")
	assert_eq(h.terrain.marks.size(), marks, "no new dirty regions")
	assert_eq(h.doc.regions.size(), 4)
	h.act("tool_end", h.sky(1.04), true)
	assert_eq(h.commits.size(), 1, "the begin dab still commits")


func test_begin_on_sky_waits_for_first_valid_hit() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	var before := h.control_snapshot()
	h.act("tool_begin", h.sky(1.0))
	assert_true(h.ctrl.has_active_operation())
	h.act("tool_end", h.sky(1.1))
	assert_eq(h.control_snapshot(), before)
	assert_eq(h.commits.size(), 0, "nothing to commit")


func _hold_sculpt(x: float, z: float, t0: float, t1: float) -> void:
	h.act("tool_begin", h.at(x, z, t0))
	var t := t0
	while t < t1:
		t = minf(t + 1.0 / 60.0, t1)
		h.ctrl.advance(t)
	h.act("tool_end", h.at(x, z, t1))


func test_sculpt_raise_regrounds_follow_terrain_objects_in_one_change() -> void:
	var boulder := h.add_object(ToolHarness.BOULDER, 42.0, 40.0, 0.2)
	var lodge := h.add_object(ToolHarness.LODGE, 46.0, 40.0)
	var tree_far := h.add_object(ToolHarness.SPRUCE, 90.0, 90.0)
	var boulder_before := boulder.clone()
	var lodge_before := lodge.clone()
	var far_before := tree_far.clone()
	var heights_before := h.height_snapshot()
	h.ctrl.set_active_tool(ToolController.TOOL_SCULPT)
	_hold_sculpt(42.0, 40.0, 1.0, 1.5)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Raise terrain")
	assert_true(h.doc.sample_height(42, 40) > float(heights_before[LOC][80 * 256 + 84]) + 0.1, "terrain raised")
	var moved := h.doc.get_object(boulder.object_id)
	assert_near(moved.position[1], h.doc.sample_height(42, 40) + 0.2, 1e-9, "boulder follows ground + offset")
	assert_true(moved.position[1] > boulder_before.position[1] + 0.1, "boulder moved up")
	assert_true(h.doc.get_object(lodge.object_id).equals(lodge_before), "WORLD_FIXED lodge unchanged")
	assert_true(h.doc.get_object(tree_far.object_id).equals(far_before), "far object unchanged")
	var change := h.commits[0]
	assert_true(change.before_objects.has(boulder.object_id), "change contains the boulder")
	assert_false(change.before_objects.has(lodge.object_id))
	assert_true(change.before_heights.has(LOC))
	h.history.undo(h.doc)
	assert_eq(h.height_snapshot(), heights_before, "undo restores heights")
	assert_true(h.doc.get_object(boulder.object_id).equals(boulder_before), "undo restores boulder exactly")


func test_sculpt_lower_label_and_direction() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_SCULPT)
	assert_empty_string(h.ctrl.set_setting("sculpt", "direction", "lower"))
	var before := h.doc.sample_height(40, 40)
	_hold_sculpt(40.0, 40.0, 1.0, 1.4)
	assert_eq(h.commits[0].label, "Lower terrain")
	assert_true(h.doc.sample_height(40, 40) < before - 0.1)


func test_cancel_after_touching_all_regions_restores_authored_hash() -> void:
	var before := CanonicalEncoder.authored_hash(h.doc)
	h.ctrl.set_active_tool(ToolController.TOOL_SCULPT)
	assert_empty_string(h.ctrl.set_setting("sculpt", "radius", 12.0))
	h.act("tool_begin", h.at(0.0, 0.0, 1.0))
	var t := 1.0
	while t < 1.4:
		t += 1.0 / 60.0
		h.ctrl.advance(t)
	assert_eq(h.terrain.marked(TerrainView.MAP_HEIGHT).size(), 4, "all four regions touched")
	assert_ne(CanonicalEncoder.authored_hash(h.doc), before)
	var cancelled: Array[String] = []
	h.ctrl.operation_cancelled.connect(func(r: String) -> void: cancelled.append(r))
	h.ctrl.handle_tool_action({"type": "tool_cancel", "reason": "native_cancel"})
	assert_eq(CanonicalEncoder.authored_hash(h.doc), before, "TE-12 exact rollback")
	assert_eq(h.commits.size(), 0)
	assert_eq(cancelled, ["native_cancel"])
	assert_false(h.ctrl.has_active_operation())


func test_frame_stall_cancels_and_rolls_back() -> void:
	var before := CanonicalEncoder.authored_hash(h.doc)
	h.ctrl.set_active_tool(ToolController.TOOL_SCULPT)
	h.act("tool_begin", h.at(40.0, 40.0, 1.0))
	var t := 1.0
	while t < 1.2:
		t += 1.0 / 60.0
		h.ctrl.advance(t)
	assert_ne(CanonicalEncoder.authored_hash(h.doc), before, "work was applied before the stall")
	h.ctrl.advance(t + 1.0)
	assert_eq(h.cancels, ["tool_error"], "request_cancel called")
	assert_eq(h.diagnostics, ["Stroke cancelled: frame stall over 250 ms."])
	assert_eq(CanonicalEncoder.authored_hash(h.doc), before, "rollback complete")
	assert_false(h.ctrl.has_active_operation())
	assert_eq(h.commits.size(), 0)


func test_settings_clamp_and_validate() -> void:
	assert_empty_string(h.ctrl.set_setting("sculpt", "radius", 99.0))
	assert_eq(h.ctrl.settings("sculpt").radius, 16.0)
	assert_empty_string(h.ctrl.set_setting("paint", "radius", 0.1))
	assert_eq(h.ctrl.settings("paint").radius, 1.0)
	assert_empty_string(h.ctrl.set_setting("path", "width", 10))
	assert_eq(h.ctrl.settings("path").width, 6.0)
	assert_empty_string(h.ctrl.set_setting("paint", "strength", 0.0))
	assert_eq(h.ctrl.settings("paint").strength, 0.05)
	assert_error_contains(h.ctrl.set_setting("paint", "material", "lava"), "paint.material")
	assert_error_contains(h.ctrl.set_setting("sculpt", "direction", "sideways"), "sculpt.direction")
	assert_error_contains(h.ctrl.set_setting("paint", "radius", NAN), "paint.radius")
	assert_error_contains(h.ctrl.set_setting("place", "asset_id", "no.such"), "no.such")
	assert_empty_string(h.ctrl.set_setting("place", "asset_id", ToolHarness.BOULDER))
	assert_error_contains(h.ctrl.set_setting("paint", "bogus", 1), "bogus")
	var copy := h.ctrl.settings("paint")
	copy.radius = 12.0
	assert_ne(h.ctrl.settings("paint").radius, 12.0, "settings() returns a copy")


func test_setting_change_does_not_affect_stroke_in_progress() -> void:
	h.ctrl.set_active_tool(ToolController.TOOL_PAINT)
	assert_empty_string(h.ctrl.set_setting("paint", "radius", 2.0))
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_empty_string(h.ctrl.set_setting("paint", "radius", 16.0))
	h.act("tool_move", h.at(42, 40, 1.02))
	h.act("tool_end", h.at(42, 40, 1.04))
	assert_eq(doc_control(40, 46), ControlCodec.grass_value(), "radius stayed 2 m")
