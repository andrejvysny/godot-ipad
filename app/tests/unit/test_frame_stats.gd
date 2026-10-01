extends TestCase
## FrameStats percentiles, ring wrap, named samples (spec §18.1, §18.3).


func test_percentiles_known_data() -> void:
	var fs := FrameStats.new()
	for i in range(1, 101):
		fs.add(float(i))
	assert_eq(fs.count(), 100)
	assert_near(fs.p50(), 50.0, 1e-9)
	assert_near(fs.p95(), 95.0, 1e-9)
	assert_near(fs.max_ms(), 100.0, 1e-9)
	assert_eq(fs.count_over(90.0), 10)


func test_ring_wraps_and_empty_is_zero() -> void:
	var fs := FrameStats.new(10)
	assert_near(fs.p95(), 0.0, 0.0)
	for i in range(1, 26):
		fs.add(float(i))
	assert_eq(fs.count(), 10)
	assert_near(fs.max_ms(), 25.0, 1e-9)
	assert_eq(fs.count_over(15.0), 10)


func test_named_samples_and_snapshot() -> void:
	var fs := FrameStats.new()
	for i in range(1, 21):
		fs.add_sample("brush", float(i))
	assert_near(fs.sample_p95("brush"), 19.0, 1e-9)
	assert_near(fs.sample_p95("missing"), 0.0, 0.0)
	fs.begin_sample("t")
	fs.end_sample("t")
	fs.end_sample("never_begun")
	var snap := fs.snapshot()
	assert_true(snap["timers"].has("brush") and snap["timers"].has("t"))
	assert_false(snap["timers"].has("never_begun"))
