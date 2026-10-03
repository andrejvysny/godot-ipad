extends TestCase
## Editor v2 tool model on ToolController (docs/editor-v2.md §1, §2): modes, tools, invert,
## settings, armed placement, height pick, stubs, scatter source, duplicate, paths.

var h: ToolHarness
var tool_events: Array[String] = []
var setting_events: Array[String] = []


func before_each() -> void:
	h = ToolHarness.new()
	assert_empty_string(h.setup(tree), "harness setup")
	h.ctrl.set_store().path = ""  # never touch the user's scatter_sets.json
	tool_events.clear()
	setting_events.clear()
	h.ctrl.tool_changed.connect(func(id: String) -> void: tool_events.append(id))
	h.ctrl.settings_changed.connect(func(ns: String) -> void: setting_events.append(ns))


func after_each() -> void:
	h.teardown()


func _tap(x: float, z: float, t: float = 1.0, over_ui: bool = false) -> void:
	h.act("tool_begin", h.at(x, z, t))
	h.act("tool_end", h.at(x, z, t + 0.02), over_ui)


# --- Modes and tools ---------------------------------------------------------------------

func test_path_width_limits_come_from_config_clamped_to_the_format() -> void:
	assert_eq(ToolSettings.width_limits({"path_width_min_m": 1.0, "path_width_max_m": 6.0}), Vector2(1.0, 6.0))
	assert_eq(ToolSettings.width_limits({"path_width_min_m": 2.0, "path_width_max_m": 4.0}), Vector2(2.0, 4.0))
	assert_eq(ToolSettings.width_limits({"path_width_min_m": 0.1, "path_width_max_m": 9.0}), Vector2(1.0, 6.0), "format range wins")
	assert_eq(ToolSettings.width_limits({}), Vector2(1.0, 6.0), "fallback to WorldConstants")
	var h := ToolHarness.new()
	assert_empty_string(h.setup(tree))
	assert_eq(h.ctx.defaults.brush.path_width_default_m, 2.4, "shipped config default")


func test_startup_state_and_remembered_tools() -> void:
	assert_eq(h.ctrl.mode(), "paint")
	assert_eq(h.ctrl.active_tool(), "paint")
	assert_eq([h.ctrl.tool_of("sculpt"), h.ctrl.tool_of("paint"), h.ctrl.tool_of("place")], ["raise", "paint", "scatter"])
	assert_eq(ToolController.MODES, ["sculpt", "paint", "place"] as Array[String])
	assert_eq(ToolController.TOOLS_BY_MODE.place, ["select", "scatter", "erase", "fill", "path"])
	assert_eq(ToolController.INVERT_LABELS.raise, "Lower")
	assert_false(h.ctrl.inverted())
	assert_eq(h.ctrl.armed_asset(), "")


func test_set_tool_switches_mode_and_each_mode_remembers_its_tool() -> void:
	assert_empty_string(h.ctrl.set_tool("flatten"))
	assert_eq([h.ctrl.mode(), h.ctrl.active_tool()], ["sculpt", "flatten"])
	assert_empty_string(h.ctrl.set_mode("place"))
	assert_eq([h.ctrl.mode(), h.ctrl.active_tool()], ["place", "scatter"])
	assert_empty_string(h.ctrl.set_tool("path"))
	assert_empty_string(h.ctrl.set_mode("sculpt"))
	assert_eq(h.ctrl.active_tool(), "flatten", "sculpt remembers flatten")
	assert_empty_string(h.ctrl.set_mode("place"))
	assert_eq(h.ctrl.active_tool(), "path", "place remembers path")
	assert_eq(tool_events, ["flatten", "scatter", "path", "flatten", "path"] as Array[String])


func test_setting_the_same_tool_or_mode_emits_nothing() -> void:
	h.ctrl.set_tool("paint")
	h.ctrl.set_mode("paint")
	assert_eq(tool_events, [] as Array[String])


func test_unknown_ids_and_busy_are_refused() -> void:
	assert_error_contains(h.ctrl.set_tool("lasso"), "lasso")
	assert_error_contains(h.ctrl.set_tool("sculpt"), "sculpt", "a mode name is not a tool id")
	assert_error_contains(h.ctrl.set_mode("raise"), "raise")
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_true(h.ctrl.has_active_operation())
	assert_eq(h.ctrl.set_tool("raise"), ToolController.BUSY)
	assert_eq(h.ctrl.set_mode("place"), ToolController.BUSY)
	assert_eq(h.ctrl.active_tool(), "paint")
	h.act("tool_end", h.at(40, 40, 1.02))


# --- Invert ------------------------------------------------------------------------------

func test_invert_resets_on_mode_or_tool_change_and_ignores_tools_without_it() -> void:
	h.ctrl.set_tool("raise")
	assert_empty_string(h.ctrl.set_inverted(true))
	assert_true(h.ctrl.inverted())
	assert_eq(setting_events, ["invert"] as Array[String])
	h.ctrl.set_inverted(true)
	assert_eq(setting_events.size(), 1, "no event without a change")
	h.ctrl.set_tool("noise")
	assert_false(h.ctrl.inverted(), "tool change clears invert")
	h.ctrl.set_inverted(true)
	h.ctrl.set_mode("paint")
	assert_false(h.ctrl.inverted(), "mode change clears invert")
	for id in ["flatten", "pick", "select", "path"]:
		h.ctrl.set_tool(id)
		assert_empty_string(h.ctrl.set_inverted(true))
		assert_false(h.ctrl.inverted(), id + " has no invert")
	for id in ToolController.INVERT_LABELS:
		h.ctrl.set_tool(id)
		h.ctrl.set_inverted(true)
		assert_true(h.ctrl.inverted(), id)


func test_inverted_raise_lowers_terrain() -> void:
	h.ctrl.set_tool("raise")
	h.ctrl.set_inverted(true)
	var before := h.doc.sample_height(40, 40)
	h.act("tool_begin", h.at(40, 40, 1.0))
	var t := 1.0
	while t < 1.4:
		t += 1.0 / 60.0
		h.ctrl.advance(t)
	h.act("tool_end", h.at(40, 40, t + 0.01))
	assert_eq(h.commits[0].label, "Lower terrain")
	assert_true(h.doc.sample_height(40, 40) < before - 0.1)


# --- Settings ----------------------------------------------------------------------------

func test_settings_defaults() -> void:
	var sculpt := h.ctrl.settings("sculpt")
	assert_eq([sculpt.radius, sculpt.strength], [6.0, 1.0])
	var paint := h.ctrl.settings("paint")
	assert_eq([paint.radius, paint.strength, paint.layer, paint.tint], [4.0, 0.8, 1, 0])
	assert_eq(h.ctrl.settings("place"), {"radius": 7.0, "strength": 0.7})
	assert_eq(h.ctrl.settings("brush"), {"shape": "soft", "alpha_mode": "circle", "pressure_enabled": true})
	assert_true(is_nan(h.ctrl.settings("flatten").target))
	assert_eq(h.ctrl.settings("path"), {"width": 2.4})
	assert_eq(h.ctrl.settings("scatter"), {"source": "set:forest", "avoid_objects": true})
	assert_eq(h.ctrl.settings("select"), {})
	assert_eq(h.ctrl.settings("nonsense"), {})


func test_settings_clamp_and_validate() -> void:
	assert_empty_string(h.ctrl.set_setting("place", "radius", 99))
	assert_eq(h.ctrl.settings("place").radius, 20.0)
	assert_empty_string(h.ctrl.set_setting("place", "radius", 0.0))
	assert_eq(h.ctrl.settings("place").radius, 1.0)
	assert_empty_string(h.ctrl.set_setting("place", "strength", 5.0))
	assert_eq(h.ctrl.settings("place").strength, 1.0)
	assert_empty_string(h.ctrl.set_setting("path", "width", 0.2))
	assert_eq(h.ctrl.settings("path").width, 1.0)
	assert_empty_string(h.ctrl.set_setting("sculpt", "strength", 0.0))
	assert_eq(h.ctrl.settings("sculpt").strength, 0.05)
	assert_empty_string(h.ctrl.set_setting("paint", "layer", 3))
	assert_empty_string(h.ctrl.set_setting("paint", "tint", 2.0))
	assert_eq([h.ctrl.settings("paint").layer, h.ctrl.settings("paint").tint], [3, 2])
	assert_error_contains(h.ctrl.set_setting("paint", "layer", 4), "paint.layer")
	assert_error_contains(h.ctrl.set_setting("paint", "layer", -1), "paint.layer")
	assert_error_contains(h.ctrl.set_setting("paint", "layer", 1.5), "paint.layer")
	assert_error_contains(h.ctrl.set_setting("paint", "tint", 3), "paint.tint")
	assert_error_contains(h.ctrl.set_setting("brush", "shape", "blob"), "brush.shape")
	assert_error_contains(h.ctrl.set_setting("brush", "alpha_mode", "x"), "brush.alpha_mode")
	assert_error_contains(h.ctrl.set_setting("brush", "pressure_enabled", 1), "brush.pressure_enabled")
	assert_error_contains(h.ctrl.set_setting("scatter", "source", "forest"), "scatter.source")
	assert_error_contains(h.ctrl.set_setting("scatter", "source", "set:"), "scatter.source")
	assert_error_contains(h.ctrl.set_setting("scatter", "avoid_objects", "yes"), "scatter.avoid_objects")
	assert_error_contains(h.ctrl.set_setting("sculpt", "radius", NAN), "sculpt.radius")
	assert_error_contains(h.ctrl.set_setting("nonsense", "radius", 1.0), "nonsense.radius")
	assert_error_contains(h.ctrl.set_setting("paint", "bogus", 1), "bogus")
	assert_error_contains(h.ctrl.set_setting("paint", "material", "grass"), "paint.material", "legacy key is gone")
	for key in ["shape", "alpha_mode"]:
		assert_empty_string(h.ctrl.set_setting("brush", key, "hard" if key == "shape" else "stamp"))
	assert_empty_string(h.ctrl.set_setting("scatter", "source", "mix"))
	assert_empty_string(h.ctrl.set_setting("scatter", "source", "set:meadow"))
	assert_empty_string(h.ctrl.set_setting("flatten", "target", 12.3))
	assert_eq(h.ctrl.settings("flatten").target, 12.3)
	assert_empty_string(h.ctrl.set_setting("flatten", "target", NAN))
	assert_true(is_nan(h.ctrl.settings("flatten").target), "NAN means stroke start")
	assert_error_contains(h.ctrl.set_setting("flatten", "target", INF), "flatten.target")


func test_settings_changed_carries_the_namespace() -> void:
	h.ctrl.set_setting("brush", "shape", "ring")
	h.ctrl.set_setting("paint", "bogus", 1)
	h.ctrl.set_snap_enabled(false)
	assert_eq(setting_events, ["brush", "select"] as Array[String])


# --- Operation mapping -------------------------------------------------------------------

func test_paint_layers_and_erase() -> void:
	h.ctrl.set_setting("paint", "layer", 0)
	_tap(40, 40)
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Paint Grass")
	h.ctrl.set_setting("paint", "layer", 1)
	h.act("tool_begin", h.at(60, 40, 2.0))
	h.act("tool_move", h.at(64, 40, 2.02))
	h.act("tool_end", h.at(64, 40, 2.04))
	assert_eq(h.commits[h.commits.size() - 1].label, "Paint Dirt")
	for layer in [2, 3]:
		h.ctrl.set_setting("paint", "layer", layer)
		h.act("tool_begin", h.at(40, 60, 3.0))
		assert_true(h.ctrl.has_active_operation(), "layer %d paints" % layer)
		h.act("tool_end", h.at(40, 60, 3.02))
		assert_eq(h.commits[h.commits.size() - 1].label, "Paint " + ["Grass", "Dirt", "Rock", "Sand"][layer])
		assert_eq(ControlCodec.get_overlay(h.doc.get_control_at_sample(80, 120)), layer)
	h.ctrl.set_setting("paint", "layer", 1)
	h.ctrl.set_inverted(true)
	h.act("tool_begin", h.at(40, 60, 4.0))
	h.act("tool_end", h.at(40, 60, 4.02))
	assert_eq(h.commits[h.commits.size() - 1].label, "Erase paint")
	assert_true(h.diagnostics.is_empty(), "no later-build messages")


func test_every_tool_is_implemented() -> void:
	for mode_id: String in ToolController.MODES:
		for id: String in ToolController.TOOLS_BY_MODE[mode_id]:
			assert_true(ToolController.IMPLEMENTED.has(id), id)


# --- Armed placement ---------------------------------------------------------------------

func test_armed_asset_places_in_any_mode_then_selects_and_disarms() -> void:
	h.ctrl.set_tool("raise")
	assert_empty_string(h.ctrl.arm_asset(ToolHarness.BOULDER))
	assert_eq(h.ctrl.armed_asset(), ToolHarness.BOULDER)
	assert_eq(h.ctrl.active_tool(), "raise", "arming keeps the tool")
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_eq(h.ctrl.stroke_state(), "Placing")
	h.act("tool_move", h.at(41, 40, 1.02))
	assert_true(h.presenter.has_ghost_visible())
	h.act("tool_end", h.at(41, 40, 1.04))
	assert_eq(h.doc.objects.size(), 1)
	assert_eq(h.doc.assets.definition(h.doc.get_object(h.ctrl.selected_id()).binding_id).asset_id, ToolHarness.BOULDER)
	assert_eq([h.ctrl.mode(), h.ctrl.active_tool(), h.ctrl.armed_asset()], ["place", "select", ""])
	assert_eq(h.commits[0].label, "Place " + h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	h.act("tool_begin", h.at(60, 60, 2.0))
	h.act("tool_end", h.at(60, 60, 2.02))
	assert_eq(h.doc.objects.size(), 1, "disarmed: select tool places nothing")


func test_failed_placement_stays_armed_and_disarm_works() -> void:
	assert_empty_string(h.ctrl.arm_asset(ToolHarness.SPRUCE))
	h.act("tool_begin", h.at(40, 40, 1.0))
	h.act("tool_end", h.sky(1.02))
	assert_eq(h.doc.objects.size(), 0)
	assert_eq(h.ctrl.armed_asset(), ToolHarness.SPRUCE)
	h.ctrl.disarm()
	assert_eq(h.ctrl.armed_asset(), "")
	assert_eq(setting_events, ["armed", "armed"] as Array[String])
	h.act("tool_begin", h.at(40, 40, 2.0))
	h.act("tool_end", h.at(40, 40, 2.02))
	assert_eq(h.doc.objects.size(), 0, "paint layer 1 painted, nothing placed")


func test_arm_refusals() -> void:
	assert_error_contains(h.ctrl.arm_asset("nature.rock.missing"), "missing")
	assert_eq(h.ctrl.armed_asset(), "")
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_eq(h.ctrl.arm_asset(ToolHarness.BOULDER), ToolController.BUSY)
	h.act("tool_end", h.at(40, 40, 1.02))


func test_library_drop_also_selects_resets_mode_and_disarms() -> void:
	h.ctrl.set_tool("raise")
	h.ctrl.arm_asset(ToolHarness.SPRUCE)
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.BOULDER))
	var pos := h.at(40.2, 40.3, 0.0).position_viewport
	h.ctrl.update_drop(pos, false)
	h.ctrl.finish_drop(pos, false)
	assert_eq(h.doc.objects.size(), 1)
	assert_eq(h.doc.assets.definition(h.doc.get_object(h.ctrl.selected_id()).binding_id).asset_id, ToolHarness.BOULDER)
	assert_eq([h.ctrl.mode(), h.ctrl.active_tool(), h.ctrl.armed_asset()], ["place", "select", ""])


func test_rotate_ghost_turns_the_placement_yaw() -> void:
	assert_ne(h.ctrl.rotate_ghost(15.0), "", "nothing to rotate")
	h.ctrl.arm_asset(ToolHarness.BOULDER)
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_empty_string(h.ctrl.rotate_ghost(15.0))
	assert_empty_string(h.ctrl.rotate_ghost(15.0))
	assert_empty_string(h.ctrl.rotate_ghost(-15.0))
	assert_empty_string(h.ctrl.rotate_ghost(45.0))
	h.act("tool_end", h.at(40, 40, 1.02))
	var rec := h.doc.get_object(h.ctrl.selected_id())
	assert_near(rad_to_deg(rec.get_yaw()), 60.0, 1e-6)
	h.ctrl.arm_asset(ToolHarness.BOULDER)
	h.act("tool_begin", h.at(60, 40, 2.0))
	h.ctrl.rotate_ghost(-30.0)
	h.act("tool_end", h.at(60, 40, 2.02))
	var second := h.doc.get_object(h.ctrl.selected_id())
	assert_near(rad_to_deg(second.get_yaw()), -30.0, 1e-6)


func test_rotate_ghost_works_on_a_library_drop_and_snaps_when_enabled() -> void:
	assert_empty_string(h.ctrl.begin_drop(ToolHarness.BOULDER))
	var pos := h.at(40, 40, 0.0).position_viewport
	h.ctrl.update_drop(pos, false)
	h.ctrl.rotate_ghost(20.0)
	h.ctrl.finish_drop(pos, false)
	var rec := h.doc.get_object(h.ctrl.selected_id())
	assert_near(rad_to_deg(rec.get_yaw()), 15.0, 1e-6, "20 degrees snaps to the 15 degree step")


# --- Height pick -------------------------------------------------------------------------

func test_height_pick_samples_the_tapped_terrain_into_flatten_target() -> void:
	assert_ne(h.ctrl.begin_height_pick(), "", "only with the flatten tool")
	h.ctrl.set_tool("flatten")
	assert_empty_string(h.ctrl.begin_height_pick())
	assert_true(h.ctrl.is_picking_height())
	_tap(40, 40)
	var hit_y := h.ctrl.last_hit().position.y
	assert_false(h.ctrl.is_picking_height())
	assert_near(float(h.ctrl.settings("flatten").target), hit_y, 1e-9)
	assert_eq(h.diagnostics, ["Target height %.1f m" % hit_y])
	assert_eq(h.commits.size(), 0, "no history")
	assert_false(h.ctrl.has_active_operation())
	_tap(60, 60, 2.0)
	assert_eq(h.diagnostics.size(), 1, "flatten is a working tool: no stub message once picking is over")


func test_height_pick_miss_or_ui_release_keeps_picking() -> void:
	h.ctrl.set_tool("flatten")
	h.ctrl.begin_height_pick()
	h.act("tool_begin", h.sky(1.0))
	h.act("tool_end", h.sky(1.02))
	assert_eq(h.diagnostics, ["No terrain under the Pencil."])
	assert_true(h.ctrl.is_picking_height())
	assert_true(is_nan(h.ctrl.settings("flatten").target), "a miss never stores 0")
	_tap(40, 40, 2.0, true)
	assert_true(h.ctrl.is_picking_height(), "released over a panel")
	assert_eq(h.diagnostics.size(), 1)
	_tap(40, 40, 3.0)
	assert_false(h.ctrl.is_picking_height())
	assert_eq(h.diagnostics.size(), 2)


func test_height_pick_is_cancelled_by_tool_or_mode_change_or_tool_cancel() -> void:
	h.ctrl.set_tool("flatten")
	h.ctrl.begin_height_pick()
	h.ctrl.set_tool("raise")
	assert_false(h.ctrl.is_picking_height())
	h.ctrl.set_tool("flatten")
	h.ctrl.begin_height_pick()
	h.ctrl.set_mode("paint")
	assert_false(h.ctrl.is_picking_height())
	h.ctrl.set_tool("flatten")
	h.ctrl.begin_height_pick()
	h.act("tool_begin", h.at(40, 40, 1.0))
	h.ctrl.handle_tool_action({"type": "tool_cancel", "reason": "native_cancel"})
	h.act("tool_end", h.at(40, 40, 1.02))
	assert_true(h.ctrl.is_picking_height(), "a cancelled contact picks nothing")
	assert_true(is_nan(h.ctrl.settings("flatten").target))
	h.ctrl.cancel_height_pick()
	assert_false(h.ctrl.is_picking_height())
	h.ctrl.editing_enabled = false
	assert_ne(h.ctrl.begin_height_pick(), "")


# --- Scatter source ----------------------------------------------------------------------

func _allow_only(allowed: Array[String]) -> void:
	for id in h.catalog.sorted_ids():
		h.catalog.get_asset(id).scatter_allowed = id in allowed


func test_scatter_config_resolves_sets_and_drops_unusable_items() -> void:
	_allow_only([ToolHarness.SPRUCE, ToolHarness.BOULDER])
	var cfg := h.ctrl.scatter_config()
	assert_eq(cfg.name, "Spruce forest")
	assert_eq([cfg.density, cfg.spacing, cfg.slope_min, cfg.slope_max, cfg.align], [0.6, 1.4, 0.0, 35.0, false])
	var ids: Array[String] = []
	for item: Dictionary in cfg.items:
		assert_true(h.catalog.get_asset(item.asset_id).scatter_allowed)
		ids.append(item.asset_id)
	assert_true(ids.has(ToolHarness.SPRUCE) and ids.has(ToolHarness.BOULDER))
	assert_eq(cfg.items[0], {"asset_id": ToolHarness.SPRUCE, "weight": 6.0})
	_allow_only([ToolHarness.SPRUCE])
	ids.clear()
	for item: Dictionary in h.ctrl.scatter_config().items:
		ids.append(item.asset_id)
	assert_false(ids.has(ToolHarness.BOULDER), "assets that are not scatter_allowed are dropped")
	var custom := {"id": "ghosts", "name": "Ghosts", "items": [{"asset_id": "no.such.asset", "weight": 1.0},
			{"asset_id": ToolHarness.SPRUCE, "weight": 3.0}], "density": 2.0, "spacing": 1.0,
			"slope_min": 0.0, "slope_max": 50.0, "align": true}
	assert_empty_string(h.ctrl.set_store().put_set(custom))
	assert_empty_string(h.ctrl.set_setting("scatter", "source", "set:ghosts"))
	assert_eq(h.ctrl.scatter_config().items, [{"asset_id": ToolHarness.SPRUCE, "weight": 3.0}], "missing asset dropped")
	h.ctrl.set_setting("scatter", "source", "set:unknown")
	assert_eq(h.ctrl.scatter_config().items, [])


func test_quick_mix_accepts_only_scatter_allowed_assets() -> void:
	_allow_only([ToolHarness.SPRUCE, ToolHarness.BOULDER])
	assert_eq(h.ctrl.quick_mix(), PackedStringArray())
	assert_error_contains(h.ctrl.set_quick_mix(PackedStringArray([ToolHarness.SPRUCE, ToolHarness.LODGE])), ToolHarness.LODGE)
	assert_error_contains(h.ctrl.set_quick_mix(PackedStringArray(["no.such"])), "no.such")
	assert_eq(h.ctrl.quick_mix(), PackedStringArray(), "a refused mix changes nothing")
	assert_empty_string(h.ctrl.set_quick_mix(PackedStringArray([ToolHarness.SPRUCE, ToolHarness.BOULDER, ToolHarness.SPRUCE])))
	assert_eq(h.ctrl.quick_mix(), PackedStringArray([ToolHarness.SPRUCE, ToolHarness.BOULDER]))
	h.ctrl.set_setting("scatter", "source", "mix")
	var cfg := h.ctrl.scatter_config()
	assert_eq(cfg.name, "Quick mix")
	assert_eq([cfg.density, cfg.spacing, cfg.slope_min, cfg.slope_max, cfg.align], [1.2, 0.8, 0.0, 45.0, true])
	assert_eq(cfg.items, [{"asset_id": ToolHarness.SPRUCE, "weight": 1.0}, {"asset_id": ToolHarness.BOULDER, "weight": 1.0}])
	var copy := h.ctrl.quick_mix()
	copy.append("x")
	assert_eq(h.ctrl.quick_mix().size(), 2, "quick_mix returns a copy")
	assert_empty_string(h.ctrl.set_quick_mix(PackedStringArray()))
	assert_eq(h.ctrl.scatter_config().items, [], "empty mix resolves to no items")


# --- Duplicate ---------------------------------------------------------------------------

func test_not_ready_assets_cannot_be_armed_dropped_duplicated_or_placed() -> void:
	var stub := StubRenderRegistry.hiding(h.catalog, [ToolHarness.SPRUCE])
	h.ctx.render_ready = stub.is_ready
	var message := "%s is not ready: render derivatives missing." % h.catalog.get_asset(ToolHarness.SPRUCE).display_name
	assert_eq(h.ctrl.arm_asset(ToolHarness.SPRUCE), message)
	assert_eq(h.ctrl.armed_asset(), "")
	assert_eq(h.ctrl.begin_drop(ToolHarness.SPRUCE), message)
	assert_false(h.ctrl.has_drop())
	var rec := h.add_object(ToolHarness.SPRUCE, 40.0, 40.0)
	h.ctrl.select(rec.object_id)
	assert_eq(h.ctrl.duplicate_selected(), message)
	assert_eq(h.doc.objects.size(), 1, "nothing was duplicated")
	assert_eq(h.commits.size(), 0)
	assert_empty_string(h.ctrl.arm_asset(ToolHarness.BOULDER))
	h.ctx.render_ready = func(_id: String) -> bool: return false
	_tap(40.0, 40.0)
	assert_eq(h.ctrl.armed_asset(), "", "an armed asset that lost readiness is disarmed instead of placed")
	assert_eq(h.doc.objects.size(), 1)
	assert_true(h.diagnostics.back().contains("not ready"))


func test_duplicate_is_one_undoable_transaction_and_selects_the_copy() -> void:
	var rec := h.add_object(ToolHarness.BOULDER, 40.0, 40.0, 0.2)
	h.ctrl.select(rec.object_id)
	var yaw_edit := rec.clone()
	ObjectEdits.apply_yaw(yaw_edit, 30.0, 0.0)
	h.doc.put_object(yaw_edit)
	assert_empty_string(h.ctrl.duplicate_selected())
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Duplicate " + h.catalog.get_asset(ToolHarness.BOULDER).display_name)
	assert_eq(h.doc.objects.size(), 2)
	var copy := h.ctrl.selected_record()
	assert_ne(copy.object_id, rec.object_id)
	assert_near(copy.position[0], 43.0, 1e-9)
	assert_near(copy.position[2], 41.5, 1e-9)
	assert_near(copy.position[1], h.doc.sample_height(43.0, 41.5) + 0.2, 1e-9, "regrounded with the height offset")
	assert_near(rad_to_deg(copy.get_yaw()), 30.0, 1e-6, "yaw and scale are copied")
	assert_eq(copy.origin, WorldConstants.ORIGIN_MANUAL)
	assert_true(h.presenter.has_object(copy.object_id))
	h.history.undo(h.doc)
	assert_eq(h.doc.objects.size(), 1)
	assert_true(h.doc.get_object(copy.object_id) == null)
	h.history.redo(h.doc)
	assert_true(h.doc.get_object(copy.object_id).equals(copy), "redo restores the exact copy")


func test_duplicate_grounding_modes_and_world_edge_clamp() -> void:
	var lodge := h.add_object(ToolHarness.LODGE, 40.0, 40.0)
	h.ctrl.select(lodge.object_id)
	assert_empty_string(h.ctrl.duplicate_selected())
	var copy := h.ctrl.selected_record()
	assert_eq(copy.grounding, lodge.grounding)
	assert_near(copy.position[1], h.doc.sample_height(43.0, 41.5), 1e-9)
	var edge := h.add_object(ToolHarness.BOULDER, 127.0, 127.0)
	h.ctrl.select(edge.object_id)
	assert_empty_string(h.ctrl.duplicate_selected())
	var clamped := h.ctrl.selected_record()
	assert_eq([clamped.position[0], clamped.position[2]], [127.5, 127.5])
	assert_near(clamped.position[1], h.doc.sample_height(127.5, 127.5), 1e-9)


func test_duplicate_refusals() -> void:
	assert_eq(h.ctrl.duplicate_selected(), ToolController.NO_SELECTION)
	var rec := h.add_object(ToolHarness.BOULDER, 40.0, 40.0)
	h.ctrl.select(rec.object_id)
	h.act("tool_begin", h.at(10, 10, 2.0))
	assert_eq(h.ctrl.duplicate_selected(), ToolController.BUSY)
	h.act("tool_end", h.at(10, 10, 2.02))
	assert_eq(h.doc.objects.size(), 1)
	assert_eq(h.commits.size(), 1, "only the paint stroke")


# --- Paths -------------------------------------------------------------------------------

func _add_path() -> PathRecord:
	var p := PathRecord.new()
	p.path_id = ObjectRecord.new_uuid_v4()
	p.width_m = 2.4
	p.points = PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(30, 10)])
	h.doc.put_path(p)
	return p


func test_path_selection_signal_and_validation() -> void:
	var events: Array[String] = []
	h.ctrl.path_selection_changed.connect(func(id: String) -> void: events.append(id))
	var p := _add_path()
	assert_eq(h.ctrl.selected_path_id(), "")
	h.ctrl.select_path("not-a-path")
	assert_eq(h.ctrl.selected_path_id(), "")
	h.ctrl.select_path(p.path_id)
	h.ctrl.select_path(p.path_id)
	assert_eq(h.ctrl.selected_path_id(), p.path_id)
	assert_eq(events, [p.path_id] as Array[String], "one event per change")
	h.doc.remove_path(p.path_id)
	h.ctrl.validate_selection()
	assert_eq(h.ctrl.selected_path_id(), "")
	assert_eq(events, [p.path_id, ""] as Array[String])
	h.ctrl.select_path(_add_path().path_id)
	assert_empty_string(h.ctrl.set_document(h.doc))
	assert_eq(h.ctrl.selected_path_id(), "", "a document swap clears the path selection")


func test_delete_selected_path_is_one_undoable_action() -> void:
	assert_eq(h.ctrl.delete_selected_path(), ToolController.NO_PATH_SELECTION)
	var p := _add_path()
	h.ctrl.select_path(p.path_id)
	assert_empty_string(h.ctrl.delete_selected_path())
	assert_eq(h.commits.size(), 1)
	assert_eq(h.commits[0].label, "Delete path")
	assert_true(h.doc.get_path_record(p.path_id) == null)
	assert_eq(h.ctrl.selected_path_id(), "")
	h.history.undo(h.doc)
	assert_true(h.doc.get_path_record(p.path_id).equals(p), "undo restores the exact path")
	h.history.redo(h.doc)
	assert_true(h.doc.get_path_record(p.path_id) == null)


# --- Mac development keys and status ----------------------------------------------------

func test_dev_keys() -> void:
	h.ctrl.set_tool("raise")
	assert_true(SessionWorldOps.dev_key(h.ctrl, KEY_D))
	assert_true(h.ctrl.inverted())
	SessionWorldOps.dev_key(h.ctrl, KEY_D)
	assert_false(h.ctrl.inverted())
	assert_true(SessionWorldOps.dev_key(h.ctrl, KEY_BRACKETRIGHT))
	assert_eq(h.ctrl.settings("sculpt").radius, 7.0)
	SessionWorldOps.dev_key(h.ctrl, KEY_BRACKETLEFT)
	SessionWorldOps.dev_key(h.ctrl, KEY_BRACKETLEFT)
	assert_eq(h.ctrl.settings("sculpt").radius, 5.0)
	h.ctrl.set_mode("place")
	SessionWorldOps.dev_key(h.ctrl, KEY_BRACKETRIGHT)
	assert_eq(h.ctrl.settings("place").radius, 8.0, "place mode has a radius too")
	h.ctrl.set_mode("paint")
	for i in 30:
		SessionWorldOps.dev_key(h.ctrl, KEY_BRACKETRIGHT)
	assert_eq(h.ctrl.settings("paint").radius, 16.0, "clamped")
	assert_false(SessionWorldOps.dev_key(h.ctrl, KEY_X))
	h.ctrl.arm_asset(ToolHarness.BOULDER)
	h.act("tool_begin", h.at(40, 40, 1.0))
	assert_true(SessionWorldOps.dev_key(h.ctrl, KEY_E))
	assert_true(SessionWorldOps.dev_key(h.ctrl, KEY_Q))
	assert_true(SessionWorldOps.dev_key(h.ctrl, KEY_E))
	h.act("tool_end", h.at(40, 40, 1.02))
	assert_near(rad_to_deg(h.ctrl.selected_record().get_yaw()), 15.0, 1e-6)
	h.ctrl.arm_asset(ToolHarness.BOULDER)
	assert_false(SessionWorldOps.dev_key(h.ctrl, KEY_ESCAPE), "Esc still reaches the cancel path")
	assert_eq(h.ctrl.armed_asset(), "")


func test_tool_status_keys() -> void:
	h.ctrl.set_tool("flatten")
	h.ctrl.begin_height_pick()
	h.ctrl.arm_asset(ToolHarness.BOULDER)
	assert_eq(SessionWorldOps.tool_status(h.ctrl), {"mode": "sculpt", "tool": "flatten", "inverted": false,
			"armed_asset": ToolHarness.BOULDER, "picking_height": false}, "arming cancels picking")
