class_name RenderCounters
extends RefCounted
## Live renderer counters (spec §18.1, §18.3). Values are reported exactly as the renderer returns
## them: headless and not-yet-measured frames read 0, never a substitute.

const MIB := 1048576.0


static func enable(viewport: Viewport) -> void:
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)


static func snapshot(viewport: Viewport) -> Dictionary:
	var rid := viewport.get_viewport_rid()
	var out := {
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
		"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid),
		"video_mem_mib": _mib(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
		"texture_mem_mib": _mib(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),
		"buffer_mem_mib": _mib(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED),
		"static_mem_mib": float(OS.get_static_memory_usage()) / MIB,
		"scale_3d": viewport.scaling_3d_scale,
		"viewport_size": [viewport.size.x, viewport.size.y],
		"pipelines": _pipelines(),
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


static func _pipelines() -> Dictionary:
	return {
		"canvas": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS),
		"mesh": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		"surface": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		"draw": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		"specialization": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION),
	}
