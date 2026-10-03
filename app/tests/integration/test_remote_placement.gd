extends RemoteUiCase
## Remote Library tiles and placement (IP-04, E2E-04): unready tiles never drag, a finished download places nothing,
## a ready drop is exactly one record and one history action, and every abandoned drag leaves no object behind.


func test_remote_tile_starts_remote_and_cannot_be_dragged() -> void:
	var s := await _remote_session()
	var tile := _tile(s)
	assert_true(tile != null and tile.is_visible_in_tree())
	assert_eq(tile.readiness().state, RemotePrep.REMOTE)
	assert_eq(tile.meta_text(), "Remote")
	assert_eq(tile.action_button().text, "Download")
	assert_false(tile.is_prepared())
	await _drag(s, _center(tile), _centre_world(s))
	assert_false(s.tools.has_drop(), "no drop was ever opened")
	assert_false(s.presenter.has_ghost_visible())
	assert_eq(s.document.objects.size(), 0)
	assert_eq(s.history.size(), 0)
	assert_eq(s.tools.armed_asset(), "")
	assert_error_contains(s.tools.begin_drop(LibrarySelection.remote("b" + "0".repeat(32))), "Unknown asset binding")
	assert_error_contains(s.tools.arm_asset(LibrarySelection.remote("b" + "0".repeat(32))), "Unknown asset binding")


func test_staged_but_unprepared_binding_is_refused_by_arm_and_drop() -> void:
	var s := await _remote_session()
	provider.delay_frames = 50
	var tile := _tile(s)
	await _pencil_click(s, tile.action_button())
	await _frames(3)
	assert_eq(tile.readiness().state, RemotePrep.DOWNLOADING)
	var id := str(tile.readiness().binding_id)
	assert_true(s.document.assets.has_binding(id), "staged in the lock while it downloads")
	assert_error_contains(s.tools.begin_drop(LibrarySelection.remote(id)), "not downloaded yet")
	assert_error_contains(s.tools.arm_asset(LibrarySelection.remote(id)), "not downloaded yet")
	assert_eq(tile.action_button().text, "Cancel")
	await _pencil_click(s, tile.action_button())
	await _frames(60)
	assert_eq(tile.readiness().state, RemotePrep.REMOTE, "cancelled: back to remote, nothing registered")
	assert_false(s.render_state().registry().is_ready(id))


func test_download_completion_places_nothing_and_keeps_the_tool() -> void:
	var s := await _remote_session()
	s.tools.set_tool("paint")
	var id := await _download(s)
	assert_true(s.document.assets.is_prepared(id))
	assert_eq(s.document.objects.size(), 0)
	assert_eq(s.history.size(), 0)
	assert_eq(s.tools.active_tool(), "paint", "the active tool is untouched")
	assert_eq(s.tools.armed_asset(), "", "nothing armed")
	assert_false(s.tools.has_drop())
	assert_eq(_tile(s).meta_text(), "Ready")
	assert_false(s.document.assets.referenced_ids(s.document).has(id), "no record references the staged binding")


func test_ready_drag_places_exactly_one_record_and_one_history_action() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	var tile := _tile(s)
	var from := _center(tile)
	await _drag(s, from, _centre_world(s))
	assert_eq(s.document.objects.size(), 1)
	assert_eq(s.history.size(), 1, "one drop is one history action")
	var rec := s.document.get_object(s.tools.selected_id())
	assert_true(rec != null and rec.binding_id == id)
	assert_eq(s.document.assets.get_binding(id).asset_ref.version_id, V1, "the exact listed version")
	assert_eq(s.tools.active_tool(), "select")
	assert_eq(s.tools.armed_asset(), "")
	assert_false(s.presenter.has_ghost_visible())
	assert_eq(s.history.peek_undo_label(), "Place Crate", "the Library's name is used for the action")
	var encoded := s.document.assets.encode_referenced(s.document)
	assert_empty_string(str(encoded[1]), "the world serializes with the new binding")
	var decoded := WorldAssetLock.decode(encoded[0], s.catalog)
	assert_empty_string(str(decoded[1]), "and its lock reads back (dependency entry present)")
	assert_empty_string(s.undo())
	assert_eq(s.document.objects.size(), 0)
	assert_true(s.document.assets.is_prepared(id), "undo keeps the prepared tiers")
	assert_empty_string(s.redo())
	assert_eq(s.document.objects.size(), 1)


func test_tap_arms_a_ready_tile_and_a_world_tap_places_once() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	await _pencil_click(s, _tile(s))
	assert_eq(s.tools.armed_asset(), id)
	assert_eq(s.tools.armed_selection(), LibrarySelection.remote(id))
	await _frames(2)
	assert_eq(_ui(s).chip().label_text(), "Crate", "the chip names the remote asset")
	await _world_tap(s, _centre_world(s))
	assert_eq(s.document.objects.size(), 1)
	assert_eq(s.history.size(), 1)
	assert_eq(s.tools.armed_asset(), "", "placing disarms")
	await _pencil_click(s, _tile(s))
	await _pencil_click(s, _tile(s))
	assert_eq(s.tools.armed_asset(), "", "a second tap disarms")


func test_tapping_an_unready_tile_starts_the_download_without_arming() -> void:
	var s := await _remote_session()
	var tile := _tile(s)
	await _pencil_click(s, tile)
	for i in 300:
		if tile.readiness().state == RemotePrep.READY:
			break
		await tree.process_frame
	assert_eq(tile.readiness().state, RemotePrep.READY)
	assert_eq(s.tools.armed_asset(), "", "the tap downloaded; arming needs a second tap")
	assert_eq(s.document.objects.size(), 0)


func test_cancel_over_ui_and_unready_release_create_nothing() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	var tile := _center(_tile(s))
	var centre := _centre_world(s)
	await _drag(s, tile, centre, PointerSample.Phase.CANCEL)
	assert_eq(s.document.objects.size(), 0)
	assert_false(s.tools.has_drop() or s.presenter.has_ghost_visible())
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, tile)
	for i in range(1, 4):
		await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, tile.lerp(centre, float(i) / 3.0))
	assert_true(s.tools.has_drop() and s.presenter.has_ghost_visible())
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, tile)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, tile)
	assert_eq(s.document.objects.size(), 0, "released over the interface")
	assert_eq(s.history.size(), 0)
	assert_false(s.presenter.has_ghost_visible() or s.tools.has_drop())
	assert_true(s.document.assets.is_prepared(id), "the download itself stays")


func test_world_switch_during_a_drag_leaves_no_late_object() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	var sel := LibrarySelection.remote(id)
	assert_empty_string(s.tools.begin_drop(sel))
	s.tools.update_drop(_centre_world(s), false)
	assert_true(s.presenter.has_ghost_visible())
	assert_empty_string(s.open_fixture("gentle_hills"))
	assert_false(s.tools.has_drop())
	assert_false(s.presenter.has_ghost_visible())
	s.tools.finish_drop(_centre_world(s), false)
	assert_eq(s.document.objects.size(), 0, "the late release is a no-op")
	assert_eq(s.history.size(), 0)
	assert_false(s.document.assets.has_binding(id), "the new world's lock never saw the staged binding")


func test_backgrounding_during_a_drag_leaves_no_late_object() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	assert_empty_string(s.tools.begin_drop(LibrarySelection.remote(id)))
	s.tools.update_drop(_centre_world(s), false)
	s._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_false(s.tools.has_drop())
	assert_false(s.presenter.has_ghost_visible())
	s.tools.finish_drop(_centre_world(s), false)
	assert_eq(s.document.objects.size(), 0)
	assert_eq(s.history.size(), 0)
	assert_false(provider.is_prepared(id), "provider released on deactivation")


func test_provider_loss_alone_cancels_the_drop_at_release() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	assert_empty_string(s.tools.begin_drop(LibrarySelection.remote(id)))
	s.tools.update_drop(_centre_world(s), false)
	s.assets().release()  # the provider unprepares the binding; the tools were not told
	assert_false(s.document.assets.is_prepared(id))
	s.tools.finish_drop(_centre_world(s), false)
	assert_eq(s.document.objects.size(), 0)
	assert_eq(s.history.size(), 0)
	assert_false(s.tools.has_drop() or s.presenter.has_ghost_visible())
	assert_error_contains(s.last_message, "changed")


func test_begin_drop_rejects_an_active_operation() -> void:
	var s := await _remote_session()
	var id := await _download(s)
	assert_empty_string(s.tools.begin_drop(UiTestCase.BOULDER))
	assert_eq(s.tools.begin_drop(LibrarySelection.remote(id)), ToolController.BUSY)
	assert_eq(s.tools.arm_asset(LibrarySelection.remote(id)), ToolController.BUSY)
	s.tools.cancel_active("test")
	assert_empty_string(s.tools.begin_drop(LibrarySelection.remote(id)))
	s.tools.cancel_active("test")
	assert_eq(s.document.objects.size(), 0)


func test_bundled_selection_forms_and_failures_stay_unchanged() -> void:
	var s := await _remote_session()
	assert_empty_string(s.tools.arm_asset(BOULDER))
	assert_eq(s.tools.armed_asset(), BOULDER)
	assert_empty_string(s.tools.arm_asset(LibrarySelection.bundled(BOULDER)))
	assert_error_contains(s.tools.arm_asset(LibrarySelection.bundled("nature.rock.missing")), "missing")
	assert_error_contains(s.tools.begin_drop("nature.rock.missing"), "Unknown asset")
	assert_eq(LibrarySelection.normalize(7), {})
	assert_eq(LibrarySelection.normalize({"provider": "x"}), {})


func test_loader_disclosures_reach_the_tile() -> void:
	var s := await _remote_session()
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.8, 0.2, 0.2, 0.5))
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = ImageTexture.create_from_image(image)
	provider.default_glb = AssetTestKit.sphere_glb(16, 8, material)
	await _download(s)
	var tile := _tile(s)
	assert_true(tile.note_text().contains("blended"), tile.note_text())
	assert_true(tile.note_text().contains("cutout"))
	assert_true(tile.tooltip_text.contains("cutout"))


func test_failed_and_over_budget_downloads_show_the_reason_and_retry() -> void:
	var s := await _remote_session()
	var tile := _tile(s)
	provider.default_glb = PackedByteArray([1, 2, 3])  # not a GLB: the validator refuses it
	await _pencil_click(s, tile.action_button())
	for i in 300:
		if tile.readiness().state != RemotePrep.DOWNLOADING:
			break
		await tree.process_frame
	assert_eq(tile.readiness().state, RemotePrep.FAILED)
	assert_true(tile.meta_text().begins_with("Failed: "), tile.meta_text())
	assert_eq(tile.action_button().text, "Retry")
	await _drag(s, _center(tile), _centre_world(s))
	assert_false(s.tools.has_drop(), "a failed tile is not draggable")
	provider.default_glb = AssetTestKit.glb(AssetTestKit.GLB_V1)
	await _pencil_click(s, tile.action_button())
	for i in 300:
		if tile.readiness().state == RemotePrep.READY:
			break
		await tree.process_frame
	assert_eq(tile.readiness().state, RemotePrep.READY, "retry succeeds")
	assert_true(RemotePrep.BUDGET_WORDS.any(func(w: String) -> bool: return "70 nodes exceed the limit of 64".contains(w)),
			"validator limit messages classify as over budget")
