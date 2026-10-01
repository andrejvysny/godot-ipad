extends TestCase
## Editor v2 sculpt and paint tools end to end through ToolController (docs/editor-v2.md §2-§5).

const LOC := Vector2i(0, 0)

var h: ToolHarness


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness setup")
	h.ctrl.set_store().path = ""


func after_each() -> void:
	h.teardown()


func _drag(z: float, x0: float, x1: float, t0: float = 1.0) -> void:
	var t := t0
	h.act("tool_begin", h.at(x0, z, t))
	var x := x0
	while x < x1:
		x = minf(x + 2.0, x1)
		t += 0.02
		h.act("tool_move", h.at(x, z, t))
	h.act("tool_end", h.at(x1, z, t + 0.02))


func _hold(x: float, z: float, t0: float, t1: float) -> void:
	h.act("tool_begin", h.at(x, z, t0))
	var t := t0
	while t < t1:
		t = minf(t + 1.0 / 60.0, t1)
		h.ctrl.advance(t)
	h.act("tool_end", h.at(x, z, t1))


func _bytes() -> Dictionary:
	var out := {}
	for loc: Vector2i in h.doc.regions:
		var r := h.doc.get_region(loc)
		out[loc] = [r.heights.duplicate(), r.control.duplicate(), r.color.duplicate()]
	return out


## Runs `stroke`, then checks label, undo and redo restore exact bytes. Returns the commit.
func _check_tool(label: String, stroke: Callable) -> WorldChange:
	var before := _bytes()
	var commits := h.commits.size()
	stroke.call()
	assert_eq(h.commits.size(), commits + 1, label + ": one commit")
	if h.commits.size() != commits + 1:
		return null
	var change := h.commits[commits]
	assert_eq(change.label, label)
	assert_eq(h.history.peek_undo_label(), label)
	var after := _bytes()
	assert_true(after != before, label + ": changed something")
	h.history.undo(h.doc)
	assert_true(_bytes() == before, label + ": undo restores exact bytes")
	h.history.redo(h.doc)
	assert_true(_bytes() == after, label + ": redo restores exact bytes")
	return change


func test_every_tool_is_one_labelled_undoable_action() -> void:
	var paint_drag := func() -> void: _drag(40.0, 30.0, 50.0, 1.0 + h.commits.size())
	var sculpt_hold := func() -> void: _hold(40.0, 40.0, 1.0 + h.commits.size(), 1.5 + h.commits.size())
	h.ctrl.set_tool("raise")
	_check_tool("Raise terrain", sculpt_hold)
	h.ctrl.set_inverted(true)
	_check_tool("Lower terrain", sculpt_hold)
	h.ctrl.set_tool("flatten")
	h.ctrl.set_setting("flatten", "target", 25.0)
	var flat := _check_tool("Flatten terrain", sculpt_hold)
	assert_true(flat != null and flat.before_heights.has(LOC))
	h.ctrl.set_tool("noise")
	_check_tool("Roughen terrain", sculpt_hold)
	h.ctrl.set_inverted(true)
	_check_tool("Smooth terrain", sculpt_hold)
	h.ctrl.set_tool("paint")
	h.ctrl.set_setting("paint", "layer", 2)
	_check_tool("Paint Rock", paint_drag)
	h.ctrl.set_inverted(true)
	_check_tool("Erase paint", paint_drag)
	h.ctrl.set_tool("spray")
	h.ctrl.set_setting("paint", "layer", 3)
	_check_tool("Spray Sand", paint_drag)
	h.ctrl.set_inverted(true)
	_check_tool("Erase spray", paint_drag)
	h.ctrl.set_tool("tint")
	h.ctrl.set_setting("paint", "tint", 2)
	var tint := _check_tool("Tint Autumn", paint_drag)
	assert_true(tint != null and tint.before_controls.is_empty() and tint.before_heights.is_empty(), "tint writes colours only")
	h.ctrl.set_inverted(true)
	_check_tool("Remove tint", paint_drag)


func test_brush_alpha_shape_applies_to_every_family() -> void:
	assert_empty_string(h.ctrl.set_setting("brush", "shape", "cloud"))
	assert_empty_string(h.ctrl.set_setting("brush", "alpha_mode", "stamp"))
	h.ctrl.set_tool("paint")
	_drag(40.0, 30.0, 50.0)
	h.ctrl.set_tool("raise")
	_hold(40.0, 40.0, 3.0, 3.5)
	assert_eq(h.commits.size(), 2)
	assert_empty_string(h.ctrl.set_setting("brush", "alpha_mode", "pattern"))
	h.ctrl.set_tool("tint")
	_drag(40.0, 30.0, 50.0, 6.0)
	assert_eq(h.commits.size(), 3)
	assert_eq(h.diagnostics, [] as Array[String])


func test_tint_marks_colour_maps_only_and_cancel_rolls_back() -> void:
	h.ctrl.set_tool("tint")
	var hash_before := CanonicalEncoder.authored_hash(h.doc)
	h.act("tool_begin", h.at(0.0, 0.0, 1.0))
	h.act("tool_move", h.at(6.0, 0.0, 1.02))
	assert_eq(h.terrain.marked(TerrainView.MAP_COLOR).size(), 4, "seam stroke touches all four colour maps")
	assert_true(h.terrain.marked(TerrainView.MAP_CONTROL).is_empty())
	assert_true(h.terrain.marked(TerrainView.MAP_HEIGHT).is_empty())
	assert_ne(CanonicalEncoder.authored_hash(h.doc), hash_before)
	h.terrain.marks.clear()
	h.ctrl.handle_tool_action({"type": "tool_cancel", "reason": "native_cancel"})
	assert_eq(CanonicalEncoder.authored_hash(h.doc), hash_before, "exact rollback")
	assert_eq(h.terrain.marked(TerrainView.MAP_COLOR).size(), 4, "rolled-back colour maps are re-uploaded")
	assert_eq(h.commits.size(), 0)


func test_stroke_state_for_every_tool() -> void:
	for pair in [["flatten", "Sculpting"], ["noise", "Sculpting"], ["spray", "Painting"], ["tint", "Painting"]]:
		h.ctrl.set_tool(pair[0])
		h.act("tool_begin", h.at(40.0, 40.0, 1.0))
		assert_eq(h.ctrl.stroke_state(), pair[1], pair[0])
		h.act("tool_end", h.at(40.0, 40.0, 1.02))
	h.ctrl.set_tool("pick")
	h.act("tool_begin", h.at(40.0, 40.0, 5.0))
	assert_eq(h.ctrl.stroke_state(), "Idle", "pick has no stroke state")
	h.act("tool_end", h.at(40.0, 40.0, 5.02))


func test_flatten_without_a_target_uses_the_height_at_the_stroke_start() -> void:
	h.ctrl.set_tool("flatten")
	assert_true(is_nan(h.ctrl.settings("flatten").target))
	var start := h.doc.sample_height(40.0, 40.0)
	var near_before := h.doc.sample_height(46.0, 40.0)
	assert_true(absf(near_before - start) > 0.2, "fixture is sloped here")
	h.act("tool_begin", h.at(40.0, 40.0, 1.0))
	var t := 1.0
	while t < 2.0:
		t += 1.0 / 60.0
		h.act("tool_move", h.at(40.0 + (t - 1.0) * 6.0, 40.0, t))  # drags over higher or lower ground
		h.ctrl.advance(t)
	h.act("tool_end", h.at(46.0, 40.0, 2.02))
	assert_eq(h.commits.size(), 1)
	var change := h.commits[0]
	# The target stayed the first hit's height although the Pencil moved on.
	for loc: Vector2i in change.after_heights:
		var after: PackedFloat32Array = change.after_heights[loc]
		var before: PackedFloat32Array = change.before_heights[loc]
		for i in after.size():
			if before[i] != after[i]:
				var gap_before := absf(before[i] - start)
				var gap_after := absf(after[i] - start)
				assert_true(gap_after <= gap_before + 1e-4, "moved towards the start height only")
	assert_true(is_nan(h.ctrl.settings("flatten").target), "the setting stays NAN")


func test_flatten_with_an_explicit_target_and_followers_in_one_action() -> void:
	var boulder := h.add_object(ToolHarness.BOULDER, 42.0, 40.0, 0.2)
	var far := h.add_object(ToolHarness.SPRUCE, 90.0, 90.0)
	var far_before := far.clone()
	var y0 := boulder.position[1]
	h.ctrl.set_tool("flatten")
	h.ctrl.set_setting("flatten", "target", 30.0)
	_hold(42.0, 40.0, 1.0, 2.0)
	assert_eq(h.commits.size(), 1)
	var moved := h.doc.get_object(boulder.object_id)
	assert_true(moved.position[1] > y0 + 1.0, "boulder rose with the ground")
	assert_near(moved.position[1], h.doc.sample_height(42, 40) + 0.2, 1e-9, "grounded on the new surface")
	assert_true(h.commits[0].before_objects.has(boulder.object_id), "the same action contains the object")
	assert_true(h.doc.get_object(far.object_id).equals(far_before))
	h.history.undo(h.doc)
	assert_near(h.doc.get_object(boulder.object_id).position[1], y0, 1e-9, "undo restores the object")


func test_noise_and_smooth_reground_followers() -> void:
	for inverted in [false, true]:
		var boulder := h.add_object(ToolHarness.BOULDER, 42.0, 40.0, 0.2)
		h.ctrl.set_tool("noise")
		h.ctrl.set_inverted(inverted)
		var commits := h.commits.size()
		_hold(42.0, 40.0, 1.0 + commits, 2.0 + commits)
		assert_eq(h.commits.size(), commits + 1)
		var rec := h.doc.get_object(boulder.object_id)
		assert_near(rec.position[1], h.doc.sample_height(42, 40) + 0.2, 1e-9, "grounded (inverted %s)" % inverted)
		h.doc.remove_object(boulder.object_id)
		h.presenter.sync_object(h.doc, boulder.object_id)


# --- Pick --------------------------------------------------------------------------------

func _tap(x: float, z: float, t: float = 1.0) -> void:
	h.act("tool_begin", h.at(x, z, t))
	h.act("tool_end", h.at(x, z, t + 0.02))


func test_pick_takes_the_visible_layer_without_history() -> void:
	h.ctrl.set_tool("paint")
	h.ctrl.set_setting("paint", "layer", 2)
	_tap(40, 40)
	h.ctrl.set_setting("paint", "layer", 1)
	var commits := h.commits.size()
	h.ctrl.set_tool("pick")
	assert_true(h.ctrl.mode() == "paint" and h.ctrl.active_tool() == "pick")
	h.diagnostics.clear()
	_tap(40, 40, 3.0)
	assert_eq(h.ctrl.settings("paint").layer, 2, "picked rock")
	assert_eq([h.ctrl.mode(), h.ctrl.active_tool()], ["paint", "paint"], "switched to the paint tool")
	assert_eq(h.diagnostics, ["Picked Rock"] as Array[String])
	assert_eq(h.commits.size(), commits, "no history")


func test_pick_overlay_base_and_rule_layers() -> void:
	var region := h.doc.get_region(LOC)
	var at := func(x: float, z: float) -> int: return (roundi(z / 0.5) % 256) * 256 + roundi(x / 0.5) % 256
	region.control[at.call(60.0, 60.0)] = ControlCodec.encode(0, {"auto": true, "base_id": 1, "overlay_id": 3, "blend": 200})
	region.control[at.call(70.0, 60.0)] = ControlCodec.encode(0, {"auto": false, "base_id": 2, "overlay_id": 3, "blend": 100})
	region.control[at.call(80.0, 60.0)] = ControlCodec.encode(0, {"auto": true, "base_id": 2, "overlay_id": 3, "blend": 100})
	h.ctrl.set_tool("pick")
	_tap(60, 60)
	assert_eq(h.ctrl.settings("paint").layer, 3, "overlay once blend >= 0.5")
	h.ctrl.set_tool("pick")
	_tap(70, 60, 2.0)
	assert_eq(h.ctrl.settings("paint").layer, 2, "manual base below 0.5")
	h.ctrl.set_tool("pick")
	_tap(80, 60, 3.0)
	assert_eq(h.ctrl.settings("paint").layer, TerrainRules.material_at(h.doc, 80.0, 60.0), "rule layer under auto")
	assert_eq(h.commits.size(), 0)


func test_pick_miss_reports_and_stays_on_pick() -> void:
	h.ctrl.set_tool("pick")
	h.diagnostics.clear()
	h.act("tool_begin", h.sky(1.0))
	h.act("tool_end", h.sky(1.02))
	assert_eq(h.diagnostics, ["No terrain under the Pencil."] as Array[String])
	assert_eq(h.ctrl.active_tool(), "pick")
	assert_eq(h.ctrl.settings("paint").layer, 1, "layer unchanged")
