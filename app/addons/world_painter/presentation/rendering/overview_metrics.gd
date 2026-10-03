class_name OverviewMetrics
extends RefCounted
## Overview counters and lobe ray intersection without mutating retained groups.


static func stats(groups: Array[Dictionary], levels: PackedFloat32Array, cell_m: float,
		jobs: int, timing: Dictionary, suppressed: bool) -> Dictionary:
	var out := {"groups": 0, "built": 0, "active": {}, "proxy_triangles": 0, "built_triangles": 0,
		"retained_proxy_triangles": 0, "proxy_submissions": 0, "view_suppressed": suppressed,
		"cells_covered": 0, "pending_builds": 0, "jobs": jobs, "mesh_builds": int(timing.mesh_builds),
		"last_worker_ms": int(timing.last_worker) / 1000.0, "max_worker_ms": int(timing.max_worker) / 1000.0,
		"last_mesh_ms": int(timing.last_mesh) / 1000.0, "max_mesh_ms": int(timing.max_mesh) / 1000.0}
	for lvl in levels.size():
		out.active[int(levels[lvl])] = 0
		for g: OverviewGroup in groups[lvl].values():
			out.groups += 1
			out.built += 1 if g.current else 0
			out.pending_builds += 0 if g.current else 1
			out.built_triangles += g.triangles
			if g.active:
				out.active[int(g.level_m)] = int(out.active.get(int(g.level_m), 0)) + 1
				out.retained_proxy_triangles += g.triangles
				if not suppressed:
					out.proxy_triangles += g.triangles
					out.proxy_submissions += int(g.canopy != null and g.canopy.visible) + int(g.solid != null and g.solid.visible)
				out.cells_covered += int(pow(g.level_m / cell_m, 2.0))
	return out


static func ray_lobes(local_origin: Vector3, dir: Vector3, boxes: PackedVector3Array) -> float:
	var best := INF
	for i in range(0, boxes.size(), 2):
		var box := AABB(boxes[i], boxes[i + 1])
		if box.has_point(local_origin):
			return 0.0
		var hit: Variant = box.intersects_ray(local_origin, dir)
		if hit != null:
			best = minf(best, local_origin.distance_to(hit as Vector3))
	return best
