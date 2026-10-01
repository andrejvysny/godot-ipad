extends TestCase


func test_probe_cancel_restores_exact_hash_across_regions() -> void:
	var document := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var probe := LabProbe.new()
	probe.document = document
	var before := CanonicalEncoder.authored_hash(document)
	probe.begin(Vector2(-1, -1))
	probe.sample(0.1, Vector2(1, 1))
	assert_ne(CanonicalEncoder.authored_hash(document), before)
	var touched := probe.cancel()
	assert_eq(touched.controls.size(), 4)
	assert_eq(CanonicalEncoder.authored_hash(document), before)
	assert_false(probe.is_active())


func test_probe_pause_does_not_bridge_gap_and_history_is_exact() -> void:
	var document := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	var probe := LabProbe.new()
	probe.document = document
	probe.radius_m = 1.0
	var before := CanonicalEncoder.authored_hash(document)
	probe.begin(Vector2(-20, 0))
	probe.pause(0.1)
	probe.sample(0.2, Vector2(20, 0))
	var change := probe.finish(0.3)
	assert_true(change != null)
	assert_eq(ControlCodec.get_blend(document.get_control_at_sample(0, 0)), 0)
	var after := CanonicalEncoder.authored_hash(document)
	change.apply_to(document, false)
	assert_eq(CanonicalEncoder.authored_hash(document), before)
	change.apply_to(document, true)
	assert_eq(CanonicalEncoder.authored_hash(document), after)


func test_calibration_records_nine_points_in_logical_units() -> void:
	var calibration := LabCalibration.new()
	calibration.size = Vector2(1180, 820)
	calibration.start()
	for i in 9:
		var sample := PointerSample.new()
		sample.source = PointerSample.Source.PENCIL
		sample.position_viewport = calibration.target() + Vector2(3, 0)
		calibration.record(sample, 2.0, 0.5)
	assert_false(calibration.active)
	assert_eq(calibration.results.size(), 9)
	assert_eq(calibration.results[0].error_pt, 1.5)
	assert_true(calibration.results[0].pass)
	assert_eq(calibration.results[8].target, [1116.0, 756.0])
	calibration.free()
