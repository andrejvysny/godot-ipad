extends UiTestCase
## Editor v2 inspector, Library drag/tap, placement ghost label and layout (docs/editor-v2.md §8, §9).

# --- inspector -------------------------------------------------------------------------------

func test_inspector_header_and_stepper_buttons() -> void:
	var s := await _start("stress_100")
	var original := (await _select_first(s)).clone()
	var inspector := _ui(s).inspector()
	assert_true(inspector.visible and inspector.stepper("yaw", 1).is_visible_in_tree())
	var asset := s.catalog.get_asset(original.asset_id)
	assert_eq(inspector.title_text(), asset.display_name)
	assert_eq(inspector.id_text(), original.object_id.substr(0, 8))
	assert_eq(inspector.stepper("yaw", 1).size, Vector2(40, 40))
	var history := s.history.size()
	await _pencil_click(s, inspector.stepper("yaw", 1))
	assert_eq(s.history.size(), history + 1)
	var yaw := wrapf(rad_to_deg(s.document.get_object(original.object_id).get_yaw()), -180.0, 180.0)
	var start := wrapf(rad_to_deg(original.get_yaw()), -180.0, 180.0)
	assert_near(wrapf(yaw - start, -180.0, 180.0), 15.0, 0.01, "yaw +15")
	assert_eq(inspector.value_text("yaw"), "%d°" % roundi(yaw))
	await _pencil_click(s, inspector.stepper("yaw", -1))
	await _pencil_click(s, inspector.stepper("yaw", -1))
	assert_near(wrapf(rad_to_deg(s.document.get_object(original.object_id).get_yaw()) - start, -180.0, 180.0), -15.0, 0.01)
	await _pencil_click(s, inspector.stepper("scale", 1))
	var after_scale := s.document.get_object(original.object_id).uniform_scale
	assert_true(after_scale >= original.uniform_scale)
	assert_eq(inspector.value_text("scale"), "%.1f×" % after_scale)


func test_scale_stepper_clamps_to_the_asset_range() -> void:
	var s := await _start("stress_100")
	var original := await _select_first(s)
	var asset := s.catalog.get_asset(original.asset_id)
	var inspector := _ui(s).inspector()
	for i in 40:
		s.tools.nudge("scale", 0.1)
	await _frames(2)
	assert_near(s.document.get_object(original.object_id).uniform_scale, asset.scale_max, 0.0001, "clamped at the maximum")
	var before := s.history.size()
	await _pencil_click(s, inspector.stepper("scale", 1))
	assert_eq(s.history.size(), before, "a no-op nudge pushes no history")
	for i in 80:
		s.tools.nudge("scale", -0.1)
	assert_near(s.document.get_object(original.object_id).uniform_scale, asset.scale_min, 0.0001, "clamped at the minimum")


func test_inspector_duplicate_selects_the_copy_and_delete_removes() -> void:
	var s := await _start("stress_100")
	var original := await _select_first(s)
	var inspector := _ui(s).inspector()
	var count := s.document.objects.size()
	await _pencil_click(s, inspector.duplicate_button())
	assert_eq(s.document.objects.size(), count + 1)
	assert_ne(s.tools.selected_id(), original.object_id, "the copy is selected")
	assert_true(s.history.peek_undo_label().begins_with("Duplicate "))
	await _frames(2)
	assert_true(inspector.visible)
	assert_eq(inspector.id_text(), s.tools.selected_id().substr(0, 8))
	var selected := s.tools.selected_id()
	await _pencil_click(s, inspector.delete_button())
	assert_eq(s.document.objects.size(), count)
	assert_null_object(s, selected)
	assert_true(s.history.peek_undo_label().begins_with("Delete "))
	await _frames(2)
	assert_false(inspector.visible, "no selection, no inspector")


func assert_null_object(s: EditorSession, id: String) -> void:
	assert_true(s.document.get_object(id) == null, "object %s removed" % id)


func test_inspector_hidden_during_operations_and_for_other_tools() -> void:
	var s := await _start("stress_100")
	var ui := _ui(s)
	await _select_first(s)
	assert_true(ui.inspector().visible)
	s.tools.set_tool("paint")
	await _frames(2)
	assert_false(ui.inspector().visible, "hidden when tool != select")
	var centre := _centre_world(s)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, centre)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, centre + Vector2(20, 0))
	assert_true(s.tools.has_active_operation(), "stroke active")
	assert_false(ui.inspector().visible, "hidden during a stroke")
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, centre + Vector2(20, 0))
	s.tools.set_tool("select")
	await _frames(2)
	assert_true(ui.inspector().visible)


func test_library_drag_places_one_object_and_selects_it() -> void:
	var s := await _start()
	var ui := _ui(s)
	var history_before := s.history.size()
	var objects_before := s.document.objects.size()
	await _drag(s, _center(ui.library().tile(BOULDER)), _centre_world(s))
	assert_eq(s.document.objects.size(), objects_before + 1, "one object placed")
	assert_eq(s.history.size(), history_before + 1)
	var id := s.tools.selected_id()
	assert_ne(id, "", "new object selected")
	assert_eq(s.tools.active_tool(), "select")
	assert_eq(s.tools.mode(), "place")
	assert_false(s.presenter.has_ghost_visible())
	await _frames(2)
	assert_true(ui.inspector().visible, "inspector shown for the new selection")
	assert_false(_rect(ui.inspector()).intersects(_object_rect(s, id)), "inspector clear of the object")
	assert_true(tree.root.get_visible_rect().encloses(_rect(ui.inspector())))


func test_inspector_avoids_neighbouring_object() -> void:
	var s := await _start()
	var ui := _ui(s)
	var tile := _center(ui.library().tile(BOULDER))
	await _drag(s, tile, _centre_world(s))
	var first := s.tools.selected_id()
	await _drag(s, tile, _centre_world(s) + Vector2(60, 0))
	var second := s.tools.selected_id()
	assert_ne(first, second, "two distinct objects")
	await _frames(2)
	assert_true(ui.inspector().visible)
	var other := _object_rect(s, first).get_center()
	assert_false(_rect(ui.inspector()).has_point(other), "inspector does not cover the neighbour")


func test_library_drag_released_over_ui_or_cancelled_creates_nothing() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_tool("paint")
	await _frames(2)
	var tile := _center(ui.library().tile(BOULDER))
	var centre := _centre_world(s)
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


func test_library_tap_arms_and_chip_names_the_asset() -> void:
	var s := await _start()
	var ui := _ui(s)
	var id := s.catalog.sorted_ids()[1]
	await _pencil_click(s, ui.library().tile(id))
	assert_eq(s.tools.armed_asset(), id)
	assert_eq(ui.toast().label().text, "Tap the terrain to place %s" % s.catalog.get_asset(id).display_name)
	assert_eq(ui.chip().label_text(), s.catalog.get_asset(id).display_name)
	assert_false(ui.chip().invert_button().visible)
	assert_eq(s.history.size(), 0, "a tap places nothing")
	assert_eq(s.document.objects.size(), 0)
	await _pencil_click(s, ui.mode_rail().tile("sculpt"))
	assert_eq(s.tools.armed_asset(), "", "choosing a mode disarms")


# --- placement ghost label -------------------------------------------------------------------

func test_place_preview_and_ghost_label_texts() -> void:
	var s := await _start()
	var ui := _ui(s)
	var name := s.catalog.get_asset(BOULDER).display_name
	assert_false(s.tools.place_preview().active)
	assert_false(ui.ghost_label().visible)
	s.tools.arm_asset(BOULDER)
	var centre := _centre_world(s)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, centre)
	var preview := s.tools.place_preview()
	assert_true(preview.active and preview.valid and not preview.over_ui, str(preview))
	assert_eq(preview.asset_name, name)
	assert_eq(preview.conflict, "")
	assert_near(float(preview.slope_deg), 0.0, 0.5, "flat world")
	assert_near(float(preview.yaw_deg), 0.0, 0.01)
	await _frames(2)
	assert_true(ui.ghost_label().visible)
	assert_eq(ui.ghost_label().title_text(), "Lift to place %s" % name)
	assert_eq(ui.ghost_label().title_color(), UiKit.ACCENT)
	assert_eq(ui.ghost_label().sub_text(), "Slope 0° · yaw 0°")
	s.tools.rotate_ghost(15.0)
	await _frames(2)
	assert_eq(ui.ghost_label().sub_text(), "Slope 0° · yaw 15°")
	var panel_pos := _center(ui.chip().main_button())
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, panel_pos)
	assert_true(s.tools.place_preview().over_ui, "over a panel")
	await _frames(2)
	assert_eq(ui.ghost_label().title_text(), "Over a panel · lift to cancel")
	assert_eq(ui.ghost_label().title_color(), UiKit.DANGER_TEXT)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, centre)
	assert_false(s.tools.place_preview().over_ui)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, centre)
	assert_eq(s.document.objects.size(), 1, "placed")
	await _frames(2)
	assert_false(ui.ghost_label().visible, "label hides with the ghost")
	assert_false(s.tools.place_preview().active)


func test_ghost_label_warns_when_too_close_but_still_places() -> void:
	var s := await _start()
	var ui := _ui(s)
	var name := s.catalog.get_asset(BOULDER).display_name
	var centre := _centre_world(s)
	s.tools.arm_asset(BOULDER)
	await _world_tap(s, centre)
	assert_eq(s.document.objects.size(), 1)
	s.tools.arm_asset(BOULDER)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, centre)
	assert_eq(s.tools.place_preview().conflict, name, "footprints overlap")
	await _frames(2)
	assert_eq(ui.ghost_label().title_text(), "Too close to %s" % name)
	assert_eq(ui.ghost_label().title_color(), UiKit.WARN_TEXT)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, centre)
	assert_eq(s.document.objects.size(), 2, "a warning does not block placement")


# --- layout, registration --------------------------------------------------------------------

func _layout_panels(ui: EditorUI) -> Array[Control]:
	var all: Array[Control] = [ui.world_pill(), ui.history_tiles(), ui.action_pill(), ui.mode_rail(), ui.popover(),
			ui.chip(), ui.library(), ui.inspector()]
	var shown: Array[Control] = []
	for c in all:
		if c.is_visible_in_tree():
			shown.append(c)
	return shown


func _assert_layout_clear(ui: EditorUI, size: Vector2, label: String) -> void:
	var viewport := Rect2(Vector2.ZERO, size)
	var panels := _layout_panels(ui)
	for i in panels.size():
		var rect := panels[i].get_global_rect()
		assert_true(viewport.grow(0.5).encloses(rect), "%s: %s %s outside %s" % [label, panels[i], rect, viewport])
		if panels[i] != ui.inspector():  # the inspector follows its object, which may sit anywhere
			assert_false(rect.has_point(size * 0.5), "%s: %s covers the centre" % [label, panels[i]])
		for j in range(i + 1, panels.size()):
			assert_false(rect.intersects(panels[j].get_global_rect()), "%s: %s overlaps %s" % [label, panels[i], panels[j]])


func test_layout_fits_both_reference_sizes_and_mirrors() -> void:
	var s := await _start("stress_100")
	var ui := _ui(s)
	for size in SIZES:
		ui.layout_override = size
		for left in [false, true]:
			ui.set_left_handed(left)
			for tool_id: String in ["paint", "scatter", "flatten", "path", "select"]:
				s.tools.set_tool(tool_id)
				if tool_id == "select":
					s.tools.select(s.document.sorted_object_ids()[0])
				ui.popover().set_open(true)
				await _frames(3)
				_assert_layout_clear(ui, size, "%s %s left=%s" % [size, tool_id, left])
			ui.popover().set_open(false)
			ui.library().set_open(false)
			await _frames(2)
			_assert_layout_clear(ui, size, "%s closed left=%s" % [size, left])
			ui.library().set_open(true)
	ui.layout_override = Vector2.ZERO


func test_left_handed_layout_mirrors_rail_popover_and_library() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_false(ui.is_left_handed())
	await _tool(s, "paint")
	assert_true(_rect(ui.mode_rail()).end.x < _rect(ui.library()).position.x, "rail left of the Library")
	assert_true(_rect(ui.popover()).position.x > _rect(ui.mode_rail()).end.x)
	await _pencil_click(s, ui.world_pill().world_button())
	await _pencil_click(s, ui.world_menu().item("left_handed"))
	await _frames(2)
	assert_true(ui.is_left_handed())
	assert_true(_rect(ui.mode_rail()).position.x > _rect(ui.library()).end.x, "rail right of the Library")
	assert_true(_rect(ui.popover()).end.x < _rect(ui.mode_rail()).position.x, "popover beside the rail")
	assert_true(_rect(ui.popover()).position.x > _rect(ui.library()).end.x)


func test_inspector_avoidance_is_bounded_and_cached() -> void:
	var s := await _start("stress_100")
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in 300:
		var r := s.document.get_object(s.document.sorted_object_ids()[0]).clone()
		r.object_id = ObjectRecord.new_uuid_v4()
		r.set_position(rng.randf_range(-400, 400), 0.0, rng.randf_range(-400, 400))
		s.document.put_object(r)
	s.presenter.rebuild(s.document)
	assert_true(s.presenter.authored_object_count() >= 400)
	var first := await _select_first(s)
	var centre := s.presenter.world_bounds(first.object_id).get_center()
	var crowd := 0
	for i in 100:
		var r := first.clone()
		r.object_id = ObjectRecord.new_uuid_v4()
		r.set_position(centre.x + rng.randf_range(-30, 30), 0.0, centre.z + rng.randf_range(-30, 30))
		s.document.put_object(r)
		crowd += 1
	s.presenter.rebuild(s.document)
	s.presenter.set_selected(first.object_id)
	var ui := _ui(s)
	var points := ui._other_object_points()
	assert_true(points.size() <= 64, "bounded candidates: %d" % points.size())
	var computes := ui.inspector_avoid_computes()
	var again := ui._other_object_points()
	assert_eq(ui.inspector_avoid_computes(), computes, "unchanged inputs reuse the cache")
	assert_eq(again, points)
	s.presenter.sync_object(s.document, first.object_id)
	ui._other_object_points()
	assert_eq(ui.inspector_avoid_computes(), computes + 1, "presentation change invalidates")
