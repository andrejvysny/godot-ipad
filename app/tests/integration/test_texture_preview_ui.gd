extends UiTestCase
## Texture Preview controls of the performance menu and indicator (spec §11.1, docs/editor-v2.md §9.1).


func _wait_state(s: EditorSession, state: String) -> void:
	for i in 600:
		if str(s.texture_preview_status().state) == state:
			return
		await tree.process_frame
	fail("preview never reached %s: %s" % [state, s.texture_preview_status()])


func test_menu_switch_status_line_and_indicator_follow_the_preview() -> void:
	var s := await _start()
	var ui := _ui(s)
	var menu := ui.perf_menu()
	var indicator := ui.perf_indicator()
	assert_eq(menu.preview_text(), "Off")
	assert_false(menu.preview_switch().button_pressed)
	assert_false(indicator.text().contains("Preview"))
	menu.preview_switch().button_pressed = true  # the user flips the switch
	assert_eq(menu.preview_text(), "Loading…")
	assert_true(menu.preview_switch().button_pressed)
	await _wait_state(s, TexturePreviewController.ACTIVE)
	ui.refresh()
	assert_true(menu.preview_text().begins_with("Active · area "), menu.preview_text())
	assert_true(menu.preview_text().ends_with(" · r 20 m"), menu.preview_text())
	assert_true(indicator.text().ends_with(" · Preview"), indicator.text())
	var st := s.texture_preview_status()
	menu.preview_switch().button_pressed = false
	assert_eq(menu.preview_text(), "Releasing…")
	assert_false(menu.preview_switch().button_pressed)
	await _wait_state(s, TexturePreviewController.OFF)
	ui.refresh()
	assert_eq(menu.preview_text(), "Off")
	assert_false(indicator.text().contains("Preview"), indicator.text())
	assert_true(int(s.texture_preview_status().generation) > int(st.generation))


func test_toggle_without_an_area_leaves_the_switch_off_and_says_why() -> void:
	var s := await _start()
	var posted: Array[String] = []
	s.message_posted.connect(func(text: String, _e: bool) -> void: posted.append(text))
	s.rig.focus_point(Vector3(9000.0, 0.0, 9000.0))
	var menu := _ui(s).perf_menu()
	menu.preview_switch().button_pressed = true
	assert_false(menu.preview_switch().button_pressed, "refused: the switch snaps back")
	assert_eq(menu.preview_text(), "Off")
	assert_true(posted.has("Select an object or aim at terrain to preview textures."))
