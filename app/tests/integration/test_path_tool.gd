extends TestCase
## Path tool through ToolController (docs/editor-v2.md §7): draw = spline path + flattened terrain
## + regrounded objects in one action, tap select, handle drag, delete. The old dirt-paint path
## preset (PA-00) is superseded by ADR 0009.

var h: ToolHarness
var path_events: Array = []
var scatter_events: Array = []
var _fixture_id := ""


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness setup")
	path_events = []
	scatter_events = []
	_fixture_id = h.doc.sorted_path_ids()[0]
	h.ctx.path_changed = func(ids: Array) -> void: path_events.append(ids)
	h.ctx.scatter_changed = func(rect: Rect2, heights_only: bool) -> void: scatter_events.append([rect, heights_only])
	assert_empty_string(h.ctrl.set_tool("path"))


func after_each() -> void:
	h.teardown()


## Straight 0.5 m-step stroke from a to b (x, z); returns the end time.
func _draw(a: Vector2, b: Vector2, over_ui: bool = false, t0: float = 1.0) -> float:
	var steps := ceili(a.distance_to(b) / 0.5)
	var t := t0
	h.act("tool_begin", h.at(a.x, a.y, t))
	for s in range(1, steps):
		t += 0.02
		var p := a.lerp(b, float(s) / float(steps))
		h.act("tool_move", h.at(p.x, p.y, t))
	h.act("tool_end", h.at(b.x, b.y, t + 0.02), over_ui)
	return t + 0.02


func _tap(p: Vector2) -> void:
	h.act("tool_begin", h.at(p.x, p.y, 1.0))
	h.act("tool_end", h.at(p.x, p.y, 1.02))


func _new_path_id() -> String:
	for id in h.doc.sorted_path_ids():
		if id != _fixture_id:
			return id
	return ""


func _roughness(x0: float, x1: float, z: float) -> float:
	var total := 0.0
	var x := x0
	while x < x1:
		total += absf(h.doc.sample_height(x + 0.5, z) - h.doc.sample_height(x, z))
		x += 0.5
	return total


func test_draw_makes_a_spline_path_and_flattens_terrain_in_one_action() -> void:
	var before_paths := PathRecord.encode_all(h.doc.paths)
	var before_heights := h.height_snapshot()
	var rough_before := _roughness(20.0, 60.0, 90.0)
	assert_true(rough_before > 1.0, "fixture hills are not flat here")
	h.act("tool_begin", h.at(20, 90, 1.0))
	assert_eq(h.ctrl.stroke_state(), "Drawing path")
	h.act("tool_cancel", null)
	assert_eq(PathRecord.encode_all(h.doc.paths), before_paths, "cancel changes nothing")
	_draw(Vector2(20, 90), Vector2(60, 90), false, 2.0)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.history.size(), 1)
	assert_eq(h.commits[0].label, "Draw path")
	var id := _new_path_id()
	assert_true(id != "", "path created")
	var rec := h.doc.get_path_record(id)
	assert_eq(rec.width_m, PackedFloat32Array([2.4])[0])
	assert_eq(rec.points.size(), 11, "40 m = control points every 4 m")
	assert_near(rec.points[0].x, 20.0, 0.3)
	assert_near(rec.points[rec.points.size() - 1].x, 60.0, 0.3)
	assert_eq(h.ctrl.selected_path_id(), id, "new path is selected")
	assert_eq(h.commits[0].path_ids(), [id])
	assert_false(h.commits[0].height_regions().is_empty())
	assert_true(_roughness(20.0, 60.0, 90.0) < rough_before * 0.5, "terrain flattened along the stroke")
	assert_true(h.terrain.marked(TerrainView.MAP_HEIGHT).size() > 0, "terrain marked dirty")
	assert_true(path_events.size() > 0 and scatter_events.size() > 0 and scatter_events[0][1], "height hooks fire")
	var after_paths := PathRecord.encode_all(h.doc.paths)
	var after_heights := h.height_snapshot()
	h.history.undo(h.doc)
	assert_eq(PathRecord.encode_all(h.doc.paths), before_paths, "undo restores the path set")
	assert_eq(h.height_snapshot(), before_heights, "undo restores heights exactly")
	h.history.redo(h.doc)
	assert_eq(PathRecord.encode_all(h.doc.paths), after_paths)
	assert_eq(h.height_snapshot(), after_heights, "redo reapplies exactly")


func test_too_short_stroke_is_a_no_op() -> void:
	var before_paths := PathRecord.encode_all(h.doc.paths)
	var before_heights := h.height_snapshot()
	_draw(Vector2(20, 90), Vector2(20.8, 90))
	assert_eq(h.commits.size(), 0)
	assert_eq(h.history.size(), 0)
	assert_eq(PathRecord.encode_all(h.doc.paths), before_paths)
	assert_eq(h.height_snapshot(), before_heights)


func test_follow_terrain_objects_are_regrounded_and_undone_with_the_path() -> void:
	var rock := h.add_object(ToolHarness.BOULDER, 40.0, 90.0)
	rock.grounding = WorldConstants.GROUNDING_FOLLOW
	var lodge := h.add_object(ToolHarness.LODGE, 40.0, 100.0)
	lodge.grounding = WorldConstants.GROUNDING_FIXED
	var rock_before := rock.clone()
	var lodge_before := lodge.clone()
	_draw(Vector2(20, 90), Vector2(60, 90))
	assert_eq(h.commits.size(), 1)
	var moved := h.doc.get_object(rock.object_id)
	assert_near(moved.position[1], h.doc.sample_height(40.0, 90.0) + moved.height_offset_m, 1e-4, "rock follows the new ground")
	assert_true(h.commits[0].before_objects.has(rock.object_id))
	assert_true(h.doc.get_object(lodge.object_id).equals(lodge_before), "fixed object untouched")
	assert_false(h.commits[0].before_objects.has(lodge.object_id))
	h.history.undo(h.doc)
	assert_true(h.doc.get_object(rock.object_id).equals(rock_before), "undo restores the rock")


func test_lift_over_ui_still_commits_the_stroke() -> void:
	_draw(Vector2(20, 90), Vector2(60, 90), true)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.doc.paths.size(), 2)
	assert_eq(h.commits[0].label, "Draw path")


func test_tap_selects_the_nearest_path_or_clears_without_history() -> void:
	var id := h.doc.sorted_path_ids()[0]
	var rec := h.doc.get_path_record(id)
	var on_curve := PathSpline.eval(rec.points, 3.5)
	_tap(on_curve)
	assert_eq(h.ctrl.selected_path_id(), id)
	_tap(on_curve + Vector2(0.0, rec.width_m * 0.5 + 0.3))
	assert_eq(h.ctrl.selected_path_id(), id, "within width/2 + 0.5 m")
	_tap(Vector2(-90, -90))
	assert_eq(h.ctrl.selected_path_id(), "", "tap on empty terrain clears")
	_tap(on_curve + Vector2(0.0, rec.width_m * 0.5 + 3.0))
	assert_eq(h.ctrl.selected_path_id(), "", "too far from the curve")
	assert_eq(h.commits.size(), 0)
	assert_eq(h.history.size(), 0)


func test_handle_drag_edits_only_the_curve_in_one_action() -> void:
	var id := h.doc.sorted_path_ids()[0]
	h.ctrl.select_path(id)
	var before := h.doc.get_path_record(id).clone()
	var before_bytes := PathRecord.encode_all(h.doc.paths)
	var heights := h.height_snapshot()
	var grab := before.points[3]
	var target := grab + Vector2(3.0, 2.0)
	h.act("tool_begin", h.at(grab.x + 0.5, grab.y, 1.0))
	assert_eq(h.ctrl.stroke_state(), "Editing path")
	h.act("tool_move", h.at(grab.x + 2.0, grab.y + 1.0, 1.02))
	path_events.clear()
	h.act("tool_move", h.at(target.x, target.y, 1.04))
	assert_eq(path_events, [[id]], "live re-render hook")
	h.act("tool_end", h.at(target.x, target.y, 1.06))
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Edit path")
	var after := h.doc.get_path_record(id)
	assert_true(after.points[3].distance_to(target) < 0.3, "point follows the hit")
	for i in after.points.size():
		if i != 3:
			assert_eq(after.points[i], before.points[i], "point %d untouched" % i)
	assert_eq(h.height_snapshot(), heights, "heights unchanged")
	assert_true(h.commits[0].before_objects.is_empty() and h.commits[0].height_regions().is_empty())
	h.history.undo(h.doc)
	assert_eq(PathRecord.encode_all(h.doc.paths), before_bytes)


func test_handle_contact_without_movement_leaves_no_history() -> void:
	var id := h.doc.sorted_path_ids()[0]
	h.ctrl.select_path(id)
	var grab := h.doc.get_path_record(id).points[2]
	h.act("tool_begin", h.at(grab.x, grab.y, 1.0))
	h.act("tool_end", h.at(grab.x, grab.y, 1.02))
	assert_eq(h.commits.size(), 0)


func test_handle_drag_cancel_restores_the_path_and_far_start_draws() -> void:
	var id := h.doc.sorted_path_ids()[0]
	h.ctrl.select_path(id)
	var before_bytes := PathRecord.encode_all(h.doc.paths)
	var grab := h.doc.get_path_record(id).points[1]
	h.act("tool_begin", h.at(grab.x, grab.y, 1.0))
	h.act("tool_move", h.at(grab.x + 3.0, grab.y + 3.0, 1.02))
	assert_ne(PathRecord.encode_all(h.doc.paths), before_bytes)
	h.act("tool_cancel", null)
	assert_eq(PathRecord.encode_all(h.doc.paths), before_bytes)
	_draw(Vector2(20, 90), Vector2(60, 90), false, 3.0)
	assert_eq(h.doc.paths.size(), 2, "a contact far from every handle draws a new path")


func test_delete_selected_path_is_one_undoable_action() -> void:
	var id := h.doc.sorted_path_ids()[0]
	var bytes := PathRecord.encode_all(h.doc.paths)
	h.ctrl.select_path(id)
	assert_empty_string(h.ctrl.delete_selected_path())
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Delete path")
	assert_eq(h.doc.paths.size(), 0)
	assert_eq(h.ctrl.selected_path_id(), "")
	h.history.undo(h.doc)
	assert_eq(PathRecord.encode_all(h.doc.paths), bytes)


func test_no_dirt_paint_preset_any_more() -> void:
	var before := h.control_snapshot()
	_draw(Vector2(20, 90), Vector2(60, 90))
	assert_eq(h.control_snapshot(), before, "the Path tool never paints the control maps")
