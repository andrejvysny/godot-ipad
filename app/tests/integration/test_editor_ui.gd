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


func test_required_controls_exist_and_are_touch_sized() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_true(ui != null, "ui built")
	var controls: Array[Control] = [ui.action_button("Undo"), ui.action_button("Redo"),
		ui.action_button("Save"), ui.action_button("Export")]
	for id in ToolController.TOOLS:
		controls.append(ui.tool_button(id))
	for id in s.catalog.sorted_ids():
		controls.append(ui.asset_strip().tile_button(id))
	for c in controls:
		assert_true(c.is_visible_in_tree() and c.size.y >= 48.0, "%s height %.1f" % [c, c.size.y])
	assert_true(ui.revision_label().text.begins_with("Revision 0 · Saved revision 0"), ui.revision_label().text)
	assert_true(ui.tool_label().text.begins_with("SELECT · Idle"), ui.tool_label().text)
	s.tools.set_active_tool("paint")
	await _frames(2)
	for key in ["radius", "strength"]:
		var slider := ui.tool_panel().brush_slider("paint", key)
		assert_true(slider.is_visible_in_tree() and slider.size.y >= 48.0, key)


func test_pencil_switches_tool_but_finger_does_not() -> void:
	var s := await _start()
	var ui := _ui(s)
	var before := s.authored_hash()
	var button := ui.tool_button("sculpt")
	var p := _center(button)
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.BEGIN, p)
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.END, p)
	assert_eq(s.tools.active_tool(), "select", "finger never operates controls")
	assert_eq(s.authored_hash(), before)
	await _pencil_click(s, ui.tool_button("paint"))
	assert_eq(s.tools.active_tool(), "paint")
	assert_true(ui.tool_button("paint").text.begins_with("▶ "))
	assert_eq(s.authored_hash(), before)
	assert_eq(s.history.size(), 0)


func test_pencil_changes_paint_material_and_asset() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_active_tool("paint")
	await _frames(2)
	await _pencil_click(s, ui.tool_panel().mode_button("paint", "grass"))
	assert_eq(s.tools.settings("paint").material, "grass")
	await _pencil_click(s, ui.tool_panel().mode_button("paint", "dirt"))
	assert_eq(s.tools.settings("paint").material, "dirt")
	var id := s.catalog.sorted_ids()[1]
	await _pencil_click(s, ui.asset_strip().tile_button(id))
	assert_eq(s.tools.settings("place").asset_id, id)
	assert_eq(s.tools.active_tool(), "place")
	assert_true(ui.asset_strip().tile_button(id).text.begins_with("✓ "))


func _select_first(s: EditorSession) -> ObjectRecord:
	var id := s.document.sorted_object_ids()[0]
	s.tools.set_active_tool("select")
	s.tools.select(id)
	await _frames(3)
	return s.document.get_object(id)


func test_object_slider_drag_is_one_history_action_and_cancel_restores() -> void:
	var s := await _start("stress_100")
	var slider := _ui(s).tool_panel().object_slider("yaw")
	var original := (await _select_first(s)).clone()
	var rect := UiHitTester.screen_rect(slider)
	var y := rect.get_center().y
	var history_before := s.history.size()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, Vector2(rect.position.x + rect.size.x * 0.25, y))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(rect.position.x + rect.size.x * 0.5, y))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(rect.position.x + rect.size.x * 0.75, y))
	assert_true(s.tools.has_object_edit(), "edit open during drag")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, Vector2(rect.position.x + rect.size.x * 0.75, y))
	assert_false(s.tools.has_object_edit())
	assert_eq(s.history.size(), history_before + 1, "one drag = one history action")
	var edited := s.document.get_object(original.object_id)
	assert_false(edited.equals(original))
	var before_cancel := s.document.get_object(original.object_id).clone()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, Vector2(rect.position.x + rect.size.x * 0.9, y))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, Vector2(rect.position.x + rect.size.x * 0.1, y))
	assert_true(s.tools.has_object_edit())
	var size_before := s.history.size()
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.CANCEL, Vector2(rect.position.x + rect.size.x * 0.1, y), "native_cancel")
	assert_false(s.tools.has_object_edit())
	assert_eq(s.history.size(), size_before, "cancelled drag creates no entry")
	assert_true(s.document.get_object(original.object_id).equals(before_cancel), "exact record restored")


func test_confirm_dialog_gates_open_fixture_and_blocks_world_input() -> void:
	var s := await _start()
	var ui := _ui(s)
	var world_id := s.document.world_id
	var tool_actions: Array[String] = []
	s.input.tool_action.connect(func(a: Dictionary) -> void: tool_actions.append(str(a.type)))
	await _pencil_click(s, ui.action_button("Open…"))
	await _pencil_click(s, ui.open_menu_button("gentle_hills"))
	var dialog := ui.confirm_dialog()
	assert_true(dialog.visible, "dialog shown")
	assert_true(s.input.router.is_modal())
	var outside := Vector2(600, 400)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, outside)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, outside)
	assert_true(tool_actions.is_empty(), "no tool action while modal: %s" % str(tool_actions))
	await _pencil_click(s, dialog.cancel_button())
	assert_false(dialog.visible)
	assert_false(s.input.router.is_modal())
	assert_eq(s.document.world_id, world_id, "cancel leaves the world")
	await _pencil_click(s, ui.action_button("Open…"))
	await _pencil_click(s, ui.open_menu_button("gentle_hills"))
	await _pencil_click(s, dialog.confirm_button())
	assert_ne(s.document.world_id, world_id, "confirm replaces the world")
	assert_eq(s.history.size(), 0)


func test_diagnostics_toggle_shows_text() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_false(ui.diagnostics_overlay().visible)
	await _pencil_click(s, ui.diag_button())
	assert_true(ui.diagnostics_overlay().visible)
	var text := ui.diagnostics_overlay().text()
	assert_true(text.contains("Revision"), text)
	assert_true(text.contains(str(s.status().renderer)), text)
	assert_true(text.contains("scatter: PoC+ (not built)"), text)


func test_registered_panels_stay_inside_viewport_and_off_centre() -> void:
	var s := await _start("stress_100")
	var ui := _ui(s)
	await _select_first(s)
	ui.diagnostics_overlay().visible = true
	ui.diagnostics_overlay().refresh(true)
	await _pencil_click(s, ui.action_button("Open…"))
	await _frames(2)
	var viewport := tree.root.get_visible_rect()
	var centre := viewport.get_center()
	var panels := ui.registered_panels()
	assert_eq(panels.size(), 6)
	for panel in panels:
		if not panel.is_visible_in_tree():
			continue
		var rect := UiHitTester.screen_rect(panel)
		assert_true(viewport.grow(0.5).encloses(rect), "%s %s outside %s" % [panel, rect, viewport])
		assert_false(rect.has_point(centre), "%s covers the centre" % panel)
		assert_true(rect.end.y <= 768.0 or panel == ui.asset_strip(), "%s taller than 768: %s" % [panel, rect])
