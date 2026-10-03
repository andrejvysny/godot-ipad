extends RemoteUiCase
## Update offers and the Review Update flow (IP-04, shared spec §7, E2E-06): badge from the change feed, exact
## target version, differences, range violations that need an explicit choice, one history action, other objects of
## the old version untouched, undo without a fetch, declines that never become a modal.

var _a: String
var _b: String
var _c: String
var _old: String


## A world with three placed v1 crates (the middle one scaled 2x) and the server's current pointer moved to `target`.
func _world_with_v1_objects(target: String = V2) -> EditorSession:
	var s := await _remote_session()
	_old = await _download(s)
	var sel := LibrarySelection.remote(_old)
	var centre := _centre_world(s)
	_a = _place(s, sel, centre + Vector2(-90, 0))
	_b = _place(s, sel, centre)
	assert_empty_string(s.tools.nudge("scale", 1.0), "scale 2x is inside v1's 0.5..2")
	_c = _place(s, sel, centre + Vector2(90, 0))
	assert_eq(s.history.size(), 4)
	client.current[ASSET] = target
	await s.assets().remote.updates.check()
	return s


func test_offer_appears_from_the_change_feed_as_a_badge_never_a_modal() -> void:
	var s := await _remote_session()
	_old = await _download(s)
	_place(s, LibrarySelection.remote(_old), _centre_world(s))
	var remote := s.assets().remote
	await remote.updates.check()
	assert_false(remote.updates.has_offer(_old), "the server still lists v1 as current")
	client.current[ASSET] = V2
	client.items[LIB][0].current_version_id = V2
	remote.on_events([{"type": "asset_current_changed", "library_id": LIB, "asset_id": ASSET}])
	await _frames(5)
	assert_true(remote.updates.has_offer(_old))
	assert_eq(remote.updates.offer_for(_old).target_version, V2)
	var tile := _tile(s, V2)
	assert_true(tile != null and tile.update_button().visible, "the new version's tile carries the update badge")
	assert_false(_ui(s).update_dialog().is_open(), "nothing opens by itself")
	assert_eq(s.history.size(), 1, "metadata checks change nothing in the world")
	await _frames(2)
	assert_true(_ui(s).inspector().update_button().visible, "the selected object offers the update")


func test_review_updates_selected_object_only_and_undo_needs_no_fetch() -> void:
	var s := await _world_with_v1_objects()
	s.tools.select(_a)
	var dlg := _ui(s).update_dialog()
	await dlg.open_for(_old)
	assert_true(dlg.is_open())
	for i in 300:
		if dlg.can_apply():
			break
		await tree.process_frame
	assert_true(dlg.can_apply())
	assert_eq(dlg.review().object_ids, [_a], "scope: the selected object")
	var text := dlg.body_text()
	assert_true(text.contains("placement_anchor"), "anchor change listed: " + text)
	assert_true(text.contains("slot added: lid"), "material slot change listed")
	assert_true(dlg.review().conflicts.is_empty())
	var new_id := dlg.target_binding_id()
	assert_ne(new_id, _old)
	assert_false(s.document.assets.get_binding(new_id).asset_ref.version_id == V1)
	var before_rec := s.document.get_object(_a).clone()
	var history_before := s.history.size()
	await _pencil_click(s, dlg.apply_button())
	assert_false(dlg.is_open())
	assert_eq(s.history.size(), history_before + 1, "one history action")
	assert_eq(s.document.get_object(_a).binding_id, new_id)
	assert_eq(s.document.get_object(_b).binding_id, _old, "other v1 objects are untouched")
	assert_eq(s.document.get_object(_c).binding_id, _old)
	var moved := s.document.get_object(_a)
	assert_eq(moved.position, before_rec.position, "placed anchor position is kept")
	assert_eq(moved.rotation_xyzw, before_rec.rotation_xyzw)
	assert_eq(moved.uniform_scale, before_rec.uniform_scale)
	assert_true(s.document.assets.has_binding(new_id) and s.document.assets.has_binding(_old), "the lock gained v2")
	var fetches := provider.fetches
	var calls := client.calls.size()
	assert_empty_string(s.undo())
	assert_eq(s.document.get_object(_a).binding_id, _old, "undo restores the old binding")
	assert_eq(provider.fetches, fetches, "no re-download")
	assert_eq(client.calls.size(), calls, "no server request")
	assert_true(provider.is_prepared(_old) and s.document.assets.is_prepared(_old))
	assert_empty_string(s.redo())
	assert_eq(s.document.get_object(_a).binding_id, new_id)


func test_scope_all_updates_every_object_of_the_binding() -> void:
	var s := await _world_with_v1_objects()
	var dlg := _ui(s).update_dialog()
	s.tools.select("")
	await dlg.open_for(_old)
	for i in 300:
		if dlg.can_apply():
			break
		await tree.process_frame
	assert_eq(dlg.review().object_ids.size(), 3, "nothing selected: all objects of the version")
	dlg.apply()
	var ids: Array = [_a, _b, _c].map(func(id: String) -> String: return s.document.get_object(id).binding_id)
	assert_eq(ids[0], ids[1])
	assert_eq(ids[1], ids[2])
	assert_ne(ids[0], _old)
	assert_eq(s.history.size(), 5, "one action for all three")
	await s.assets().remote.updates.check()
	assert_false(s.assets().remote.updates.has_offer(_old), "no object uses v1 any more")


func test_out_of_range_scale_blocks_automatic_preservation_until_the_user_chooses() -> void:
	var s := await _world_with_v1_objects(V3)
	var dlg := _ui(s).update_dialog()
	s.tools.select("")
	await dlg.open_for(_old, UpdateReviewDialog.SCOPE_ALL)
	for i in 300:
		if dlg.review() != null and s.document.assets.is_prepared(dlg.target_binding_id()):
			break
		await tree.process_frame
	var review := dlg.review()
	assert_eq(review.conflicts.size(), 1)
	assert_eq(review.conflicts[0].object_id, _b)
	assert_eq(review.conflicts[0].field, "uniform_scale")
	assert_eq(review.conflicts[0].proposed, 1.5)
	assert_true(review.needs_choice())
	assert_false(dlg.can_apply(), "Update stays disabled")
	assert_true(dlg.choice_button("exclude").is_visible_in_tree())
	await _frames(2)
	assert_eq(review.plan().ids, [], "no plan without a choice")
	var history_before := s.history.size()
	dlg.apply()
	assert_eq(s.history.size(), history_before, "nothing applied")
	var err := s.tools.rebind_objects([_b], dlg.target_binding_id())
	assert_error_contains(err, "outside the new version's limits")
	assert_eq(s.document.get_object(_b).uniform_scale, 2.0, "never clamped")
	assert_eq(s.document.get_object(_b).binding_id, _old)
	assert_eq(s.history.size(), history_before)
	await _pencil_click(s, dlg.choice_button("exclude"))
	assert_true(dlg.can_apply())
	await _pencil_click(s, dlg.apply_button())
	assert_eq(s.document.get_object(_a).binding_id, dlg.target_binding_id())
	assert_eq(s.document.get_object(_c).binding_id, dlg.target_binding_id())
	assert_eq(s.document.get_object(_b).binding_id, _old, "the out-of-range object stays on v1")
	assert_eq(s.document.get_object(_b).uniform_scale, 2.0)


func test_explicit_limit_choice_sets_the_shown_value_in_the_same_action() -> void:
	var s := await _world_with_v1_objects(V3)
	var dlg := _ui(s).update_dialog()
	s.tools.select("")
	await dlg.open_for(_old, UpdateReviewDialog.SCOPE_ALL)
	for i in 300:
		if dlg.review() != null and s.document.assets.is_prepared(dlg.target_binding_id()):
			break
		await tree.process_frame
	await _frames(3)
	await _pencil_click(s, dlg.choice_button("limit"))
	assert_eq(dlg.review().choice, "limit")
	var history_before := s.history.size()
	dlg.apply()
	assert_eq(s.history.size(), history_before + 1)
	assert_eq(s.document.get_object(_b).binding_id, dlg.target_binding_id())
	assert_eq(s.document.get_object(_b).uniform_scale, 1.5, "the nearest limit the dialog showed")
	assert_eq(s.document.get_object(_a).uniform_scale, 1.0)
	assert_empty_string(s.undo())
	assert_eq(s.document.get_object(_b).uniform_scale, 2.0, "undo restores the scale too")
	assert_eq(s.document.get_object(_b).binding_id, _old)


func test_update_is_blocked_during_an_active_operation() -> void:
	var s := await _world_with_v1_objects()
	var dlg := _ui(s).update_dialog()
	assert_empty_string(s.tools.begin_drop(BOULDER))
	assert_eq(await dlg.open_for(_old), ToolController.BUSY)
	assert_false(dlg.is_open())
	assert_eq(s.tools.rebind_objects([_a], _old), ToolController.BUSY)
	s.tools.cancel_active("test")
	await dlg.open_for(_old)
	for i in 300:
		if dlg.can_apply():
			break
		await tree.process_frame
	assert_true(dlg.can_apply())
	assert_empty_string(s.tools.begin_drop(BOULDER))
	assert_false(dlg.can_apply(), "Apply is blocked once an operation starts")
	dlg.apply()
	assert_eq(s.document.get_object(_a).binding_id, _old)
	s.tools.cancel_active("test")


func test_declining_hides_the_badge_and_only_a_new_version_offers_again() -> void:
	var s := await _world_with_v1_objects()
	var remote := s.assets().remote
	var dlg := _ui(s).update_dialog()
	await dlg.open_for(_old)
	await _frames(3)
	await _pencil_click(s, dlg.decline_button())
	assert_false(dlg.is_open())
	assert_false(remote.updates.has_offer(_old))
	await remote.updates.check()
	assert_false(remote.updates.has_offer(_old), "the same version is not offered again")
	assert_eq(s.history.size(), 4, "declining changes nothing")
	client.current[ASSET] = V3
	remote.on_events([{"type": "asset_current_changed", "library_id": LIB, "asset_id": ASSET}])
	await _frames(4)
	assert_true(remote.updates.has_offer(_old), "a different version offers again, as a badge")
	assert_eq(remote.updates.offer_for(_old).target_version, V3)
	assert_false(dlg.is_open(), "never a blocking modal")


func test_review_with_no_server_data_reports_instead_of_opening() -> void:
	var s := await _remote_session()
	var dlg := _ui(s).update_dialog()
	assert_error_contains(await dlg.open_for("b" + "0".repeat(32)), "No update is offered")
	assert_false(dlg.is_open())
