extends TestCase
## Editor interface through the real iOS Pencil path: FakeProvider samples -> router -> synthetic
## mouse events -> Controls (IN-02, IN-03, OB-03, spec §9, §14.3, §18.3).

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")

var sessions: Array = []
var fake: InputTests.FakeProvider
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	allow_logged_errors()  # the pinned Terrain3D binary logs one known deprecation warning
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	for s: Variant in sessions:
		if is_instance_valid(s):
			if s.get_parent() != null:
				tree.root.remove_child(s)
			s.free()
	sessions.clear()
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


func _start(fixture: String = "flat") -> EditorSession:
	fake = InputTests.FakeProvider.new()
	var s := EditorSession.new()
	s.storage_root = scratch_dir() + "/worlds"
	s.start_fixture = fixture
	s.provider_override = fake
	s.platform_override = "iOS"
	s.build_ui = true
	sessions.append(s)
	tree.root.add_child(s)
	await _frames(3)
	for i in 300:
		if not s.storage.is_busy():
			break
		await tree.process_frame
	return s


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _center(c: Control) -> Vector2:
	return UiHitTester.screen_rect(c).get_center()


func _feed(s: EditorSession, source: int, phase: int, pos: Vector2, reason: String = "") -> void:
	fake.push(source, 1, phase, pos, reason)
	s.input.run_frame()
	await _frames(3)


func _pencil_click(s: EditorSession, control: Control) -> void:
	var p := _center(control)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, p)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, p)


func _ui(s: EditorSession) -> EditorUI:
	return s.ui as EditorUI


func _rect(c: Control) -> Rect2:
	return UiHitTester.screen_rect(c)


func _select_first(s: EditorSession) -> ObjectRecord:
	var id := s.document.sorted_object_ids()[0]
	s.tools.set_active_tool("select")
	s.tools.select(id)
	await _frames(3)
	return s.document.get_object(id)


func _object_rect(s: EditorSession, id: String) -> Rect2:
	var camera := s.rig.get_camera()
	var bounds := s.presenter.world_bounds(id)
	var rect := Rect2(camera.unproject_position(bounds.get_endpoint(0)), Vector2.ZERO)
	for i in range(1, 8):
		rect = rect.expand(camera.unproject_position(bounds.get_endpoint(i)))
	return rect


func _layout_panels(ui: EditorUI) -> Array[Control]:
	var panels: Array[Control] = [ui.dock(), ui.context_bar(), ui.world_menu(), ui.history_bar()]
	panels.append(ui.library() if ui.library().is_open() else ui.library().strip())
	var actions := ui.reset_view_button().get_parent().get_parent() as Control
	panels.append(actions)
	return panels


func _drag(s: EditorSession, from: Vector2, to: Vector2, end_phase: int = PointerSample.Phase.END) -> void:
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, from)
	for i in range(1, 4):
		await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, from.lerp(to, float(i) / 3.0))
	if end_phase == PointerSample.Phase.CANCEL:
		await _feed(s, PointerSample.Source.PENCIL, end_phase, to, "native_cancel")
	else:
		await _feed(s, PointerSample.Source.PENCIL, end_phase, to)


func test_required_controls_exist_and_are_touch_sized() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_true(ui != null, "ui built")
	var controls: Array[Control] = [ui.history_bar().undo_button(), ui.history_bar().redo_button(),
		ui.world_menu().world_button(), ui.reset_view_button(), ui.export_button()]
	for id in ToolController.TOOLS:
		controls.append(ui.dock().tool_button(id))
	for id in s.catalog.sorted_ids():
		controls.append(ui.library().tile(id))
	controls.append(ui.context_bar().snap_switch())
	for c in controls:
		assert_true(c.is_visible_in_tree() and c.size.y >= 48.0, "%s height %.1f" % [c, c.size.y])
	assert_true(ui.world_menu().save_label().text.begins_with("Saved revision 0"), ui.world_menu().save_label().text)
	assert_eq(ui.world_menu().world_button().text, "Flat", "fixture name from source_label")
	assert_eq(ui.history_bar().undo_caption().text, "Nothing")
	assert_false(ui.history_bar().cancel_button().visible)
	assert_true(ui.dock().tool_button("select").button_pressed)
	s.tools.set_active_tool("paint")
	await _frames(2)
	for key in ["radius", "strength"]:
		var field := ui.context_bar().scrub("paint", key)
		assert_true(field.is_visible_in_tree() and field.size.y >= 48.0, key)
	assert_true(ui.context_bar().pressure_switch("paint").is_visible_in_tree())
	assert_true(ui.context_bar().hint_label().text.begins_with("Draw on terrain"))


func test_pencil_switches_tool_but_finger_does_not() -> void:
	var s := await _start()
	var ui := _ui(s)
	var before := s.authored_hash()
	var p := _center(ui.dock().tool_button("sculpt"))
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.BEGIN, p)
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.END, p)
	assert_eq(s.tools.active_tool(), "select", "finger never operates controls")
	assert_eq(s.authored_hash(), before)
	await _pencil_click(s, ui.dock().tool_button("paint"))
	assert_eq(s.tools.active_tool(), "paint")
	assert_true(ui.dock().tool_button("paint").button_pressed)
	assert_eq(s.authored_hash(), before)
	assert_eq(s.history.size(), 0)


func test_pencil_changes_paint_material_and_library_tap_arms_place() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_active_tool("paint")
	await _frames(2)
	await _pencil_click(s, ui.context_bar().mode_button("paint", "grass"))
	assert_eq(s.tools.settings("paint").material, "grass")
	await _pencil_click(s, ui.context_bar().mode_button("paint", "dirt"))
	assert_eq(s.tools.settings("paint").material, "dirt")
	var id := s.catalog.sorted_ids()[1]
	await _pencil_click(s, ui.library().tile(id))
	assert_eq(s.tools.settings("place").asset_id, id)
	assert_eq(s.tools.active_tool(), "place")
	assert_eq(s.history.size(), 0, "a tap places nothing")
	assert_eq(s.document.objects.size(), 0)
	assert_true(ui.dock().tool_button("place").button_pressed)


func test_context_scrub_drag_is_one_history_free_setting_and_cancel_restores() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_active_tool("path")
	await _frames(2)
	var field := ui.context_bar().scrub("path", "width")
	var rect := _rect(field)
	var y := rect.get_center().y
	var start: float = s.tools.settings("path").width
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, Vector2(rect.position.x + rect.size.x * 0.5, y))
	assert_eq(s.tools.settings("path").width, start, "press does not jump")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(rect.position.x + rect.size.x * 0.9, y))
	assert_ne(s.tools.settings("path").width, start, "drag changes the width")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.CANCEL, Vector2(rect.position.x + rect.size.x * 0.9, y), "native_cancel")
	assert_eq(s.tools.settings("path").width, start, "cancel restores the start value")
	assert_eq(s.history.size(), 0)


func test_object_scrub_drag_is_one_history_action_and_cancel_restores() -> void:
	var s := await _start("stress_100")
	var original := (await _select_first(s)).clone()
	var slider := _ui(s).inspector().scrub("yaw")
	assert_true(slider.is_visible_in_tree(), "inspector visible for a selection")
	var rect := _rect(slider)
	var y := rect.get_center().y
	var history_before := s.history.size()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, Vector2(rect.position.x + rect.size.x * 0.25, y))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(rect.position.x + rect.size.x * 0.5, y))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(rect.position.x + rect.size.x * 0.75, y))
	assert_true(s.tools.has_object_edit(), "edit open during drag %s" % [rect])
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, Vector2(rect.position.x + rect.size.x * 0.75, y))
	assert_false(s.tools.has_object_edit())
	assert_eq(s.history.size(), history_before + 1, "one drag = one history action")
	var edited := s.document.get_object(original.object_id)
	assert_false(edited.equals(original))
	var before_cancel := s.document.get_object(original.object_id).clone()
	rect = _rect(slider)
	var away := 0.1 if slider.value > 0.0 else 0.9  # relative drag: move toward the roomy side of the range
	var from_x := rect.position.x + rect.size.x * (1.0 - away)
	var to_x := rect.position.x + rect.size.x * away
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, Vector2(from_x, y))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(to_x, y))
	assert_true(s.tools.has_object_edit(), "second drag edit open %s" % [rect])
	var size_before := s.history.size()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.CANCEL, Vector2(to_x, y), "native_cancel")
	assert_false(s.tools.has_object_edit())
	assert_eq(s.history.size(), size_before, "cancelled drag creates no entry")
	assert_true(s.document.get_object(original.object_id).equals(before_cancel), "exact record restored")


func test_stepper_plus_on_scale_is_one_history_action() -> void:
	var s := await _start("stress_100")
	var original := (await _select_first(s)).clone()
	var before := s.history.size()
	await _pencil_click(s, _ui(s).inspector().stepper("scale", 1))
	assert_eq(s.history.size(), before + 1)
	assert_true(s.document.get_object(original.object_id).uniform_scale > original.uniform_scale)


func test_confirm_dialog_gates_open_fixture_and_blocks_world_input() -> void:
	var s := await _start()
	var ui := _ui(s)
	var world_id := s.document.world_id
	var tool_actions: Array[String] = []
	s.input.tool_action.connect(func(a: Dictionary) -> void: tool_actions.append(str(a.type)))
	await _pencil_click(s, ui.world_menu().world_button())
	assert_true(ui.world_menu().menu_panel().visible)
	await _pencil_click(s, ui.world_menu().item("gentle_hills"))
	var dialog := ui.confirm_dialog()
	assert_true(dialog.visible, "dialog shown")
	assert_false(ui.world_menu().menu_panel().visible, "menu closes")
	assert_true(s.input.router.is_modal())
	var outside := Vector2(600, 400)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, outside)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, outside)
	assert_true(tool_actions.is_empty(), "no tool action while modal: %s" % str(tool_actions))
	await _pencil_click(s, dialog.cancel_button())
	assert_false(dialog.visible)
	assert_false(s.input.router.is_modal())
	assert_eq(s.document.world_id, world_id, "cancel leaves the world")
	await _pencil_click(s, ui.world_menu().world_button())
	await _pencil_click(s, ui.world_menu().item("gentle_hills"))
	await _pencil_click(s, dialog.confirm_button())
	assert_ne(s.document.world_id, world_id, "confirm replaces the world")
	assert_eq(ui.world_menu().world_button().text, "Gentle Hills")
	assert_eq(s.history.size(), 0)


func test_diagnostics_toggle_shows_text() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_false(ui.diagnostics_overlay().visible)
	await _pencil_click(s, ui.world_menu().world_button())
	await _pencil_click(s, ui.world_menu().item("diagnostics"))
	assert_true(ui.diagnostics_overlay().visible)
	var text := ui.diagnostics_overlay().text()
	assert_true(text.contains("Revision"), text)
	assert_true(text.contains(str(s.status().renderer)), text)
	assert_true(text.contains("scatter: PoC+ (not built)"), text)


func test_panels_stay_inside_viewport_and_apart() -> void:
	var s := await _start("stress_100")
	var ui := _ui(s)
	await _select_first(s)
	ui.diagnostics_overlay().visible = true
	ui.diagnostics_overlay().refresh(true)
	await _pencil_click(s, ui.world_menu().world_button())
	await _frames(2)
	var viewport := tree.root.get_visible_rect()
	var centre := viewport.get_center()
	var panels := ui.registered_panels()
	assert_eq(panels.size(), 10)
	for panel in panels:
		if panel.is_visible_in_tree():
			assert_true(viewport.grow(0.5).encloses(_rect(panel)), "%s %s outside %s" % [panel, _rect(panel), viewport])
	_assert_layout_clear(ui, centre)
	ui.world_menu().close()
	ui.library().set_open(false)
	await _frames(2)
	_assert_layout_clear(ui, centre)


func _assert_layout_clear(ui: EditorUI, centre: Vector2) -> void:
	var panels := _layout_panels(ui)
	for i in panels.size():
		assert_false(_rect(panels[i]).has_point(centre), "%s covers the centre" % panels[i])
		for j in range(i + 1, panels.size()):
			assert_false(_rect(panels[i]).intersects(_rect(panels[j])), "%s overlaps %s" % [panels[i], panels[j]])


func test_library_drag_places_one_object_and_selects_it() -> void:
	var s := await _start()
	var ui := _ui(s)
	var history_before := s.history.size()
	var objects_before := s.document.objects.size()
	var centre := tree.root.get_visible_rect().get_center()
	await _drag(s, _center(ui.library().tile("nature.rock.boulder_a")), centre)
	assert_eq(s.document.objects.size(), objects_before + 1, "one object placed")
	assert_eq(s.history.size(), history_before + 1)
	var id := s.tools.selected_id()
	assert_ne(id, "", "new object selected")
	assert_eq(s.tools.active_tool(), "select")
	assert_false(s.presenter.has_ghost_visible())
	await _frames(2)
	assert_true(ui.inspector().visible, "inspector shown for the new selection")
	assert_false(_rect(ui.inspector()).intersects(_object_rect(s, id)), "inspector clear of the object")
	assert_true(tree.root.get_visible_rect().encloses(_rect(ui.inspector())))


func test_inspector_avoids_neighbouring_object() -> void:
	var s := await _start()
	var ui := _ui(s)
	var centre := tree.root.get_visible_rect().get_center()
	var tile := _center(ui.library().tile("nature.rock.boulder_a"))
	await _drag(s, tile, centre)
	var first := s.tools.selected_id()
	await _drag(s, tile, centre + Vector2(60, 0))
	var second := s.tools.selected_id()
	assert_ne(first, second, "two distinct objects")
	await _frames(2)
	assert_true(ui.inspector().visible)
	var other := _object_rect(s, first).get_center()
	assert_false(_rect(ui.inspector()).has_point(other), "inspector does not cover the neighbour")


func test_library_drag_released_over_ui_or_cancelled_creates_nothing() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_active_tool("paint")
	await _frames(2)
	var tile := _center(ui.library().tile("nature.rock.boulder_a"))
	var centre := tree.root.get_visible_rect().get_center()
	var history_before := s.history.size()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, tile)
	for i in range(1, 4):
		await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, tile.lerp(centre, float(i) / 3.0))
	assert_true(s.tools.has_drop() and s.presenter.has_ghost_visible(), "drop open while dragging")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, tile)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, tile)
	assert_eq(s.document.objects.size(), 0)
	assert_eq(s.history.size(), history_before)
	assert_false(s.presenter.has_ghost_visible() or s.tools.has_drop())
	assert_eq(s.tools.active_tool(), "paint", "no tap side effects")
	await _drag(s, tile, centre, PointerSample.Phase.CANCEL)
	assert_eq(s.document.objects.size(), 0)
	assert_eq(s.history.size(), history_before)
	assert_false(s.presenter.has_ghost_visible() or s.tools.has_drop())
	assert_eq(s.tools.active_tool(), "paint", "cancel is not a tap")


func test_inspector_hidden_during_operations_and_for_other_tools() -> void:
	var s := await _start("stress_100")
	var ui := _ui(s)
	await _select_first(s)
	assert_true(ui.inspector().visible)
	s.tools.set_active_tool("paint")
	await _frames(2)
	assert_false(ui.inspector().visible, "hidden when tool != select")
	var centre := tree.root.get_visible_rect().get_center()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, centre)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, centre + Vector2(20, 0))
	assert_true(s.tools.has_active_operation(), "stroke active")
	assert_false(ui.inspector().visible, "hidden during a stroke")
	assert_true(ui.history_bar().cancel_button().visible, "explicit Cancel while an operation is open")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, centre + Vector2(20, 0))
	s.tools.set_active_tool("select")
	await _frames(2)
	assert_true(ui.inspector().visible)


func test_left_handed_layout_mirrors_dock_and_library() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_false(ui.is_left_handed())
	await _pencil_click(s, ui.world_menu().world_button())
	await _pencil_click(s, ui.world_menu().item("left_handed"))
	await _frames(2)
	assert_true(ui.is_left_handed())
	assert_true(_rect(ui.dock()).position.x > _rect(ui.library()).end.x, "dock right of the Library")
	_assert_layout_clear(ui, tree.root.get_visible_rect().get_center())
	var viewport := tree.root.get_visible_rect()
	for panel in _layout_panels(ui):
		assert_true(viewport.grow(0.5).encloses(_rect(panel)), "%s outside" % panel)


func test_library_collapses_to_strip_and_strip_reopens() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_true(ui.library().is_open())
	await _pencil_click(s, ui.library().collapse_button())
	await _frames(2)
	assert_false(ui.library().is_open())
	assert_false(ui.library().visible)
	assert_true(ui.library().strip().visible)
	assert_true(_rect(ui.library().strip()).size.x <= 64.0)
	await _pencil_click(s, ui.library().strip())
	await _frames(2)
	assert_true(ui.library().is_open() and ui.library().visible)
	assert_false(ui.library().strip().visible)


func test_error_toast_uses_danger_colour() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.post_message("x", true)
	assert_eq(ui.toast_label().text, "x")
	assert_eq(ui.toast_label().get_theme_color("font_color"), UiKit.DANGER_TEXT)
	s.post_message("fine")
	assert_eq(ui.toast_label().get_theme_color("font_color"), UiKit.TEXT)
