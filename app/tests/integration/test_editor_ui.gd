extends UiTestCase
## Editor v2 top bar, mode rail, chip and tool popover (docs/editor-v2.md §9). Tests address controls
## through component accessors, never captions.

# --- top bar, rail, chip ---------------------------------------------------------------------

func test_required_controls_exist_with_design_sizes() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_true(ui != null, "ui built")
	assert_eq(ui.history_tiles().undo_button().size, Vector2(52, 38))
	assert_eq(ui.history_tiles().redo_button().size, Vector2(52, 38))
	for mode in ToolModel.MODES:
		assert_eq(ui.mode_rail().tile(mode).size, Vector2(52, 52), mode)
	assert_true(ui.chip().main_button().is_visible_in_tree() and ui.chip().main_button().size.y >= 36.0)
	assert_true(ui.world_pill().world_button().is_visible_in_tree())
	assert_true(ui.action_pill().export_button().size.y >= 38.0)
	assert_eq(ui.world_pill().name_text(), "Flat", "fixture name from source_label")
	assert_true(ui.world_menu().save_label().text.begins_with("Saved · revision 0"), ui.world_menu().save_label().text)
	assert_near(ui.history_tiles().undo_button().modulate.a, 0.4, 0.001, "unavailable undo is dimmed")
	assert_near(ui.history_tiles().redo_button().modulate.a, 0.4, 0.001)
	assert_false(ui.history_tiles().cancel_button().visible)
	assert_false(ui.popover().is_open(), "popover starts closed")
	assert_eq(ui.chip().label_text(), "Paint Dirt")
	assert_eq(ui.chip().sub_text(), "4.0 m · 80%")


func test_rail_switches_modes_and_toggles_popover() -> void:
	var s := await _start()
	var ui := _ui(s)
	var popover := ui.popover()
	await _pencil_click(s, ui.mode_rail().tile("paint"))
	assert_true(popover.is_open(), "active mode opens the popover")
	assert_eq(popover.title_text(), "PAINT TOOLS")
	await _pencil_click(s, ui.mode_rail().tile("paint"))
	assert_false(popover.is_open(), "active mode toggles it closed")
	await _pencil_click(s, ui.mode_rail().tile("sculpt"))
	assert_eq(s.tools.mode(), "sculpt")
	assert_eq(s.tools.active_tool(), "raise", "each mode remembers its tool")
	assert_true(popover.is_open(), "another mode switches and opens")
	assert_true(ui.mode_rail().tile("sculpt").button_pressed)
	assert_false(ui.mode_rail().tile("paint").button_pressed)
	assert_eq(popover.title_text(), "SCULPT TOOLS")
	await _pencil_click(s, ui.chip().main_button())
	assert_false(popover.is_open(), "chip tap toggles the popover")
	await _pencil_click(s, ui.chip().main_button())
	assert_true(popover.is_open())
	await _pencil_click(s, ui.mode_rail().tile("place"))
	assert_eq(s.tools.active_tool(), "scatter")
	assert_eq(s.history.size(), 0)


func test_finger_never_operates_controls_but_pencil_picks_a_tool() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "raise")
	var before := s.authored_hash()
	var p := _center(ui.popover().tool_tile("flatten"))
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.BEGIN, p)
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.END, p)
	assert_eq(s.tools.active_tool(), "raise", "finger never operates controls")
	await _pencil_click(s, ui.popover().tool_tile("flatten"))
	assert_eq(s.tools.active_tool(), "flatten")
	assert_true(ui.popover().tool_tile("flatten").button_pressed)
	assert_eq(s.authored_hash(), before)
	assert_eq(s.history.size(), 0)


func test_chip_texts_per_tool() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_tool("raise")
	assert_eq(ui.chip().label_text(), "Raise")
	assert_eq(ui.chip().sub_text(), "6.0 m · 100%")
	s.tools.set_setting("sculpt", "radius", 7.0)
	s.tools.set_setting("sculpt", "strength", 0.5)
	assert_eq(ui.chip().sub_text(), "7.0 m · 50%")
	s.tools.set_inverted(true)
	assert_eq(ui.chip().label_text(), "Lower")
	assert_eq(ui.chip().label_color(), UiKit.DANGER_TEXT, "inverted label uses the danger colour")
	s.tools.set_tool("paint")
	assert_eq(ui.chip().label_text(), "Paint Dirt")
	assert_eq(ui.chip().label_color(), UiKit.ACCENT)
	s.tools.set_setting("paint", "layer", 0)
	s.tools.set_tool("spray")
	assert_eq(ui.chip().label_text(), "Spray Grass")
	s.tools.set_tool("tint")
	assert_eq(ui.chip().label_text(), "Tint")
	s.tools.set_tool("pick")
	assert_eq(ui.chip().sub_text(), "tap terrain")
	s.tools.set_tool("select")
	assert_eq(ui.chip().sub_text(), "drag from Library")
	s.tools.set_tool("path")
	assert_eq(ui.chip().sub_text(), "width 2.4 m")
	s.tools.set_tool("scatter")
	assert_eq(ui.chip().sub_text(), "Spruce forest · 7.0 m · 70%")
	s.tools.set_inverted(true)
	assert_eq(ui.chip().label_text(), "Erase")
	assert_eq(ui.chip().sub_text(), "7.0 m · 70%", "inverted scatter drops the set name")
	s.tools.set_tool("erase")
	assert_eq(ui.chip().sub_text(), "7.0 m · 70%")
	s.tools.set_tool("fill")
	assert_eq(ui.chip().sub_text(), "Spruce forest")
	s.tools.set_inverted(true)
	assert_eq(ui.chip().label_text(), "Clear")
	assert_eq(ui.chip().sub_text(), "clear loop")


func test_invert_button_visibility_state_and_d_key() -> void:
	var s := await _start()
	var ui := _ui(s)
	var invertible := {"raise": "Lower", "noise": "Smooth", "paint": "Erase", "spray": "Erase", "tint": "Remove",
			"scatter": "Erase", "fill": "Clear"}
	for tool_id: String in ["raise", "flatten", "noise", "paint", "spray", "tint", "pick", "select", "scatter", "erase", "fill", "path"]:
		s.tools.set_tool(tool_id)
		assert_eq(ui.chip().invert_button().visible, invertible.has(tool_id), tool_id)
		if invertible.has(tool_id):
			assert_eq(ui.chip().invert_button().text, invertible[tool_id], tool_id)
	await _tool(s, "raise", false)
	assert_false(ui.chip().invert_button().button_pressed)
	await _pencil_click(s, ui.chip().invert_button())
	assert_true(s.tools.inverted())
	assert_true(ui.chip().invert_button().button_pressed)
	assert_eq(ui.chip().label_text(), "Lower")
	await _pencil_click(s, ui.chip().invert_button())
	assert_false(s.tools.inverted())
	assert_true(SessionWorldOps.dev_key(s.tools, KEY_D), "D key still inverts")
	assert_true(s.tools.inverted())
	assert_true(ui.chip().invert_button().button_pressed, "chip follows the D key")
	assert_eq(ui.chip().label_text(), "Lower")
	s.tools.set_tool("noise")
	assert_false(s.tools.inverted(), "tool change clears invert")
	assert_false(ui.chip().invert_button().button_pressed)


func test_operation_start_closes_popover_and_menu() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "paint")
	await _pencil_click(s, ui.world_pill().world_button())
	assert_true(ui.world_menu().visible and ui.world_pill().world_button().button_pressed)
	assert_true(ui.popover().is_open())
	var centre := _centre_world(s)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, centre)
	assert_true(s.tools.has_active_operation(), "stroke started")
	assert_false(ui.popover().is_open(), "drawing closes the popover")
	assert_false(ui.world_menu().visible, "and the world menu")
	assert_false(ui.world_pill().world_button().button_pressed)
	assert_true(ui.history_tiles().cancel_button().visible, "explicit Cancel while an operation is open")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, centre)


func test_dismiss_closes_popover_and_menu() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "paint")
	ui.world_menu().toggle_open(true)
	s.tools.dismiss()
	assert_false(ui.popover().is_open())
	assert_false(ui.world_menu().visible)


# --- popover ----------------------------------------------------------------------------------

func test_popover_sections_per_tool() -> void:
	var s := await _start()
	var ui := _ui(s)
	var expected := {
		"raise": ["size", "strength", "alpha", "pressure"],
		"flatten": ["height", "size", "strength", "alpha", "pressure"],
		"noise": ["size", "strength", "alpha", "pressure"],
		"paint": ["swatches", "size", "strength", "alpha", "pressure", "rules"],
		"spray": ["swatches", "size", "strength", "alpha", "pressure", "rules"],
		"tint": ["tints", "size", "strength", "alpha", "pressure", "rules"],
		"pick": ["swatches", "rules"],
		"select": ["snap"],
		"scatter": ["source", "size", "strength", "alpha", "pressure", "avoid"],
		"erase": ["size", "strength", "alpha"],
		"fill": ["source", "avoid"],
		"path": ["width"],
	}
	var counts := {"sculpt": 3, "paint": 4, "place": 5}
	for tool_id: String in expected:
		await _tool(s, tool_id)
		assert_eq(Array(ui.popover().shown_sections()), expected[tool_id], tool_id)
		assert_true(ui.popover().hint_text().begins_with(ToolTexts.HINTS[tool_id]), tool_id + " hint")
		assert_eq(ui.popover().visible_tool_ids().size(), counts[s.tools.mode()], tool_id + " tiles")
		assert_true(ui.popover().tool_tile(tool_id).button_pressed, tool_id + " tile pressed")
	await _tool(s, "scatter")
	assert_eq(ui.popover().scrub("strength").caption, "Flow", "place mode names strength Flow")
	assert_eq(ui.popover().section("pressure").text, "Pressure to flow")
	await _tool(s, "raise")
	assert_eq(ui.popover().scrub("strength").caption, "Strength")
	assert_eq(ui.popover().section("pressure").text, "Pressure to strength")


func test_delete_selected_path_action_needs_a_selected_path() -> void:
	var s := await _start()
	var ui := _ui(s)
	var rec := PathRecord.new()
	rec.path_id = ObjectRecord.new_uuid_v4()
	rec.points = PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 5)])
	s.document.put_path(rec)
	await _tool(s, "path")
	assert_false(ui.popover().section("delete_path").visible)
	s.tools.select_path(rec.path_id)
	await _frames(2)
	assert_true(ui.popover().section("delete_path").visible)
	await _pencil_click(s, ui.popover().section("delete_path") as Control)
	assert_eq(s.history.peek_undo_label(), "Delete path")
	assert_eq(s.tools.selected_path_id(), "")
	assert_false(ui.popover().section("delete_path").visible)


func test_swatches_set_paint_layer_and_tint() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "paint")
	var layers := ui.popover().section("swatches") as SwatchRow
	await _pencil_click(s, layers.swatch(0))
	assert_eq(s.tools.settings("paint").layer, 0)
	assert_eq(layers.selected(), 0)
	assert_eq(ui.chip().label_text(), "Paint Grass")
	await _pencil_click(s, layers.swatch(2))
	assert_eq(s.tools.settings("paint").layer, 2)
	assert_eq(ui.chip().label_text(), "Paint Rock")
	await _tool(s, "tint")
	await _pencil_click(s, (ui.popover().section("tints") as SwatchRow).swatch(2))
	assert_eq(s.tools.settings("paint").tint, 2)
	assert_eq(s.history.size(), 0)


func test_scrubs_write_the_mode_namespace_and_cancel_restores() -> void:
	var s := await _start()
	var ui := _ui(s)
	var cases := [["raise", "sculpt"], ["paint", "paint"], ["scatter", "place"]]
	for entry: Array in cases:
		await _tool(s, entry[0])
		var ns: String = entry[1]
		var before := s.tools.settings(ns)
		var others := {}
		for other: String in ["sculpt", "paint", "place"]:
			others[other] = s.tools.settings(other)
		var changes: Array[String] = []
		var counter := func(changed: String) -> void: changes.append(changed)
		s.tools.settings_changed.connect(counter)
		await _scrub_drag(s, ui.popover().scrub("size"))
		s.tools.settings_changed.disconnect(counter)
		assert_ne(s.tools.settings(ns).radius, before.radius, "%s size" % ns)
		assert_eq(s.tools.settings(ns).strength, before.strength, "size drag leaves strength alone")
		assert_true(changes.size() >= 1 and changes.all(func(c: String) -> bool: return c == ns), "%s changes %s" % [ns, changes])
		for other: String in others:
			if other != ns:
				assert_eq(str(s.tools.settings(other)), str(others[other]), "%s untouched by %s scrub" % [other, ns])
		var strength_before: float = s.tools.settings(ns).strength
		await _scrub_drag(s, ui.popover().scrub("strength"))
		assert_ne(s.tools.settings(ns).strength, strength_before, "%s strength" % ns)
	assert_eq(s.history.size(), 0, "settings never touch history")
	await _tool(s, "path")
	var width_before: float = s.tools.settings("path").width
	await _scrub_drag(s, ui.popover().scrub("width"))
	assert_ne(s.tools.settings("path").width, width_before)
	var start: float = s.tools.settings("path").width
	await _scrub_drag(s, ui.popover().scrub("width"), PointerSample.Phase.CANCEL)
	assert_eq(s.tools.settings("path").width, start, "ui_cancelled restores the width")
	assert_eq(ui.popover().scrub("width").value, start)
	await _tool(s, "raise")
	var radius: float = s.tools.settings("sculpt").radius
	await _scrub_drag(s, ui.popover().scrub("size"), PointerSample.Phase.CANCEL)
	assert_eq(s.tools.settings("sculpt").radius, radius, "ui_cancelled restores the size")
	assert_eq(s.history.size(), 0)


func test_scrub_press_does_not_jump_and_is_relative() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "raise")
	var field := ui.popover().scrub("size")
	var start: float = s.tools.settings("sculpt").radius
	var rect := _rect(field)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, Vector2(rect.position.x + rect.size.x * 0.8, rect.get_center().y))
	assert_eq(s.tools.settings("sculpt").radius, start, "press does not jump")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, Vector2(rect.position.x + rect.size.x * 0.8, rect.get_center().y))
	assert_eq(s.tools.settings("sculpt").radius, start, "tap leaves the value")


func test_alpha_tiles_and_mode_segmented_update_brush_settings() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "raise")
	var alpha := ui.popover().section("alpha") as BrushAlphaSection
	assert_true(alpha.tile("soft").button_pressed and alpha.mode_button("circle").button_pressed)
	assert_eq(alpha.hint_text(), "Alpha centred on the Pencil tip.")
	for shape in BrushAlpha.SHAPES:
		assert_true(alpha.tile(shape).icon != null, shape + " has a preview")
		await _pencil_click(s, alpha.tile(shape))
		assert_eq(s.tools.settings("brush").shape, shape)
		assert_true(alpha.tile(shape).button_pressed)
	await _pencil_click(s, alpha.mode_button("stamp"))
	assert_eq(s.tools.settings("brush").alpha_mode, "stamp")
	assert_eq(alpha.hint_text(), "Alpha rotates to follow the stroke direction.")
	await _pencil_click(s, alpha.mode_button("pattern"))
	assert_eq(s.tools.settings("brush").alpha_mode, "pattern")
	assert_eq(alpha.hint_text(), "Alpha tiles in world space; the stroke reveals it.")
	await _tool(s, "scatter")
	assert_true(alpha.tile("streak").button_pressed, "the alpha is shared by every brush tool")
	assert_eq(s.history.size(), 0)


func test_switches_write_their_settings() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "raise")
	var pressure := ui.popover().section("pressure") as Button
	assert_true(pressure.button_pressed)
	await _pencil_click(s, pressure)
	assert_eq(s.tools.settings("brush").pressure_enabled, false)
	await _tool(s, "scatter")
	assert_false((ui.popover().section("pressure") as Button).button_pressed, "pressure is shared")
	var avoid := ui.popover().section("avoid") as Button
	assert_true(avoid.button_pressed)
	await _pencil_click(s, avoid)
	assert_eq(s.tools.settings("scatter").avoid_objects, false)
	await _tool(s, "select")
	var snap := ui.popover().section("snap") as Button
	assert_true(snap.button_pressed and s.tools.snap_enabled())
	await _pencil_click(s, snap)
	assert_false(s.tools.snap_enabled())
	assert_eq(snap.text, "Snap move to 0.5 m")
	await _tool(s, "erase")
	assert_false(ui.popover().section("pressure").visible, "erase has no pressure switch")


func test_flatten_pick_flow_reopens_the_popover() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "flatten")
	var row := ui.popover().section("height") as HeightTargetRow
	assert_eq(row.value_text(), "stroke start")
	await _pencil_click(s, row.pick_button())
	assert_true(s.tools.is_picking_height())
	assert_false(ui.popover().is_open(), "popover closes while picking")
	assert_eq(ui.toast().label().text, "Tap the terrain to sample its height")
	await _world_tap(s, _centre_world(s))
	assert_false(s.tools.is_picking_height())
	assert_true(is_finite(float(s.tools.settings("flatten").target)), "tap sampled the height")
	assert_true(ui.popover().is_open(), "popover reopens after the pick")
	assert_true(row.value_text().ends_with(" m"), row.value_text())
	assert_eq(s.history.size(), 0)


func test_scatter_source_card_change_and_edit_hook() -> void:
	var s := await _start()
	var ui := _ui(s)
	var spruce := s.catalog.get_asset("nature.tree.spruce_a")
	spruce.scatter_allowed = true
	await _tool(s, "scatter")
	var card := ui.popover().section("source") as SourceCard
	assert_eq(card.kicker_text(), "SCATTER SET")
	assert_eq(card.name_text(), "Spruce forest · density 0.6")
	assert_eq(card.edit_button().text, "Edit set")
	assert_true(card.segment_count() >= 1)
	ui.library().set_open(false)
	await _frames(2)
	await _pencil_click(s, card.change_button())
	assert_true(ui.library().is_open(), "Change opens the Library")
	await _pencil_click(s, card.edit_button())
	assert_true(ui.set_editor().is_open(), "Edit set opens the set editor")
	ui.set_editor().close()
	var sources: Array[String] = []
	ui.edit_set_hook = func(source: String) -> void: sources.append(source)
	await _pencil_click(s, card.edit_button())
	assert_eq(sources, ["set:forest"] as Array[String])
	s.tools.set_quick_mix(PackedStringArray(["nature.tree.spruce_a"]))
	s.tools.set_setting("scatter", "source", "mix")
	await _frames(2)
	assert_eq(card.kicker_text(), "QUICK MIX · 1 ASSETS")
	assert_eq(card.edit_button().text, "Save as set")
	assert_eq(card.segment_count(), 1)
