extends UiTestCase
## Library v2 (tabs, ticks, quick mix, set cards) and the scatter-set editor (docs/editor-v2.md §6, §9).

const LODGE := "built.lodge.cabin_a"
const SPRUCE := "nature.tree.spruce_a"
const FERN := "nature.cover.fern_a"


func _store(s: EditorSession) -> ScatterSetStore:
	return s.tools.set_store()


func _open_editor_for(s: EditorSession, set_id: String) -> SetEditor:
	var ui := _ui(s)
	ui.library().show_tab("sets")
	await _frames(2)
	await _pencil_click(s, ui.library().set_card(set_id).edit_button())
	return ui.set_editor()


func _new_set_editor(s: EditorSession) -> SetEditor:
	var ui := _ui(s)
	ui.library().show_tab("sets")
	await _frames(2)
	await _pencil_click(s, ui.library().new_set_button())
	return ui.set_editor()


# --- Library ---------------------------------------------------------------------------------

func test_not_ready_assets_are_disabled_captioned_and_cannot_be_armed() -> void:
	var s := await _start()
	var stub := StubRenderRegistry.hiding(s.catalog, [SPRUCE])
	s._render._registry = stub
	s._tool_ctx.render_ready = stub.is_ready
	var tile := LibraryTile.new()
	tile.setup(s, s.catalog.get_asset(SPRUCE))
	assert_false(tile.is_prepared())
	assert_eq(tile.meta_text(), "Not ready")
	assert_true(tile.modulate.a < 1.0, "dimmed like a disabled tile")
	tile.free()
	assert_true(_ui(s).library().tile(BOULDER).is_prepared(), "a prepared asset keeps its caption")
	var error := s.tools.arm_asset(SPRUCE)
	assert_eq(error, "%s is not ready: render derivatives missing." % s.catalog.get_asset(SPRUCE).display_name)
	assert_eq(s.tools.armed_asset(), "")
	assert_error_contains(s.tools.begin_drop(SPRUCE), "not ready")
	assert_false(s.tools.has_drop())
	assert_empty_string(s.tools.arm_asset(BOULDER))


func test_tabs_switch_between_objects_and_sets() -> void:
	var s := await _start()
	var lib := _ui(s).library()
	assert_eq(lib.tab(), "objects")
	assert_true(lib.tab_button("objects").button_pressed and lib.tile(BOULDER).is_visible_in_tree())
	await _pencil_click(s, lib.tab_button("sets"))
	assert_eq(lib.tab(), "sets")
	assert_true(lib.tab_button("sets").button_pressed and not lib.tab_button("objects").button_pressed)
	assert_false(lib.tile(BOULDER).is_visible_in_tree())
	assert_true(lib.set_card("forest").is_visible_in_tree())
	await _pencil_click(s, lib.tab_button("objects"))
	assert_true(lib.tile(BOULDER).is_visible_in_tree())
	assert_eq(lib.size.x, 240.0)


func test_ticks_exist_only_for_scatter_assets_and_drive_the_quick_mix() -> void:
	var s := await _start()
	var ui := _ui(s)
	var lib := ui.library()
	assert_true(lib.tile(LODGE).tick_button() == null, "a non-scatter asset has no tick")
	assert_false(lib.quick_mix_button().is_visible_in_tree())
	assert_eq(lib.tile(BOULDER).tick_button().size, Vector2(30, 30))
	await _pencil_click(s, lib.tile(SPRUCE).tick_button())
	assert_eq(lib.ticked(), PackedStringArray([SPRUCE]))
	assert_eq(s.tools.armed_asset(), "", "a tick does not arm")
	await _pencil_click(s, lib.tile(FERN).tick_button())
	assert_true(lib.quick_mix_button().is_visible_in_tree())
	assert_eq(lib.quick_mix_button().text, "Scatter 2 as quick mix")
	await _pencil_click(s, lib.quick_mix_button())
	assert_eq(s.tools.quick_mix(), PackedStringArray([SPRUCE, FERN]))
	assert_eq(s.tools.settings("scatter").source, "mix")
	assert_eq(s.tools.active_tool(), "scatter")
	assert_true(ui.popover().is_open(), "the popover opens")
	assert_eq(ui.chip().sub_text(), "Quick mix · 7.0 m · 70%")
	await _pencil_click(s, lib.clear_button())
	assert_eq(lib.ticked().size(), 0)
	assert_false(lib.tile(SPRUCE).is_ticked())
	assert_false(lib.quick_mix_button().is_visible_in_tree())


func test_tap_arms_and_second_tap_disarms() -> void:
	var s := await _start()
	var lib := _ui(s).library()
	await _pencil_click(s, lib.tile(BOULDER))
	assert_eq(s.tools.armed_asset(), BOULDER)
	await _pencil_click(s, lib.tile(BOULDER))
	assert_eq(s.tools.armed_asset(), "", "tapping the armed tile disarms")
	assert_eq(s.history.size(), 0)


func test_finger_tap_arms_and_finger_drag_never_places() -> void:
	var s := await _start()
	var lib := _ui(s).library()
	var tile := _center(lib.tile(BOULDER))
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.BEGIN, tile)
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.END, tile)
	assert_eq(s.tools.armed_asset(), BOULDER, "a finger tap arms the asset")
	s.tools.disarm()
	var objects_before := s.document.objects.size()
	var to := _centre_world(s)
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.BEGIN, tile)
	for i in range(1, 4):
		await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.MOVE, tile.lerp(to, float(i) / 3.0))
		assert_false(s.tools.has_drop(), "a finger drag never opens a drop")
	await _feed(s, PointerSample.Source.FINGER, PointerSample.Phase.END, to)
	assert_eq(s.document.objects.size(), objects_before, "nothing placed")
	assert_eq(s.history.size(), 0)
	assert_eq(s.tools.armed_asset(), "", "a dead press does not arm on release")
	assert_false(s.presenter.has_ghost_visible())


func test_set_cards_show_data_and_pick_the_source() -> void:
	var s := await _start()
	var ui := _ui(s)
	var lib := ui.library()
	lib.show_tab("sets")
	await _frames(2)
	assert_eq(lib.set_card_ids().size(), 3)
	var forest := lib.set_card("forest")
	assert_eq(forest.name_text(), "Spruce forest")
	assert_eq(forest.meta_text(), "density 0.6 · spacing 1.4 m · slope 0–35°")
	assert_eq(forest.thumb_count(), 3)
	assert_true(forest.edit_button().size.y >= 44.0, "Edit hit height")
	s.tools.set_tool("raise")
	await _pencil_click(s, lib.set_card("meadow"))
	assert_eq(s.tools.settings("scatter").source, "set:meadow")
	assert_eq(s.tools.active_tool(), "scatter")
	assert_eq(s.history.size(), 0)
	s.tools.set_tool("fill")
	s.tools.set_inverted(true)
	await _pencil_click(s, lib.set_card("scree"))
	assert_eq(s.tools.settings("scatter").source, "set:scree")
	assert_eq(s.tools.active_tool(), "fill", "fill is kept")
	assert_false(s.tools.inverted())


func test_change_opens_the_library_on_the_matching_tab() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_tool("scatter")
	ui.popover().set_open(true)
	ui.library().set_open(false)
	await _frames(2)
	var card := ui.popover().section("source") as SourceCard
	await _pencil_click(s, card.change_button())
	assert_true(ui.library().is_open())
	assert_eq(ui.library().tab(), "sets")
	s.tools.set_setting("scatter", "source", "mix")
	ui.library().set_open(false)
	await _frames(2)
	await _pencil_click(s, card.change_button())
	assert_eq(ui.library().tab(), "objects")


# --- Set editor ------------------------------------------------------------------------------

func test_editor_opens_for_existing_and_new_sets() -> void:
	var s := await _start()
	var ed := await _open_editor_for(s, "forest")
	assert_true(ed.is_open())
	assert_eq(ed.name_edit().text, "Spruce forest")
	assert_true(ed.delete_button().visible)
	assert_eq(ed.weight_scrub(0).value, 6.0)
	assert_eq(ed.param("density").value, 0.6)
	assert_true(ed.add_chip(SPRUCE).disabled, "assets already in the set cannot be added")
	assert_false(ed.add_chip("nature.rock.pebbles_a").disabled)
	await _pencil_click(s, ed.cancel_button())
	assert_false(ed.is_open())
	assert_eq(_store(s).get_set("forest").density, 0.6, "Cancel changes nothing")
	var fresh := await _new_set_editor(s)
	assert_true(fresh.is_open())
	assert_false(fresh.delete_button().visible, "a set not yet in the store cannot be deleted")
	assert_eq(fresh.name_edit().text, "New set")
	assert_eq(fresh.draft().items.size(), 1)
	assert_eq(fresh.draft().items[0].asset_id, "nature.cover.grass_tuft_a")
	assert_eq(fresh.draft().items[0].weight, 5.0)
	assert_eq(fresh.draft().density, 1.0)
	assert_eq(fresh.draft().spacing, 0.6)
	assert_eq(fresh.draft().slope_max, 40.0)
	assert_true(fresh.draft().align)
	assert_true(_store(s).get_set(str(fresh.draft().id)).is_empty())
	fresh.close()


func test_editor_edits_are_local_until_save_then_select_the_set() -> void:
	var s := await _start()
	var ui := _ui(s)
	var ed := await _open_editor_for(s, "meadow")
	ed.name_edit().text = "Meadow 2"
	ed.name_edit().text_changed.emit("Meadow 2")
	ed.param("density").value = 2.0
	await _pencil_click(s, ed.add_chip("nature.rock.boulder_a"))
	assert_eq(ed.draft().items.size(), 4)
	assert_true(ed.add_chip("nature.rock.boulder_a").disabled)
	await _pencil_click(s, ed.remove_button(0))
	assert_eq(ed.draft().items.size(), 3)
	assert_eq(_store(s).get_set("meadow").density, 3.0, "the store is untouched before Save")
	assert_eq(s.history.size(), 0, "the editor never writes world history")
	s.tools.set_tool("fill")
	await _pencil_click(s, ed.save_button())
	assert_false(ed.is_open())
	var saved := _store(s).get_set("meadow")
	assert_eq(saved.name, "Meadow 2")
	assert_eq(saved.density, 2.0)
	assert_eq(saved.items.size(), 3)
	assert_eq(s.tools.settings("scatter").source, "set:meadow")
	assert_eq(s.tools.active_tool(), "fill", "fill stays the tool")
	assert_eq(ui.library().tab(), "sets")
	assert_eq(ui.toast().label().text, "Saved set Meadow 2")
	assert_eq(ui.library().set_card("meadow").name_text(), "Meadow 2")


func test_new_set_save_and_delete() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_tool("raise")
	var ed := await _new_set_editor(s)
	var id := str(ed.draft().id)
	await _pencil_click(s, ed.save_button())
	assert_false(_store(s).get_set(id).is_empty())
	assert_eq(s.tools.settings("scatter").source, "set:" + id)
	assert_eq(s.tools.active_tool(), "scatter")
	assert_eq(s.tools.mode(), "place")
	assert_true(ui.library().set_card_ids().has(id))
	ed = await _open_editor_for(s, id)
	assert_true(ed.delete_button().visible)
	await _pencil_click(s, ed.delete_button())
	assert_false(ed.is_open())
	assert_true(_store(s).get_set(id).is_empty())
	assert_eq(s.tools.settings("scatter").source, "set:forest", "the first remaining set becomes the source")
	assert_false(ui.library().set_card_ids().has(id))


func test_save_needs_an_asset_and_delete_of_a_default_keeps_the_rest() -> void:
	var s := await _start()
	var ui := _ui(s)
	var ed := await _open_editor_for(s, "scree")
	await _pencil_click(s, ed.remove_button(1))
	await _pencil_click(s, ed.remove_button(0))
	await _pencil_click(s, ed.save_button())
	assert_true(ed.is_open(), "stays open on an empty set")
	assert_eq(ui.toast().label().text, "Add at least one asset")
	assert_eq(ui.toast().label().get_theme_color("font_color"), UiKit.DANGER_TEXT)
	assert_eq(_store(s).get_set("scree").items.size(), 2)
	s.tools.set_setting("scatter", "source", "set:scree")
	await _pencil_click(s, ed.cancel_button())
	ed = await _open_editor_for(s, "scree")
	await _pencil_click(s, ed.delete_button())
	assert_eq(s.tools.settings("scatter").source, "set:forest")
	assert_eq(_store(s).sets().size(), 2)


func test_slope_scrubs_keep_min_below_max() -> void:
	var s := await _start()
	var ed := await _open_editor_for(s, "forest")
	ed.param("slope_min").value = 80.0
	assert_true(ed.param("slope_max").value >= 80.0, "pushes the maximum up")
	ed.param("slope_max").value = 10.0
	assert_true(ed.param("slope_min").value <= 10.0, "pushes the minimum down")
	assert_true(float(ed.draft().slope_min) <= float(ed.draft().slope_max))
	ed.close()


func test_preview_is_seeded_counted_and_rerolls() -> void:
	var s := await _start()
	var ed := await _open_editor_for(s, "forest")
	await _frames(2)
	var first := ed.preview().instances()
	assert_true(first.size() > 0)
	assert_eq(ed.count_text(), "%d instances in preview" % first.size())
	var again := ScatterPreview.generate(ed.draft(), s.catalog, ed.seed_value())
	assert_eq(str(again), str(first), "same set and seed, same layout")
	await _pencil_click(s, ed.reroll_button())
	assert_eq(ed.seed_value(), 2)
	assert_ne(str(ed.preview().instances()), str(first), "Re-roll changes the layout")
	for inst in ed.preview().instances():
		assert_true(float(inst.x) >= 0.0 and float(inst.x) < 50.0 and float(inst.z) >= 0.0 and float(inst.z) < 35.0)
	var count := ed.preview().instance_count()
	ed.param("density").value = 0.2
	assert_true(ed.preview().instance_count() < count, "an edit regenerates the preview")
	ed.close()


func test_save_as_set_from_the_quick_mix_and_escape() -> void:
	var s := await _start()
	var ui := _ui(s)
	s.tools.set_quick_mix(PackedStringArray([SPRUCE, FERN]))
	s.tools.set_setting("scatter", "source", "mix")
	await _tool(s, "scatter")
	var card := ui.popover().section("source") as SourceCard
	assert_eq(card.edit_button().text, "Save as set")
	await _pencil_click(s, card.edit_button())
	var ed := ui.set_editor()
	assert_true(ed.is_open())
	assert_false(ed.delete_button().visible)
	assert_eq(ed.draft().items.size(), 2)
	assert_eq(ed.draft().items[0].asset_id, SPRUCE)
	s.tools.dismiss()
	assert_false(ed.is_open(), "Esc closes the editor")
	s.tools.set_setting("scatter", "source", "set:forest")
	ui.popover().set_open(true)
	await _frames(2)
	await _pencil_click(s, (ui.popover().section("source") as SourceCard).edit_button())
	assert_true(ed.is_open())
	assert_eq(ed.name_edit().text, "Spruce forest", "Edit set opens the current set")
	ed.close()


func test_editor_registration_and_layout() -> void:
	var s := await _start()
	var ui := _ui(s)
	var ed := ui.set_editor()
	assert_false(s.input.ui_hits.is_over_ui(_centre_world(s)))
	for size in SIZES:
		ui.layout_override = size
		for left in [false, true]:
			ui.set_left_handed(left)
			ed = await _open_editor_for(s, "forest")
			await _frames(3)
			assert_true(s.input.ui_hits.is_over_ui(_centre_world(s)), "the open editor blocks the world")
			var viewport := Rect2(Vector2.ZERO, size)
			assert_eq(ed.get_global_rect(), viewport)
			var parts: Array[Control] = [ed.cancel_button(), ed.name_edit(), ed.delete_button(), ed.save_button(),
					ed.reroll_button(), ed.preview(), ed.weight_scrub(0), ed.param("density"), ed.align_switch()]
			for i in parts.size():
				var r := parts[i].get_global_rect()
				assert_true(viewport.grow(0.5).encloses(r), "%s: %s %s outside" % [size, parts[i], r])
				for j in range(i + 1, parts.size()):
					assert_false(r.intersects(parts[j].get_global_rect()), "%s: %s overlaps %s" % [size, parts[i], parts[j]])
			assert_eq(ed.preview().size, Vector2(420, 294))
			ed.close()
	ui.layout_override = Vector2.ZERO
