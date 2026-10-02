extends TestCase


func test_zero_gpu_does_not_discard_available_cpu_or_claim_gpu_measurement() -> void:
	var stats := BenchStreamStats.new()
	for index in 8:
		stats.add_frame(16.0)
		stats.add_snapshot({"gpu_ms": 0.0, "cpu_ms": 2.0,
			"gpu_status": RenderCounters.AVAILABLE, "cpu_status": RenderCounters.AVAILABLE})
	var summary := stats.summary()
	assert_eq(summary.gpu_status, RenderCounters.NOT_AVAILABLE)
	assert_eq(summary.gpu_samples, 0)
	assert_eq(summary.gpu_p50_ms, null)
	assert_eq(summary.gpu_p95_ms, null)
	assert_eq(summary.gpu_p99_ms, null)
	assert_eq(summary.cpu_status, RenderCounters.AVAILABLE)
	assert_eq(summary.cpu_samples, 8)
	assert_near(summary.cpu_p95_ms, 2.0, 0.11)


func test_invalid_cpu_and_gpu_are_filtered_independently() -> void:
	var stats := BenchStreamStats.new()
	stats.add_timing(1.0, 0.0)
	stats.add_timing(INF, 2.0)
	stats.add_timing(NAN, -1.0)
	var summary := stats.summary(RenderCounters.AVAILABLE, RenderCounters.AVAILABLE)
	assert_eq(summary.gpu_samples, 1)
	assert_eq(summary.cpu_samples, 1)
	assert_near(summary.gpu_p95_ms, 1.0, 0.11)
	assert_near(summary.cpu_p95_ms, 2.0, 0.11)
	stats.reset()
	stats.add_timing(0.0, 0.0)
	assert_eq(stats.summary(RenderCounters.AVAILABLE, RenderCounters.AVAILABLE).gpu_status, RenderCounters.NOT_AVAILABLE)
	assert_eq(stats.summary(RenderCounters.AVAILABLE, RenderCounters.AVAILABLE).cpu_p95_ms, null)


func test_timing_status_preserves_unsupported_and_warmup() -> void:
	for invalid in [0.0, -1.0, INF, NAN]:
		assert_eq(RenderCounters.sample_status(RenderCounters.AVAILABLE, invalid), RenderCounters.NOT_AVAILABLE)
	assert_eq(RenderCounters.sample_status(RenderCounters.AVAILABLE, 0.01), RenderCounters.AVAILABLE)
	assert_eq(RenderCounters.sample_status(RenderCounters.UNSUPPORTED, 4.0), RenderCounters.UNSUPPORTED)
	assert_eq(RenderCounters.sample_status(RenderCounters.WARMING_UP, 4.0), RenderCounters.WARMING_UP)


func test_peak_samples_use_each_timing_validity() -> void:
	var peak := {"gpu_ms": null, "cpu_ms": null}
	var sample := {"gpu_ms": 0.0, "cpu_ms": 2.0, "gpu_status": RenderCounters.NOT_AVAILABLE,
		"cpu_status": RenderCounters.AVAILABLE, "visible_draws": 1, "shadow_draws": 0,
		"visible_prims": 10, "shadow_prims": 0, "visible_objects": 1}
	RenderBench._track_peak(peak, sample)
	assert_eq(peak.gpu_ms, null)
	assert_eq(peak.cpu_ms, 2.0)
	sample.gpu_ms = 3.0
	sample.gpu_status = RenderCounters.AVAILABLE
	sample.cpu_ms = 0.0
	sample.cpu_status = RenderCounters.NOT_AVAILABLE
	RenderBench._track_peak(peak, sample)
	assert_eq(peak.gpu_ms, 3.0)
	assert_eq(peak.cpu_ms, 2.0)
