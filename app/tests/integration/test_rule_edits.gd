extends TestCase
## RuleEdits (auto-paint toggle and scrub history) and ToolController.place_preview().

class RulesTerrain extends ToolHarness.FakeTerrain:
	var slopes: Array[int] = []

	func set_rules(rules: TerrainRules) -> void:
		slopes.append(rules.rock_slope_deg)


var h: ToolHarness
var terrain := RulesTerrain.new()


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree))
	h.ctx.terrain = terrain


func after_each() -> void:
	h.teardown()
	terrain.free()
	terrain = RulesTerrain.new()


func test_toggle_is_one_action_and_reaches_the_terrain() -> void:
	var edits := h.ctrl.rule_edits()
	assert_true(h.doc.rules.rock_enabled)
	assert_empty_string(edits.toggle("rock"))
	assert_false(h.doc.rules.rock_enabled)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Toggle rule")
	assert_eq(terrain.slopes.size(), 1, "set_rules called")
	assert_empty_string(edits.toggle("sand"))
	assert_false(h.doc.rules.sand_enabled)
	assert_eq(h.commits.size(), 2)
	assert_ne(edits.toggle("lava"), "")
	assert_eq(h.commits.size(), 2)


func test_scrub_is_one_action_clamps_and_undoes() -> void:
	var edits := h.ctrl.rule_edits()
	var start := h.doc.rules.rock_slope_deg
	assert_empty_string(edits.begin_scrub())
	assert_true(edits.is_open())
	assert_ne(edits.begin_scrub(), "", "no nested scrub")
	edits.update("rock_slope_deg", 40)
	edits.update("rock_slope_deg", 99)
	assert_eq(h.doc.rules.rock_slope_deg, WorldConstants.RULE_ROCK_SLOPE_MAX, "clamped to the format range")
	edits.update("sand_height_dm", -99)
	assert_eq(h.doc.rules.sand_height_dm, WorldConstants.RULE_SAND_HEIGHT_DM_MIN)
	assert_eq(terrain.slopes[0], 40, "live updates reach the terrain")
	assert_eq(h.commits.size(), 0, "nothing committed mid-scrub")
	edits.end_scrub()
	assert_false(edits.is_open())
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Edit auto-paint rule")
	h.history.undo(h.doc)
	assert_eq(h.doc.rules.rock_slope_deg, start)


func test_unchanged_scrub_has_no_history_and_cancel_restores() -> void:
	var edits := h.ctrl.rule_edits()
	var start := h.doc.rules.rock_slope_deg
	edits.begin_scrub()
	edits.update("rock_slope_deg", start)
	edits.end_scrub()
	assert_eq(h.commits.size(), 0)
	edits.begin_scrub()
	edits.update("rock_slope_deg", 55)
	edits.cancel_scrub()
	assert_eq(h.doc.rules.rock_slope_deg, start, "cancel restores")
	assert_eq(terrain.slopes[terrain.slopes.size() - 1], start, "terrain restored too")
	assert_eq(h.commits.size(), 0)
	assert_ne(edits.update("rock_slope_deg", 20), "", "no open scrub")


func test_rule_edits_refused_while_an_operation_is_open() -> void:
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.BOULDER))
	assert_eq(h.ctrl.rule_edits().toggle("rock"), ToolModel.BUSY)
	assert_eq(h.ctrl.rule_edits().begin_scrub(), ToolModel.BUSY)
	h.ctrl.cancel_active("test")
	assert_empty_string(h.ctrl.rule_edits().toggle("rock"))


func test_cancel_active_rolls_back_an_open_scrub() -> void:
	var start := h.doc.rules.rock_slope_deg
	h.ctrl.rule_edits().begin_scrub()
	h.ctrl.rule_edits().update("rock_slope_deg", 50)
	h.ctrl.cancel_active("app_deactivated")
	assert_eq(h.doc.rules.rock_slope_deg, start)
	assert_false(h.ctrl.rule_edits().is_open())


func test_place_preview_reports_state_slope_and_conflict() -> void:
	assert_false(h.ctrl.place_preview().active)
	var near := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.BOULDER))
	assert_false(h.ctrl.place_preview().active, "inactive until the ghost has been shown")
	h.ctrl.update_drop(h.camera.unproject_position(Vector3(40.0, h.doc.sample_height(40.0, 40.0), 40.0)), false)
	var p := h.ctrl.place_preview()
	assert_true(p.active and p.valid and not p.over_ui)
	assert_eq(p.asset_name, h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	assert_eq(p.conflict, h.catalog.get_asset(ToolHarness.BOULDER).display_name, "overlaps the manual object %s" % near.object_id)
	assert_true(float(p.slope_deg) >= 0.0 and float(p.slope_deg) < 90.0)
	assert_near(float(p.yaw_deg), 0.0, 0.01)
	h.ctrl.update_drop(Vector2(10, 10), true)
	assert_true(h.ctrl.place_preview().over_ui)
	assert_false(h.ctrl.place_preview().valid)
	h.ctrl.update_drop(h.camera.unproject_position(Vector3(60.0, h.doc.sample_height(60.0, 60.0), 60.0)), false)
	assert_eq(h.ctrl.place_preview().conflict, "", "far from every object")
	h.ctrl.cancel_active("test")
	assert_false(h.ctrl.place_preview().active)
