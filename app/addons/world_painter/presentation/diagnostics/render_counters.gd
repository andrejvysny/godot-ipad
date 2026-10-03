class_name RenderCounters
extends RefCounted
## Live renderer counters (spec §18.1, §18.3, §19.1). Raw values are reported exactly as the renderer
## returns them (headless and not-yet-measured frames read 0); "gpu_status"/"cpu_status" say whether
## a raw timing may be used. Statistics must only take AVAILABLE samples.

const MIB := 1048576.0
const AVAILABLE := "AVAILABLE"
const WARMING_UP := "WARMING_UP"
const UNSUPPORTED := "UNSUPPORTED"
const NOT_RUN := "NOT_RUN"
const NOT_AVAILABLE := "NOT_AVAILABLE"
const WARMUP_SAMPLES := 4

static var _enabled: Dictionary = {}  # viewport rid -> true once measure_render_time was switched on
static var _warm: Dictionary = {}  # viewport rid -> snapshots taken since enable / last reset


static func enable(viewport: Viewport) -> void:
	var rid := viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	_enabled[rid] = true
	_warm[rid] = 0


## Restarts the warm-up window after a settings or population change.
static func reset_warmup(viewport: Viewport) -> void:
	_warm[viewport.get_viewport_rid()] = 0


## Validity of the viewport's render-time samples. Each call counts as one warm-up sample.
static func timing_status(viewport: Viewport) -> String:
	var rid := viewport.get_viewport_rid()
	if RenderingServer.get_rendering_device() == null:
		return UNSUPPORTED
	if not _enabled.get(rid, false):
		return NOT_RUN
	var seen: int = _warm.get(rid, 0) + 1
	_warm[rid] = seen
	return WARMING_UP if seen <= WARMUP_SAMPLES else AVAILABLE


static func snapshot(viewport: Viewport) -> Dictionary:
	var rid := viewport.get_viewport_rid()
	var timing := timing_status(viewport)
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var out := {
		"gpu_status": sample_status(timing, gpu_ms), "cpu_status": sample_status(timing, cpu_ms),
		"gpu_ms": gpu_ms, "cpu_ms": cpu_ms,
		"video_mem_mib": _mib(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
		"texture_mem_mib": _mib(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),
		"buffer_mem_mib": _mib(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED),
		"static_mem_mib": float(OS.get_static_memory_usage()) / MIB,
		"scale_3d": viewport.scaling_3d_scale,
		"viewport_size": [viewport.size.x, viewport.size.y],
		"internal_3d_size": [roundi(viewport.size.x * viewport.scaling_3d_scale), roundi(viewport.size.y * viewport.scaling_3d_scale)],
		"internal_3d_size_source": "display_size_times_scale",
		"pipelines": pipelines(),
	}
	out.merge(_view("visible", viewport, Viewport.RENDER_INFO_TYPE_VISIBLE))
	out.merge(_view("shadow", viewport, Viewport.RENDER_INFO_TYPE_SHADOW))
	return out


static func _view(prefix: String, viewport: Viewport, type: Viewport.RenderInfoType) -> Dictionary:
	return {
		prefix + "_draws": viewport.get_render_info(type, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		prefix + "_prims": viewport.get_render_info(type, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
		prefix + "_objects": viewport.get_render_info(type, Viewport.RENDER_INFO_OBJECTS_IN_FRAME),
	}


static func _mib(info: RenderingServer.RenderingInfo) -> float:
	return float(RenderingServer.get_rendering_info(info)) / MIB


## Cumulative pipeline compilation counters; reading them does not advance the timing warm-up window.
static func pipelines() -> Dictionary:
	return {
		"canvas": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS),
		"mesh": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		"surface": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		"draw": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		"specialization": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION),
	}


## A renderer can report CPU timing while GPU timing remains unavailable (for example Metal returning zero).
static func sample_status(base: String, measured_ms: float) -> String:
	if base != AVAILABLE:
		return base
	return AVAILABLE if is_finite(measured_ms) and measured_ms > 0.0 else NOT_AVAILABLE


static func merge_timing_status(current: String, sample: String) -> String:
	return AVAILABLE if current == AVAILABLE or sample == AVAILABLE else sample
