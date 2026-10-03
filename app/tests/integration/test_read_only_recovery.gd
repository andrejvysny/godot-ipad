extends TestCase
## Read-only recovery (ADR 0014 D8): while a world has unavailable asset bindings every authoring operation is
## refused with a visible reason, posted once; navigation state and the document stay untouched.

const REASON := "Read-only recovery: 1 asset binding(s) unavailable. Editing is disabled."

var h: ToolHarness


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness setup")


func after_each() -> void:
	h.teardown()


func test_pointer_operations_are_refused_and_the_reason_is_posted_once() -> void:
	h.ctrl.set_read_only(REASON)
	assert_eq(h.ctrl.read_only_reason(), REASON)
	var before := CanonicalEncoder.authored_hash(h.doc)
	for tool_id in [ToolController.TOOL_PAINT, ToolController.TOOL_RAISE, "scatter", ToolController.TOOL_SELECT]:
		assert_empty_string(h.ctrl.set_tool(tool_id), "choosing a tool is not authoring")
		h.act("tool_begin", h.at(40, 40, 1.0))
		h.act("tool_move", h.at(44, 40, 1.02))
		h.act("tool_end", h.at(44, 40, 1.04))
		assert_false(h.ctrl.has_active_operation(), "%s starts nothing" % tool_id)
	assert_eq(CanonicalEncoder.authored_hash(h.doc), before, "the document is untouched")
	assert_eq(h.commits.size(), 0, "nothing reaches history")
	assert_eq(h.diagnostics, [REASON], "the reason is posted once, not per attempt")
	h.ctrl.set_read_only("")
	h.ctrl.set_read_only("Read-only recovery: another reason.")
	h.act("tool_begin", h.at(40, 40, 2.0))
	assert_eq(h.diagnostics.size(), 2, "a different reason is posted again")


func test_drop_arm_height_pick_and_object_commands_are_refused() -> void:
	var rec := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	h.ctrl.select(rec.object_id)
	h.ctrl.set_read_only(REASON)
	var before := CanonicalEncoder.authored_hash(h.doc)
	assert_eq(h.ctrl.begin_drop(ToolHarness.BOULDER), REASON)
	assert_false(h.ctrl.has_drop())
	assert_eq(h.ctrl.arm_asset(ToolHarness.BOULDER), REASON)
	assert_eq(h.ctrl.armed_asset(), "")
	assert_empty_string(h.ctrl.set_tool(ToolController.TOOL_FLATTEN))
	assert_eq(h.ctrl.begin_height_pick(), REASON)
	assert_eq(h.ctrl.begin_object_edit("yaw"), REASON, "sliders")
	assert_eq(h.ctrl.nudge("scale", 0.1), REASON)
	assert_eq(h.ctrl.set_grounding(WorldConstants.GROUNDING_FIXED), REASON)
	assert_eq(h.ctrl.duplicate_selected(), REASON)
	assert_eq(h.ctrl.delete_selected(), REASON)
	assert_eq(h.ctrl.rule_edits().toggle("rock"), REASON, "rule toggles")
	assert_eq(h.ctrl.rule_edits().begin_scrub(), REASON)
	assert_false(h.ctrl.has_object_edit())
	assert_eq(CanonicalEncoder.authored_hash(h.doc), before)
	assert_true(h.doc.get_object(rec.object_id) != null)
	assert_eq(h.commits.size(), 0)


func test_editing_resumes_when_the_reason_clears() -> void:
	h.ctrl.set_read_only(REASON)
	assert_ne(h.ctrl.arm_asset(ToolHarness.BOULDER), "")
	h.ctrl.set_read_only("")
	assert_empty_string(h.ctrl.arm_asset(ToolHarness.BOULDER), "arming works again")
	h.ctrl.disarm()
	assert_empty_string(h.ctrl.set_tool(ToolController.TOOL_PAINT))
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_true(h.ctrl.has_active_operation(), "a stroke starts again")
	h.act("tool_end", h.at(40, 40, 1.1))
