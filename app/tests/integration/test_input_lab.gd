extends TestCase

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
var lab: InputLab
var log_filter: TerrainTests.KnownWarningFilter


func after_each() -> void:
	if is_instance_valid(lab):
		tree.root.remove_child(lab)
		lab.free()
	if log_filter != null:
		assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
		OS.remove_logger(log_filter)


func test_lab_probe_checkpoint_reload_and_exact_cancel() -> void:
	# The pinned Terrain3D binary emits its known compatibility deprecation on startup.
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)
	lab = InputLab.new()
	tree.root.add_child(lab)
	await tree.process_frame
	assert_true(lab._ready_for_input)
	assert_eq(lab.document.objects.size(), 1)
	var before := CanonicalEncoder.authored_hash(lab.document)
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.MOUSE_DEV
	var point := Vector3(20, lab.document.sample_height(20, 20), 20)
	sample.position_viewport = lab.rig.get_camera().unproject_position(point)
	sample.timestamp_s = 1.0
	lab._tool_action({"type": "tool_begin", "sample": sample})
	assert_true(lab.probe.is_active())
	assert_ne(CanonicalEncoder.authored_hash(lab.document), before)
	lab._tool_action({"type": "tool_cancel", "reason": "native_cancel"})
	assert_eq(CanonicalEncoder.authored_hash(lab.document), before)
	lab._tool_action({"type": "tool_begin", "sample": sample})
	lab._tool_action({"type": "tool_end", "sample": sample, "over_ui": false})
	assert_eq(lab.document.document_revision, 1)
	var after := CanonicalEncoder.authored_hash(lab.document)
	for i in 300:
		if not lab.storage.is_busy():
			break
		await tree.process_frame
	assert_false(lab.storage.is_busy(), "checkpoint completes")
	assert_eq(lab.storage.status_text(1), "Saved revision 1")
	lab._reload()
	assert_eq(CanonicalEncoder.authored_hash(lab.document), after)
	lab.adapter.flush()
	await tree.process_frame
	assert_true(lab.adapter.verify_matches_document(lab.document).is_empty())
	lab._save_trace()
	assert_true(lab._message.contains("saved"), lab._message)


func test_lab_panel_routes_pencil_and_fingers_to_ui() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)
	lab = InputLab.new()
	tree.root.add_child(lab)
	await tree.process_frame
	var point := UiHitTester.screen_rect(lab._radius).get_center()
	assert_true(lab.input.ui_hits.is_over_ui(point), "lab panel registered")
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.PENCIL
	sample.phase = PointerSample.Phase.BEGIN
	sample.pointer_id = 1
	sample.position_viewport = point
	var actions := lab.input.router.process(sample)
	assert_eq(actions[0].type, "ui_press", "UI must never begin a terrain operation")
	sample.phase = PointerSample.Phase.END
	lab.input.router.process(sample)
	sample.source = PointerSample.Source.FINGER
	sample.pointer_id = 2
	sample.phase = PointerSample.Phase.BEGIN
	sample.timestamp_s = 5.0  # past the post-Pencil guard window
	actions = lab.input.router.process(sample)
	assert_eq(actions[0].type, "ui_press", "finger over UI is UI, never a probe")
	assert_eq(actions[0].source, "finger")
	sample.phase = PointerSample.Phase.END
	lab.input.router.process(sample)
	assert_false(lab.probe.is_active())
	lab._panel.hide()
	assert_false(lab.input.ui_hits.is_over_ui(point), "hidden panel does not block calibration")


func test_lab_pencil_click_across_frames_operates_scale_button() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)
	lab = InputLab.new()
	var fake := InputTests.FakeProvider.new()
	lab.input.platform_override = "iOS"
	lab.input.provider_override = fake
	tree.root.add_child(lab)
	for i in 4:
		await tree.process_frame
	var button: Button
	for child in lab._panel.get_children():
		if child is Button and child.text == "Toggle 100% / 50% 3D scale":
			button = child
	assert_true(button != null)
	var center := UiHitTester.screen_rect(button).get_center()
	var original_scale := tree.root.scaling_3d_scale
	fake.push(PointerSample.Source.PENCIL, 1, PointerSample.Phase.BEGIN, center)
	lab.input.run_frame()
	for i in 4:
		await tree.process_frame
	fake.push(PointerSample.Source.PENCIL, 1, PointerSample.Phase.END, center)
	lab.input.run_frame()
	assert_ne(tree.root.scaling_3d_scale, original_scale, "Pencil release activates the lab button")
	tree.root.scaling_3d_scale = original_scale
