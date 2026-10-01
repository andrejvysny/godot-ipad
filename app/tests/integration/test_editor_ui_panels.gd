extends UiTestCase
## Editor v2 rules section, history tiles, actions, world menu, registration, hints and toasts.

# --- rules -----------------------------------------------------------------------------------

func test_rule_toggle_and_scrub_are_one_history_action_each() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "paint")
	var rules := ui.popover().section("rules") as RulesSection
	assert_true(rules.switch_button("rock").button_pressed and s.document.rules.rock_enabled)
	await _pencil_click(s, rules.switch_button("rock"))
	assert_false(s.document.rules.rock_enabled)
	assert_eq(s.history.size(), 1)
	assert_eq(s.history.peek_undo_label(), "Toggle rule")
	assert_false(rules.switch_button("rock").button_pressed)
	await _pencil_click(s, rules.switch_button("sand"))
	assert_false(s.document.rules.sand_enabled)
	assert_eq(s.history.size(), 2)
	var slope := s.document.rules.rock_slope_deg
	await _scrub_drag(s, rules.scrub("rock"))
	assert_ne(s.document.rules.rock_slope_deg, slope, "scrub changes the slope")
	assert_eq(s.history.size(), 3, "one scrub = one action")
	assert_eq(s.history.peek_undo_label(), "Edit auto-paint rule")
	assert_eq(rules.scrub("rock").value, float(s.document.rules.rock_slope_deg))
	var sand := s.document.rules.sand_height_dm
	await _scrub_drag(s, rules.scrub("sand"))
	assert_ne(s.document.rules.sand_height_dm, sand)
	assert_eq(s.history.size(), 4)
	assert_eq(rules.scrub("sand").value, s.document.rules.sand_height_dm / 10.0, "sand is shown in metres")
	s.undo()
	assert_eq(s.document.rules.sand_height_dm, sand, "undo restores the rule")


func test_rule_scrub_cancel_restores_and_unchanged_scrub_has_no_history() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "paint")
	var rules := ui.popover().section("rules") as RulesSection
	var slope := s.document.rules.rock_slope_deg
	await _scrub_drag(s, rules.scrub("rock"), PointerSample.Phase.CANCEL)
	assert_eq(s.document.rules.rock_slope_deg, slope, "ui_cancelled restores the rules")
	assert_eq(rules.scrub("rock").value, float(slope))
	assert_eq(s.history.size(), 0)
	assert_false(s.tools.rule_edits().is_open())
	var rect := _rect(rules.scrub("rock"))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, rect.get_center())
	assert_true(s.tools.rule_edits().is_open(), "scrub open while pressed")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, rect.get_center())
	assert_false(s.tools.rule_edits().is_open())
	assert_eq(s.history.size(), 0, "no history when unchanged")


func test_highlight_switch_calls_the_terrain() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _tool(s, "paint")
	var rules := ui.popover().section("rules") as RulesSection
	assert_false(s.terrain.get_rule_highlight())
	await _pencil_click(s, rules.highlight_switch())
	assert_true(s.terrain.get_rule_highlight())
	assert_true(rules.highlight_switch().button_pressed)
	await _pencil_click(s, rules.highlight_switch())
	assert_false(s.terrain.get_rule_highlight())
	assert_eq(s.history.size(), 0, "highlight is view only")


# --- history tiles, actions, menu ------------------------------------------------------------

func test_undo_redo_toasts_name_the_action() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _pencil_click(s, ui.history_tiles().undo_button())
	assert_eq(ui.toast().label().text, "Nothing to undo")
	await _pencil_click(s, ui.history_tiles().redo_button())
	assert_eq(ui.toast().label().text, "Nothing to redo")
	assert_eq(s.tools.rule_edits().toggle("rock"), "")
	await _frames(2)
	assert_eq(ui.history_tiles().undo_button().modulate.a, 1.0)
	await _pencil_click(s, ui.history_tiles().undo_button())
	assert_eq(ui.toast().label().text, "Undid Toggle rule")
	assert_true(s.document.rules.rock_enabled)
	assert_eq(ui.history_tiles().redo_button().modulate.a, 1.0)
	await _pencil_click(s, ui.history_tiles().redo_button())
	assert_eq(ui.toast().label().text, "Redid Toggle rule")
	assert_false(s.document.rules.rock_enabled)


func test_export_toast_reports_the_result() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _pencil_click(s, ui.action_pill().export_button())
	var text := ui.toast().label().text
	assert_true(text.begins_with("Exported revision 0") or ui.toast().label().get_theme_color("font_color") == UiKit.DANGER_TEXT, text)
	assert_true(ui.toast().visible)


func test_library_toggle_shows_and_hides_the_library() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_true(ui.library().is_open() and ui.action_pill().library_button().button_pressed)
	await _pencil_click(s, ui.action_pill().library_button())
	await _frames(2)
	assert_false(ui.library().visible)
	assert_false(ui.action_pill().library_button().button_pressed)
	await _pencil_click(s, ui.action_pill().library_button())
	await _frames(2)
	assert_true(ui.library().visible and ui.library().is_open())
	ui.library().set_open(false)
	assert_false(ui.action_pill().library_button().button_pressed, "toggle follows the Library state")


func test_confirm_dialog_gates_open_fixture_and_blocks_world_input() -> void:
	var s := await _start()
	var ui := _ui(s)
	var world_id := s.document.world_id
	var tool_actions: Array[String] = []
	s.input.tool_action.connect(func(a: Dictionary) -> void: tool_actions.append(str(a.type)))
	await _pencil_click(s, ui.world_pill().world_button())
	assert_true(ui.world_menu().visible)
	await _pencil_click(s, ui.world_menu().item("gentle_hills"))
	var dialog := ui.confirm_dialog()
	assert_true(dialog.visible, "dialog shown")
	assert_false(ui.world_menu().visible, "menu closes")
	assert_true(s.input.router.is_modal())
	await _world_tap(s, Vector2(600, 400))
	assert_true(tool_actions.is_empty(), "no tool action while modal: %s" % str(tool_actions))
	await _pencil_click(s, dialog.cancel_button())
	assert_false(dialog.visible)
	assert_eq(s.document.world_id, world_id, "cancel leaves the world")
	await _pencil_click(s, ui.world_pill().world_button())
	await _pencil_click(s, ui.world_menu().item("gentle_hills"))
	await _pencil_click(s, dialog.confirm_button())
	assert_ne(s.document.world_id, world_id, "confirm replaces the world")
	assert_eq(ui.world_pill().name_text(), "Gentle Hills")
	assert_eq(s.history.size(), 0)


func test_world_menu_save_and_reset_camera_close_the_menu() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _pencil_click(s, ui.world_pill().world_button())
	await _pencil_click(s, ui.world_menu().item("reset_camera"))
	assert_false(ui.world_menu().visible)
	assert_eq(ui.toast().label().text, "Camera reset")
	await _pencil_click(s, ui.world_pill().world_button())
	await _pencil_click(s, ui.world_menu().item("save"))
	assert_false(ui.world_menu().visible)
	assert_false(ui.world_pill().world_button().button_pressed)


func test_diagnostics_toggle_shows_text() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_false(ui.diagnostics_overlay().visible)
	await _pencil_click(s, ui.world_pill().world_button())
	await _pencil_click(s, ui.world_menu().item("diagnostics"))
	assert_true(ui.diagnostics_overlay().visible)
	var text := ui.diagnostics_overlay().text()
	assert_true(text.contains("Revision"), text)
	assert_true(text.contains(str(s.status().renderer)), text)
	assert_false(text.contains("PoC+"), "no stale scatter placeholder")
	for part in ["Mode paint · tool paint · invert off", "scatter 0 inst", "paths ", "Rules rock on 30° · sand on -0.4 m · highlight off"]:
		assert_true(text.contains(part), "%s in %s" % [part, text])
	var overlay := ui.diagnostics_overlay()
	ui.layout_override = Vector2(1180, 500)
	ui.layout()
	assert_true(overlay.position.y + overlay.size.y <= ui.chip().position.y, "overlay stays above the chip: %s %s" % [overlay.size, ui.chip().position])
	ui.layout_override = Vector2.ZERO


func test_long_toast_wraps_within_the_free_span() -> void:
	var s := await _start()
	var ui := _ui(s)
	ui.layout_override = Vector2(1180, 820)
	ui.toast().show_message("word ".repeat(80), false)
	ui.layout()
	var toast := ui.toast()
	assert_true(toast.size.x <= 560.0 + 40.0, "capped width %s" % toast.size)
	assert_true(toast.size.y > 40.0, "wrapped to several lines %s" % toast.size)
	ui.toast().fit_width(200.0)
	assert_true(toast.label().custom_minimum_size.x <= 200.0, "narrow span respected %s" % toast.label().custom_minimum_size)
	ui.layout_override = Vector2.ZERO


func test_save_caption_matches_the_spec_wording() -> void:
	assert_eq(WorldMenu.save_caption("Saved revision 4"), "Saved · revision 4")
	assert_eq(WorldMenu.save_caption("Saving revision 5"), "Saving revision 5")
	assert_eq(WorldMenu.save_caption("Unsaved"), "Unsaved")


func test_registration_of_panels_and_non_blocking_overlays() -> void:
	var s := await _start()
	var ui := _ui(s)
	var panels := ui.registered_panels()
	assert_eq(panels.size(), 11)
	for c: Control in [ui.world_pill(), ui.world_menu(), ui.history_tiles(), ui.action_pill(), ui.mode_rail(),
			ui.popover(), ui.chip(), ui.library(), ui.inspector(), ui.diagnostics_overlay(), ui.set_editor()]:
		assert_true(panels.has(c), "%s registered" % c)
	for c: Control in [ui.gesture_hints(), ui.toast(), ui.ghost_label()]:
		assert_false(panels.has(c), "%s must not be registered" % c)
		assert_eq(c.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	await _tool(s, "paint")
	var before := s.authored_hash()
	s.post_message("hello")
	await _frames(2)
	var toast_pos := _center(ui.toast())
	assert_false(s.input.ui_hits.is_over_ui(toast_pos), "a Pencil over the toast edits the world")
	assert_true(s.input.ui_hits.is_over_ui(_center(ui.popover())))
	assert_true(s.input.ui_hits.is_over_ui(_center(ui.chip())))
	assert_eq(s.authored_hash(), before)


func test_gesture_hints_variants() -> void:
	var s := await _start()
	var hints := _ui(s).gesture_hints()
	assert_eq(hints.lines(), PackedStringArray(["1 finger orbit · 2 fingers pan / zoom",
			"Pencil edits · Invert on the chip", "Library: drag to place"]))
	hints.set_development(true)
	await _frames(1)
	assert_eq(hints.lines(), PackedStringArray(["Click edits · right-drag orbit · middle-drag pan · wheel zoom",
			"D inverts · [ ] brush size · Q/E rotate ghost", "Esc cancels"]))
	var position := hints.get_global_rect().position
	assert_true(position.x < 40.0, "bottom-left")


func test_toast_colours_and_duration() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.post_message("x", true)
	assert_eq(ui.toast().label().text, "x")
	assert_eq(ui.toast().label().get_theme_color("font_color"), UiKit.DANGER_TEXT)
	assert_true(ui.toast().visible)
	assert_eq(Toast.SECONDS, 2.2)
	s.post_message("fine")
	assert_eq(ui.toast().label().get_theme_color("font_color"), UiKit.TEXT)


func test_screenshot_state_parser_selects_tool_and_opens_popover() -> void:
	var s := await _start("stress_100")
	var ui := _ui(s)
	assert_eq(UiScreenshot.apply_state(ui, s, "sculpt:flatten"), "")
	assert_eq(s.tools.active_tool(), "flatten")
	assert_true(ui.popover().is_open())
	assert_eq(UiScreenshot.apply_state(ui, s, "place:select:closed:select"), "")
	assert_false(ui.popover().is_open())
	assert_ne(s.tools.selected_id(), "")
	assert_ne(UiScreenshot.apply_state(ui, s, "paint:raise"), "", "tool outside its mode")
