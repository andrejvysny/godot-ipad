extends TestCase
## EditorSession lifecycle: boot/recovery, commit/undo/redo, save honesty (IO-04..IO-06),
## fixture replacement (IO-07), export, deactivation rollback, history eviction, status.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")

var sessions: Array = []
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	# The pinned Terrain3D binary emits one known deprecation warning when it enters the tree.
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	for s: Variant in sessions:
		if is_instance_valid(s):
			_dispose(s)
	sessions.clear()
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


func _dispose(s: EditorSession) -> void:
	if s.get_parent() != null:
		tree.root.remove_child(s)
	s.free()


func _start(fixture: String = "flat", root: String = "") -> EditorSession:
	var s := EditorSession.new()
	s.storage_root = root if root != "" else scratch_dir() + "/worlds"
	s.start_fixture = fixture
	s.provider_override = InputTests.FakeProvider.new()
	s.build_ui = false
	sessions.append(s)
	tree.root.add_child(s)
	await tree.process_frame
	await _settle(s)
	return s


func _settle(s: EditorSession) -> void:
	for i in 300:
		if not s.storage.is_busy():
			return
		await tree.process_frame
	fail("storage did not become idle")


func _sample(s: EditorSession, x: float, z: float, t: float) -> PointerSample:
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.PENCIL
	sample.timestamp_s = t
	sample.position_viewport = s.rig.get_camera().unproject_position(Vector3(x, s.document.sample_height(x, z), z))
	return sample


func _act(s: EditorSession, type: String, x: float, z: float, t: float) -> void:
	s._on_tool_action({"type": type, "sample": _sample(s, x, z, t), "over_ui": false})


func _stroke(s: EditorSession, x0: float, x1: float, z: float = 0.0) -> void:
	var t := 1.0
	_act(s, "tool_begin", x0, z, t)
	var x := x0
	while x < x1:
		x = minf(x + 2.0, x1)
		t += 0.02
		_act(s, "tool_move", x, z, t)
	_act(s, "tool_end", x1, z, t + 0.02)


func _tiny_change(label: String) -> WorldChange:
	var change := WorldChange.new()
	change.label = label
	return change


func _generation_region_file(root: String, world_id: String) -> String:
	var gens := GenerationStore.generations_dir(root, world_id)
	var newest := GenerationStore.complete_generations(gens)[0]
	var regions := gens.path_join(GenerationStore.generation_name(newest)).path_join("regions")
	for file in DirAccess.get_files_at(regions):
		return regions.path_join(file)
	return ""


func test_fresh_start_opens_new_working_copy() -> void:
	var s: EditorSession = await _start()
	assert_eq(s.boot_error, "")
	assert_true(s.ready_for_input)
	assert_true(ObjectRecord.is_uuid(s.document.world_id))
	var fixture := WorldCodec.read_generation("res://fixtures/flat", s.catalog)[0] as WorldDocument
	assert_ne(s.document.world_id, fixture.world_id)
	assert_eq(s.document.document_revision, 0)
	assert_eq(s.storage.status_text(0), "Saved revision 0")
	assert_true(s.last_message.begins_with("Opened Flat"), s.last_message)


func test_restart_recovers_and_falls_back_past_corrupt_generation() -> void:
	var root := scratch_dir() + "/worlds"
	var first: EditorSession = await _start("flat", root)
	var original_hash := first.authored_hash()
	first.tools.set_tool(ToolController.TOOL_PAINT)
	_stroke(first, -6.0, 6.0)
	await _settle(first)
	var stroked_hash := first.authored_hash()
	assert_ne(stroked_hash, original_hash)
	var world_id := first.document.world_id
	_dispose(first)
	var second: EditorSession = await _start("flat", root)
	assert_eq(second.document.world_id, world_id)
	assert_eq(second.authored_hash(), stroked_hash)
	assert_true(second.last_message.begins_with("Recovered revision 1"), second.last_message)
	_dispose(second)
	var victim := _generation_region_file(root, world_id)
	var file := FileAccess.open(victim, FileAccess.WRITE)
	file.store_string("corrupt")
	file.close()
	var third: EditorSession = await _start("flat", root)
	assert_eq(third.document.world_id, world_id)
	assert_eq(third.document.document_revision, 0)
	assert_eq(third.authored_hash(), original_hash)
	assert_true(third.last_message.contains("skipped 1 invalid checkpoint"), third.last_message)


func test_stroke_commit_undo_redo() -> void:
	var s: EditorSession = await _start()
	var before := s.authored_hash()
	s.tools.set_tool(ToolController.TOOL_PAINT)
	_stroke(s, -6.0, 6.0)
	assert_eq(s.document.document_revision, 1)
	assert_eq(s.history.size(), 1)
	var stroked := s.authored_hash()
	await _settle(s)
	assert_eq(s.storage.status_text(1), "Saved revision 1")
	assert_eq(s.undo(), "")
	assert_eq(s.document.document_revision, 2)
	assert_eq(s.authored_hash(), before)
	assert_true(s.terrain.has_pending_uploads(), "undo marks terrain dirty")
	assert_eq(s.redo(), "")
	assert_eq(s.document.document_revision, 3)
	assert_eq(s.authored_hash(), stroked)
	assert_eq(s.undo(), "")
	assert_eq(s.redo(), "")
	assert_eq(s.redo(), "Nothing to redo")


func test_undo_refused_during_active_stroke() -> void:
	var s: EditorSession = await _start()
	s.tools.set_tool(ToolController.TOOL_PAINT)
	_act(s, "tool_begin", 0.0, 0.0, 1.0)
	assert_true(s.tools.has_active_operation())
	assert_eq(s.undo(), EditorSession.BUSY_MESSAGE)
	assert_eq(s.redo(), EditorSession.BUSY_MESSAGE)
	assert_eq(s.save_now(), EditorSession.BUSY_MESSAGE)
	assert_eq(s.export_world().error, EditorSession.BUSY_MESSAGE)
	s.cancel_active()
	assert_false(s.tools.has_active_operation())


func test_placement_undo_removes_object_and_selection() -> void:
	var s: EditorSession = await _start()
	var baseline := s.presenter.authored_object_count()
	assert_empty_string(s.tools.arm_asset(ToolHarness.BOULDER))
	_act(s, "tool_begin", 0.0, 0.0, 1.0)
	_act(s, "tool_end", 0.0, 0.0, 1.05)
	assert_eq(s.presenter.authored_object_count(), baseline + 1)
	assert_ne(s.tools.selected_id(), "")
	assert_eq(s.undo(), "")
	assert_eq(s.presenter.authored_object_count(), baseline)
	assert_eq(s.tools.selected_id(), "")
	assert_eq(s.redo(), "")
	assert_eq(s.presenter.authored_object_count(), baseline + 1)


func test_second_commit_never_reported_saved_early() -> void:
	var s: EditorSession = await _start()
	s.commit(_tiny_change("one"))
	s.commit(_tiny_change("two"))
	assert_eq(s.document.document_revision, 2)
	assert_ne(s.storage.status_text(2), "Saved revision 2", "second revision has its own job")
	await _settle(s)
	assert_eq(s.storage.status_text(2), "Saved revision 2")


func test_injected_save_failure_is_reported_then_recovers() -> void:
	var s: EditorSession = await _start()
	s.inject_save_failure()
	s.commit(_tiny_change("one"))
	assert_true(s.storage.fault_injection.is_empty(), "injection is one-shot")
	await _settle(s)
	var text := s.storage.status_text(1)
	assert_true(text.begins_with("Save failed"), text)
	assert_true(text.contains("revision 0"), text)
	s.commit(_tiny_change("two"))
	await _settle(s)
	assert_eq(s.storage.status_text(2), "Saved revision 2")


func test_open_fixture_replaces_world_and_rejects_unknown() -> void:
	var s: EditorSession = await _start()
	var old_id := s.document.world_id
	var old_hash := s.authored_hash()
	var replaced := [0]
	s.world_replaced.connect(func() -> void: replaced[0] += 1)
	s.commit(_tiny_change("one"))
	assert_error_contains(s.open_fixture("nope"), "unknown fixture")
	assert_eq(s.document.world_id, old_id)
	assert_eq(replaced[0], 0)
	assert_eq(s.open_fixture("stress_100"), "")
	assert_eq(replaced[0], 1)
	assert_eq(s.presenter.authored_object_count(), 100)
	assert_ne(s.document.world_id, old_id)
	assert_eq(s.document.document_revision, 0)
	assert_eq(s.history.size(), 0)
	await _settle(s)
	var recovered := s.storage.recover_latest_valid(old_id, s.catalog)
	assert_true(recovered.doc != null, str(recovered.error))
	assert_eq(CanonicalEncoder.authored_hash(recovered.doc), old_hash)
	assert_eq(recovered.doc.document_revision, 1)


func test_open_new_km1_world_replaces_frames_and_saves_the_world() -> void:
	var s: EditorSession = await _start()
	var old_id := s.document.world_id
	assert_error_contains(s.open_new_world("volcano"), "unknown world kind")
	assert_eq(s.document.world_id, old_id, "a refused request leaves the world")
	assert_eq(s.rig.get_camera().far, 2000.0)
	assert_eq(s.open_new_world("hills"), "")
	assert_true(s.document.layout.equals(WorldLayout.km1()))
	assert_eq(s.document.source_label, "new:km1-hills")
	assert_eq(s.document.document_revision, 0)
	assert_eq(s.history.size(), 0)
	assert_eq(s.last_message, "Opened new 1 km world (hills)")
	assert_true(s.rig.get_camera().far > 2000.0, "far plane covers the larger world")
	assert_true(s.rig.controller.distance > 350.0, "reset view frames the whole world")
	assert_eq(s.rig.controller.world_rect(), WorldLayout.km1().world_rect())
	if s.terrain is TerrainAdapter:
		assert_eq((s.terrain as TerrainAdapter).verify_matches_document(s.document), PackedStringArray())
	await _settle(s)
	var recovered := s.storage.recover_latest_valid(s.document.world_id, s.catalog)
	assert_true(recovered.doc != null, str(recovered.error))
	assert_eq(CanonicalEncoder.authored_hash(recovered.doc), s.authored_hash(), "the new world is durable")
	assert_eq(s.open_fixture("flat"), "")
	assert_true(s.document.layout.is_legacy())
	assert_eq(s.rig.get_camera().far, 2000.0, "legacy camera limits are restored")
	assert_eq(s.rig.controller.distance, 140.0)


func test_export_is_verified() -> void:
	var s: EditorSession = await _start()
	s.tools.set_tool(ToolController.TOOL_PAINT)
	_stroke(s, -6.0, 6.0)
	var result := s.export_world()
	assert_eq(result.error, "")
	assert_true(FileAccess.file_exists(result.path), str(result.path))
	var imported := WorldPackage.import_package(result.path, s.catalog, s.storage.import_tmp_root)
	assert_eq(imported[1], "")
	assert_eq(CanonicalEncoder.authored_hash(imported[0]), s.authored_hash())
	assert_true(s.last_message.begins_with("Exported revision 1 (verified)"), s.last_message)


func test_deactivation_rolls_back_active_stroke() -> void:
	var s: EditorSession = await _start()
	s.commit(_tiny_change("base"))
	await _settle(s)
	var before := s.authored_hash()
	s.tools.set_tool(ToolController.TOOL_RAISE)
	_act(s, "tool_begin", 0.0, 0.0, 1.0)
	_act(s, "tool_move", 3.0, 0.0, 1.1)
	_act(s, "tool_move", 6.0, 0.0, 1.2)
	s.tools.advance(1.3)
	assert_ne(s.authored_hash(), before, "stroke is visible while active")
	s._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_false(s.tools.has_active_operation())
	assert_eq(s.authored_hash(), before)
	assert_eq(s.history.size(), 1, "no history entry for the cancelled stroke")
	assert_eq(s.document.document_revision, 1)
	assert_eq(s.storage.status_text(1), "Saved revision 1")


func test_history_eviction_is_silent_and_keeps_world() -> void:
	var s: EditorSession = await _start()
	var before := s.authored_hash()
	var messages: Array[String] = []
	s.message_posted.connect(func(text: String, _e: bool) -> void: messages.append(text))
	var cap := s.history.max_actions
	assert_eq(cap, 100, "configured action cap")
	for i in cap + 5:
		s.commit(_tiny_change("c%d" % i))
	assert_true(messages.is_empty(), "eviction posts no message: %s" % [messages])
	assert_eq(s.history.size(), cap)
	assert_eq(s.history.evicted_count, 5)
	assert_eq(s.status().history_oldest, "c5", "oldest entries evicted first")
	assert_eq(s.authored_hash(), before, "eviction never touches the world")


func test_status_has_all_keys() -> void:
	var s: EditorSession = await _start()
	var status := s.status()
	for key in ["tool", "mode", "inverted", "armed_asset", "picking_height", "stroke_state", "revision", "save_text", "save_state", "can_undo", "can_redo",
			"undo_label", "redo_label", "history_size", "history_bytes", "evicted", "history_oldest", "object_count",
			"selected_id", "provider_label", "banner", "editing_enabled", "development_input",
			"router_state", "contacts", "pressure_available", "renderer", "driver", "frame_p50_ms",
			"frame_p95_ms", "brush_p95_ms", "render_scale", "world_id", "operation_id", "last_hit"]:
		assert_true(status.has(key), "missing status key " + key)
	assert_false(status.has("authored_hash"))
	assert_eq(status.last_hit, "no hit")


## Drawn decorative instances once the view has settled: the stroke's pins have released and the active area
## and distance bands reflect the resting camera (thinning is view-dependent, never history-dependent).
func _settled_drawn(s: EditorSession) -> int:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 600 or s.render_state().active_edit.has_pins():
		await tree.process_frame
		if Time.get_ticks_msec() - t0 > 3000:
			break
	assert_true(s.layers.settle_now())
	return int(s.layers.stats().instances)


func test_scatter_stroke_renders_and_follows_undo_redo() -> void:
	var s: EditorSession = await _start()
	assert_eq(s.layers.stats().authored, 0)
	s.tools.set_tool("scatter")
	assert_empty_string(s.tools.set_setting("place", "radius", 20.0))
	_stroke(s, -10.0, 10.0)
	var added := s.document.scatter.count()
	assert_true(added > 5, "scattered %d" % added)
	assert_eq(s.history.size(), 1)
	await tree.process_frame
	assert_true(s.layers.settle_now())
	assert_eq(s.layers.stats().authored, added, "live stroke is bucketed")
	var drawn := await _settled_drawn(s)
	assert_true(drawn > 0 and drawn <= added, "live stroke is drawn (decorative cover may be thinned): %d of %d" % [drawn, added])
	assert_eq(s.undo(), "")
	await tree.process_frame
	assert_true(s.layers.settle_now())
	assert_eq(s.layers.stats().authored, 0, "undo redraws")
	assert_eq(s.layers.stats().instances, 0)
	assert_eq(s.redo(), "")
	await tree.process_frame
	assert_true(s.layers.settle_now())
	assert_eq(s.layers.stats().authored, added, "redo redraws")
	assert_eq(await _settled_drawn(s), drawn, "the same subset after redo")
	s.tools.set_tool("raise")
	_act(s, "tool_begin", 0.0, 0.0, 5.0)
	_act(s, "tool_move", 2.0, 0.0, 5.1)
	s.tools.advance(5.2)
	assert_true(s.layers.scatter.has_dirty(), "a live height edit marks scatter cells")
	s.cancel_active()

