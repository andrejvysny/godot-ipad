extends TestCase
## Scatter, Erase and Fill through ToolController (docs/editor-v2.md §6): one transaction per
## contact, exact undo/redo bytes, manual objects untouched, limit handling, ToolContext hook.

const PEBBLES := "nature.rock.pebbles_a"

var h: ToolHarness
var rects: Array = []  # [Rect2, heights_only]


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness setup")
	h.doc.scatter = ScatterLayer.new()
	rects = []
	h.ctx.scatter_changed = func(rect: Rect2, heights_only: bool) -> void: rects.append([rect, heights_only])
	assert_empty_string(h.ctrl.set_setting("place", "radius", 20.0))
	assert_empty_string(h.ctrl.set_setting("place", "strength", 1.0))


func after_each() -> void:
	h.teardown()


## Drags along z from x0 to x1, 2 m per move, 20 ms apart; returns the end time.
func _drag(z: float, x0: float, x1: float, t0: float = 1.0) -> float:
	return _trace([Vector2(x0, z), Vector2(x1, z)], t0)


## Pencil path through `points`, 2 m steps; ends at the last point.
func _trace(points: Array[Vector2], t0: float = 1.0) -> float:
	var t := t0
	h.act("tool_begin", h.at(points[0].x, points[0].y, t))
	for k in range(1, points.size()):
		var from := points[k - 1]
		var steps := maxi(1, ceili(from.distance_to(points[k]) / 2.0))
		for s in range(1, steps + 1):
			t += 0.02
			var p := from.lerp(points[k], float(s) / float(steps))
			if k == points.size() - 1 and s == steps:
				h.act("tool_end", h.at(p.x, p.y, t))
			else:
				h.act("tool_move", h.at(p.x, p.y, t))
	return t


func _square() -> Array[Vector2]:
	return [Vector2(30, 30), Vector2(50, 30), Vector2(50, 50), Vector2(30, 50), Vector2(30, 31)]


func _inside_square(layer: ScatterLayer, i: int) -> bool:
	return layer.x[i] >= 30.0 and layer.x[i] <= 50.0 and layer.z[i] >= 30.0 and layer.z[i] <= 50.0


func _limit_messages() -> int:
	return h.diagnostics.count("Scatter limit reached (20000).")


func _prefill(n: int) -> void:
	var version := h.catalog.get_asset(PEBBLES).version
	for i in n:
		h.doc.scatter.add(PEBBLES, version, -120.0 + float(i % 200), -120.0 + float(i / 200), 0.0, 1.0, 0)


func test_scatter_stroke_is_one_undoable_change() -> void:
	var empty := h.doc.scatter.encode()
	h.ctrl.set_tool("scatter")
	h.act("tool_begin", h.at(30, 40, 1.0))
	assert_eq(h.ctrl.stroke_state(), "Scattering")
	h.act("tool_move", h.at(32, 40, 1.02))
	h.act("tool_cancel", null)
	assert_eq(h.doc.scatter.encode(), empty)
	_drag(40.0, 30.0, 50.0, 2.0)
	var added := h.doc.scatter.count()
	assert_true(added > 5, "scattered %d" % added)
	assert_eq(h.commits.size(), 1)
	var change := h.commits[0]
	assert_eq(change.label, "Scatter Spruce forest (%d)" % added)
	assert_eq(h.history.size(), 1)
	assert_true(change.has_scatter())
	assert_true(change.before_objects.is_empty(), "objects untouched")
	var after := h.doc.scatter.encode()
	assert_true(rects.size() > 0 and not bool(rects[0][1]), "scatter edits notify with heights_only false")
	h.history.undo(h.doc)
	assert_eq(h.doc.scatter.encode(), empty, "undo restores exact bytes")
	h.history.redo(h.doc)
	assert_eq(h.doc.scatter.encode(), after, "redo restores exact bytes")
	for i in h.doc.scatter.count():
		assert_true(["nature.tree.spruce_a", "nature.cover.fern_a", "nature.rock.boulder_a"].has(h.doc.scatter.asset_of(i)))


func test_empty_source_reports_and_creates_no_operation() -> void:
	h.ctrl.set_tool("scatter")
	assert_empty_string(h.ctrl.set_setting("scatter", "source", "mix"))
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_false(h.ctrl.has_active_operation())
	assert_eq(h.diagnostics, [ToolCommands.EMPTY_SOURCE_MESSAGE])
	h.act("tool_end", h.at(40, 40, 1.1))
	assert_eq(h.commits.size(), 0)
	h.ctrl.set_tool("fill")
	h.diagnostics.clear()
	h.act("tool_begin", h.at(40, 40, 2.0))
	assert_eq(h.diagnostics, [ToolCommands.EMPTY_SOURCE_MESSAGE], "fill needs a source too")
	h.ctrl.set_tool("erase")
	h.diagnostics.clear()
	h.act("tool_begin", h.at(40, 40, 3.0))
	assert_true(h.ctrl.has_active_operation(), "erase needs no source")
	h.act("tool_end", h.at(40, 40, 3.1))


func test_erase_brush_removes_scatter_only_and_undoes_exactly() -> void:
	var rock := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	var rock_before := rock.clone()
	h.doc.scatter.add("nature.rock.pebbles_a", h.catalog.get_asset(PEBBLES).version, -100.0, -100.0, 0.0, 1.0, 0)
	h.ctrl.set_tool("scatter")
	_drag(40.0, 20.0, 60.0)
	var populated := h.doc.scatter.count()
	var bytes := h.doc.scatter.encode()
	assert_true(populated > 10, "something to erase: %d" % populated)
	h.ctrl.set_tool("erase")
	_drag(40.0, 20.0, 60.0, 5.0)
	var left := h.doc.scatter.count()
	assert_true(left < populated, "erased some: %d of %d left" % [left, populated])
	assert_eq(h.commits.size(), 2)
	assert_eq(h.commits[1].label, "Erase scatter (%d)" % (populated - left))
	assert_true(h.doc.get_object(rock.object_id).equals(rock_before), "manual object untouched")
	assert_eq(h.doc.objects.size(), 1)
	var far := false
	for i in h.doc.scatter.count():
		far = far or (h.doc.scatter.x[i] == -100.0 and h.doc.scatter.z[i] == -100.0)
	assert_true(far, "instance outside the brush survives")
	h.history.undo(h.doc)
	assert_eq(h.doc.scatter.encode(), bytes, "undo restores exact bytes")


func test_inverted_scatter_erases_and_reports_erasing() -> void:
	h.ctrl.set_tool("scatter")
	_drag(40.0, 20.0, 60.0)
	var populated := h.doc.scatter.count()
	assert_empty_string(h.ctrl.set_inverted(true))
	h.act("tool_begin", h.at(20, 40, 5.0))
	assert_eq(h.ctrl.stroke_state(), "Erasing")
	h.act("tool_end", h.at(20, 40, 5.02))
	_drag(40.0, 20.0, 60.0, 6.0)
	var last := h.commits[h.commits.size() - 1]
	assert_true(last.label.begins_with("Erase scatter ("), last.label)
	assert_true(h.doc.scatter.count() < populated)
	assert_true(h.ctrl.inverted())


func test_stroke_that_changes_nothing_pushes_no_history() -> void:
	h.ctrl.set_tool("erase")
	_drag(40.0, 20.0, 60.0)
	assert_eq(h.commits.size(), 0)
	assert_eq(h.history.size(), 0)
	assert_eq(h.ctrl.stroke_state(), "Idle")


func _hold(x0: float, x1: float, t0: float) -> void:
	h.act("tool_begin", h.at(x0, 40, t0))
	var x := x0
	while x < x1:
		x += 2.0
		t0 += 0.02
		h.act("tool_move", h.at(x, 40, t0))


func test_over_ui_end_keeps_work_so_far_and_cancel_rolls_back() -> void:
	var empty := h.doc.scatter.encode()
	h.ctrl.set_tool("scatter")
	_hold(30.0, 44.0, 1.0)
	var count_now := h.doc.scatter.count()
	assert_true(count_now > 0)
	h.act("tool_end", h.at(70, 40, 1.4), true)
	assert_eq(h.doc.scatter.count(), count_now, "the over-UI end sample is not applied")
	assert_eq(h.commits.size(), 1)
	h.history.undo(h.doc)
	assert_eq(h.doc.scatter.encode(), empty)
	_hold(30.0, 44.0, 2.0)
	assert_true(h.doc.scatter.count() > 0)
	rects.clear()
	h.act("tool_cancel", null)
	assert_eq(h.doc.scatter.encode(), empty, "cancel rolls the layer back")
	assert_false(h.ctrl.has_active_operation())
	assert_eq(h.commits.size(), 1)
	assert_true(rects.size() > 0, "rollback tells the renderer")


func test_invalid_hit_pauses_without_bridging() -> void:
	h.ctrl.set_tool("scatter")
	_hold(30.0, 34.0, 1.0)
	h.act("tool_move", h.sky(1.1))
	var count_now := h.doc.scatter.count()
	h.act("tool_resume", h.at(100, 40, 2.0))
	h.act("tool_move", h.at(104, 40, 2.02))
	h.act("tool_end", h.at(104, 40, 2.04))
	var between := 0
	for i in h.doc.scatter.count():
		if h.doc.scatter.x[i] > 52.0 and h.doc.scatter.x[i] < 78.0:
			between += 1
	assert_eq(between, 0, "the gap is not scattered")
	assert_true(h.doc.scatter.count() > count_now, "resume scatters again")


func test_fill_fills_inside_the_loop_only() -> void:
	var version := h.catalog.get_asset(PEBBLES).version
	h.doc.scatter.add(PEBBLES, version, 0.0, 0.0, 0.0, 1.0, 0)
	h.ctrl.set_tool("fill")
	h.act("tool_begin", h.at(30, 30, 1.0))
	assert_eq(h.ctrl.stroke_state(), "Filling")
	h.act("tool_cancel", null)
	var before := h.doc.scatter.count()
	_trace(_square())
	var layer := h.doc.scatter
	var added := layer.count() - before
	assert_true(added > 10, "filled %d" % added)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Fill Spruce forest (%d)" % added)
	for i in range(before, layer.count()):
		assert_true(_inside_square(layer, i), "instance %d inside the loop" % i)
	assert_eq(layer.x[0], 0.0, "existing instance kept")
	assert_true(rects.size() > 0 and not bool(rects[rects.size() - 1][1]))
	var after := layer.encode()
	h.history.undo(h.doc)
	assert_eq(h.doc.scatter.count(), before)
	h.history.redo(h.doc)
	assert_eq(h.doc.scatter.encode(), after)


func test_clear_removes_instances_inside_the_loop_only() -> void:
	var version := h.catalog.get_asset(PEBBLES).version
	for p in [Vector2(40, 40), Vector2(35, 45), Vector2(55, 40), Vector2(10, 10)]:
		h.doc.scatter.add(PEBBLES, version, p.x, p.y, 0.0, 1.0, 0)
	var bytes := h.doc.scatter.encode()
	h.ctrl.set_tool("fill")
	assert_empty_string(h.ctrl.set_inverted(true))
	_trace(_square())
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Clear area (2)")
	assert_eq(h.doc.scatter.count(), 2)
	assert_eq(h.doc.scatter.x[0], 55.0)
	assert_eq(h.doc.scatter.x[1], 10.0)
	h.history.undo(h.doc)
	assert_eq(h.doc.scatter.encode(), bytes)


func test_fill_needs_three_points() -> void:
	h.ctrl.set_tool("fill")
	h.act("tool_begin", h.at(40, 40, 1.0))
	h.act("tool_move", h.at(40.1, 40.0, 1.02))
	h.act("tool_end", h.at(40.2, 40.0, 1.04))
	assert_eq(h.commits.size(), 0)
	assert_false(h.ctrl.has_active_operation())


func test_limit_reports_once_for_fill_and_brush() -> void:
	_prefill(WorldConstants.MAX_SCATTER_INSTANCES - 5)
	assert_empty_string(h.ctrl.set_setting("scatter", "source", "set:meadow"))
	h.ctrl.set_tool("fill")
	_trace(_square())
	assert_eq(h.doc.scatter.count(), WorldConstants.MAX_SCATTER_INSTANCES)
	assert_eq(_limit_messages(), 1)
	h.ctrl.set_tool("scatter")
	h.diagnostics.clear()
	var bytes := h.doc.scatter.encode()
	_drag(40.0, 20.0, 60.0, 5.0)
	assert_eq(_limit_messages(), 1, "reported once per stroke")
	assert_eq(h.doc.scatter.count(), WorldConstants.MAX_SCATTER_INSTANCES)
	assert_eq(h.doc.scatter.encode(), bytes)
	assert_eq(h.commits.size(), 1, "the full-layer stroke changed nothing")


func test_sculpt_marks_heights_only_rects() -> void:
	h.ctrl.set_tool("raise")
	h.act("tool_begin", h.at(40, 40, 1.0))
	h.act("tool_move", h.at(42, 40, 1.02))
	h.ctrl.advance(1.3)
	h.act("tool_end", h.at(42, 40, 1.32))
	assert_true(rects.size() > 0, "height edits notify the scatter hook")
	for r: Array in rects:
		assert_true(bool(r[1]), "heights_only")
