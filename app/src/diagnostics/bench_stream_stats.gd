class_name BenchStreamStats
extends RefCounted
## Streaming frame/GPU/CPU statistics of the scenario and sustained benches (spec §19.2: aggregate streaming
## histograms instead of unbounded per-frame arrays). Memory is fixed: three 0.1 ms histograms up to
## MAX_MS plus counters. Percentiles are the upper edge of the histogram bin (error < RESOLUTION_MS); max and
## the hitch counters are exact. summary() has the same keys as BenchPlan.summarize.

const RESOLUTION_MS := 0.1
const MAX_MS := 500.0
const BINS := 5001  # the last bin collects everything >= MAX_MS

var frames := 0
var _frame := PackedInt32Array()
var _gpu := PackedInt32Array()
var _cpu := PackedInt32Array()
var _gpu_samples := 0
var _cpu_samples := 0
var gpu_status := RenderCounters.NOT_RUN
var cpu_status := RenderCounters.NOT_RUN
var _peak := 0.0
var _counts := {}
var _target_ms := 1000.0 / BenchPlan.DEFAULT_TARGET_FPS


func _init(target_fps: float = BenchPlan.DEFAULT_TARGET_FPS) -> void:
	_target_ms = 1000.0 / target_fps
	reset()


func reset() -> void:
	frames = 0
	_frame = PackedInt32Array()
	_frame.resize(BINS)
	_gpu = PackedInt32Array()
	_gpu.resize(BINS)
	_cpu = PackedInt32Array()
	_cpu.resize(BINS)
	_gpu_samples = 0
	_cpu_samples = 0
	gpu_status = RenderCounters.NOT_RUN
	cpu_status = RenderCounters.NOT_RUN
	_peak = 0.0
	_counts = {"over_16_7": 0, "over_33_4": 0, "missed_target": 0, "hitches_over_50_ms": 0, "over_100_ms": 0,
		"over_250_ms": 0}


func add_frame(ms: float) -> void:
	frames += 1
	_peak = maxf(_peak, ms)
	_frame[_bin(ms)] += 1
	_counts.over_16_7 += 1 if ms > 16.7 else 0
	_counts.over_33_4 += 1 if ms > 33.4 else 0
	_counts.missed_target += 1 if ms > BenchPlan.MISSED_TARGET_FACTOR * _target_ms else 0
	_counts.hitches_over_50_ms += 1 if ms > 50.0 else 0
	_counts.over_100_ms += 1 if ms > 100.0 else 0
	_counts.over_250_ms += 1 if ms > 250.0 else 0


## Only AVAILABLE render-time samples may be added (RenderCounters validity).
func add_timing(gpu_ms: float, cpu_ms: float, gpu_valid: bool = true, cpu_valid: bool = true) -> void:
	if gpu_valid:
		gpu_status = RenderCounters.merge_timing_status(gpu_status, RenderCounters.sample_status(RenderCounters.AVAILABLE, gpu_ms))
	if cpu_valid:
		cpu_status = RenderCounters.merge_timing_status(cpu_status, RenderCounters.sample_status(RenderCounters.AVAILABLE, cpu_ms))
	if gpu_valid and RenderCounters.sample_status(RenderCounters.AVAILABLE, gpu_ms) == RenderCounters.AVAILABLE:
		_gpu_samples += 1
		_gpu[_bin(gpu_ms)] += 1
	if cpu_valid and RenderCounters.sample_status(RenderCounters.AVAILABLE, cpu_ms) == RenderCounters.AVAILABLE:
		_cpu_samples += 1
		_cpu[_bin(cpu_ms)] += 1


func add_snapshot(sample: Dictionary) -> void:
	var gpu := RenderCounters.sample_status(str(sample.gpu_status), float(sample.gpu_ms))
	var cpu := RenderCounters.sample_status(str(sample.cpu_status), float(sample.cpu_ms))
	gpu_status = RenderCounters.merge_timing_status(gpu_status, gpu)
	cpu_status = RenderCounters.merge_timing_status(cpu_status, cpu)
	add_timing(float(sample.gpu_ms), float(sample.cpu_ms), gpu == RenderCounters.AVAILABLE, cpu == RenderCounters.AVAILABLE)


func missed_target() -> int:
	return int(_counts.missed_target)


func hitches_over_50() -> int:
	return int(_counts.hitches_over_50_ms)


func percentile(q: float) -> float:
	return _quantile(_frame, frames, q, _peak)


func summary(recorded_gpu_status: String = "", recorded_cpu_status: String = "") -> Dictionary:
	var gpu := gpu_status if recorded_gpu_status == "" else recorded_gpu_status
	var cpu := cpu_status if recorded_cpu_status == "" else recorded_cpu_status
	if _gpu_samples == 0 and gpu == RenderCounters.AVAILABLE:
		gpu = RenderCounters.NOT_AVAILABLE
	if _cpu_samples == 0 and cpu == RenderCounters.AVAILABLE:
		cpu = RenderCounters.NOT_AVAILABLE
	var out := {"frames": frames, "frame_interval_source": "wall_clock_proxy",
		"frame_p50_ms": percentile(0.5), "frame_p95_ms": percentile(0.95), "frame_p99_ms": percentile(0.99),
		"frame_max_ms": _peak, "target_ms": _target_ms, "gpu_samples": _gpu_samples, "gpu_status": gpu,
		"cpu_samples": _cpu_samples, "cpu_status": cpu, "histogram_resolution_ms": RESOLUTION_MS}
	out.merge(_counts)
	for q: Array in [["p50", 0.5], ["p95", 0.95], ["p99", 0.99]]:
		out["gpu_%s_ms" % q[0]] = _quantile_or_null(_gpu, _gpu_samples, q[1])
		out["cpu_%s_ms" % q[0]] = _quantile_or_null(_cpu, _cpu_samples, q[1])
	return out


func gpu_percentile(q: float) -> Variant:
	return _quantile_or_null(_gpu, _gpu_samples, q)


static func _bin(ms: float) -> int:
	return clampi(int(ms / RESOLUTION_MS), 0, BINS - 1)


func _quantile_or_null(hist: PackedInt32Array, samples: int, q: float) -> Variant:
	return null if samples == 0 else _quantile(hist, samples, q, MAX_MS)


## Upper bin edge of the sample with rank ceil(q * n), capped at `ceiling`; 0 for an empty histogram.
static func _quantile(hist: PackedInt32Array, n: int, q: float, ceiling: float) -> float:
	if n == 0:
		return 0.0
	var rank := maxi(1, ceili(q * float(n)))
	var seen := 0
	for i in hist.size():
		seen += hist[i]
		if seen >= rank:
			return minf(float(i + 1) * RESOLUTION_MS, ceiling) if i < BINS - 1 else ceiling
	return ceiling
