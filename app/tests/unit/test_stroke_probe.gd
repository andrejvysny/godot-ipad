extends TestCase
## StrokeProbe stats math and WorldChange delta helpers.


func test_stats_min_max_avg_duration() -> void:
	var p := StrokeProbe.new()
	p.begin("sculpt", 10.0)
	p.add_sample(true, 0.2, 0.4, 10.0)
	p.add_sample(false, 0.9, 1.0, 10.5)
	p.add_sample(true, 0.6, 0.8, 11.0)
	var r := p.finish("committed", null, 7, "")
	assert_eq(r.tool, "sculpt")
	assert_eq(r.result, "committed")
	assert_eq(r.samples, 3)
	assert_eq(r.pressure_valid_samples, 2)
	assert_near(r.pressure_min, 0.2, 1e-9)
	assert_near(r.pressure_max, 0.6, 1e-9)
	assert_near(r.pressure_avg, 0.4, 1e-9)
	assert_near(r.pf_avg, (0.4 + 1.0 + 0.8) / 3.0, 1e-9)
	assert_near(r.duration_s, 1.0, 1e-9)
	assert_eq(r.steps, 7)
	assert_near(r.peak_dh_m, 0.0, 0.0)
	assert_eq(r.controls_changed, 0)
	assert_eq(r.regions, 0)


func test_no_valid_pressure_is_nan() -> void:
	var p := StrokeProbe.new()
	p.begin("paint", 0.0)
	p.add_sample(false, 0.0, 1.0, 0.1)
	var r := p.finish("cancelled", null, 0, "stall")
	assert_true(is_nan(r.pressure_min) and is_nan(r.pressure_max) and is_nan(r.pressure_avg))
	assert_eq(r.error, "stall")


func _change() -> WorldChange:
	var c := WorldChange.new()
	var a := Vector2i(0, 0)
	var b := Vector2i(1, 0)
	c.before_heights[a] = PackedFloat32Array([1.0, 2.0, 3.0])
	c.after_heights[a] = PackedFloat32Array([1.5, 1.0, 3.0])
	c.before_heights[b] = PackedFloat32Array([0.0, 0.0])
	c.after_heights[b] = PackedFloat32Array([0.25, 0.0])
	c.before_controls[b] = PackedInt32Array([1, 2, 3, 4])
	c.after_controls[b] = PackedInt32Array([1, 9, 3, 8])
	return c


func test_change_deltas() -> void:
	var c := _change()
	assert_near(StrokeProbe.peak_height_delta(c), 1.0, 1e-6)
	assert_eq(StrokeProbe.changed_controls(c), 2)
	var p := StrokeProbe.new()
	p.begin("sculpt", 0.0)
	var r := p.finish("committed", c, 1, "")
	assert_eq(r.regions, 2)
	assert_near(r.peak_dh_m, 1.0, 1e-6)
	assert_eq(r.controls_changed, 2)


func test_null_change_is_zero() -> void:
	assert_near(StrokeProbe.peak_height_delta(null), 0.0, 0.0)
	assert_eq(StrokeProbe.changed_controls(null), 0)
