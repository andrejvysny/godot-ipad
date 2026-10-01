class_name OverviewRenderer
extends Node3D
## Whole-world 3D overview proxies (spec §9): groups of 1-4 configured levels (e.g. 64 / 128 / 256 m; origin-aligned,
## inside the world rect, each level a power-of-two multiple of the previous, level 0 children are the object cells)
## built by OverviewClusterBuilder on WorkerThreadPool tasks; at most one build start and one ArrayMesh pair per frame.
## Hierarchy cut (LOD-03): see OverviewCut. (De)activation shows/hides the proxy and (un)covers its cells in every
## population in the same call, so a proxy never shows over visible cell batches or with an ancestor/descendant.
## Populations (ObjectRenderWorld, ScatterRenderer): overview_members(rect), set_cells_covered(rect, covered),
## signal overview_changed(rect).

const MAX_JOBS := 2
const GRID_DIVISOR := 32.0  # grid cell = max(MIN_GRID_M, group size / 32): 4 m for 64 / 128 m groups, 8 m for 256 m
const MIN_GRID_M := 4.0
const MAX_LEVELS := 4
const NO_ROW := -1
const CAPTURE_BUDGET_MS := 1.0

var _registry: RenderAssetRegistry
var _pops: Array[Object] = []
var _levels := PackedFloat32Array([128.0, 256.0])
var _groups: Array[Dictionary] = [{}, {}]  # level -> Dictionary(Vector2i -> OverviewGroup)
var _world_rect := Rect2()
var _epoch: int = 0
var _profile: Dictionary = {}
var _hysteresis: float = 0.2
var _settle_ms: int = 250
var _cell_m: float = 32.0
var _cam := LodCameraTracker.new()
var _blocked: Array[Dictionary] = [{}, {}]  # level -> Dictionary(Vector2i -> true)
var _selected := AABB()
var _veg_hidden := false
var _roles_dirty := true
var _withheld := false  # an activation change waits for settled navigation
var _jobs: Array[Dictionary] = []
var _capture: Dictionary = {}  # member capture of the group being built, see _advance_capture
var _cap_positions := PackedVector3Array()
var _cap_assets := PackedInt32Array()
var _cap_sxz := PackedFloat32Array()
var _cap_sy := PackedFloat32Array()
var _rows: Dictionary = {}  # asset_id -> table row, NO_ROW without overview geometry
var _table := PackedFloat32Array()
var _material := StandardMaterial3D.new()
var _timing := {"mesh_builds": 0, "last_mesh": 0, "max_mesh": 0, "last_worker": 0, "max_worker": 0}  # usec


func _init() -> void:
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.cull_mode = BaseMaterial3D.CULL_BACK


## Proxy grid cell of a group of `size_m`: 4 m up to 128 m groups, 8 m for 256 m (lobe budget stays <= 1024).
static func grid_cell_m(size_m: float) -> float:
	return maxf(MIN_GRID_M, size_m / GRID_DIVISOR)


func material() -> Material:
	return _material


func setup(registry: RenderAssetRegistry, cell_m: float = 32.0, levels_m: PackedFloat32Array = PackedFloat32Array()) -> void:
	_registry = registry
	_cell_m = cell_m
	if levels_m.size() >= 1 and levels_m.size() <= MAX_LEVELS:
		_levels = levels_m
	_groups = []
	_blocked = []
	for lvl in _levels.size():
		_groups.append({})
		_blocked.append({})


func _exit_tree() -> void:
	for job: Dictionary in _jobs:
		WorkerThreadPool.wait_for_task_completion(int(job.task))
	_jobs.clear()


## Populations are asked for their members and told which cells to cover; `overview_changed` invalidates.
func add_population(pop: Object) -> void:
	if pop == null or _pops.has(pop) or not pop.has_method("overview_members") or not pop.has_method("set_cells_covered"):
		return
	_pops.append(pop)
	if pop.has_signal("overview_changed"):
		pop.connect("overview_changed", _on_changed)
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if g.active:
				pop.call("set_cells_covered", g.rect, true)


## Forgets every population (call reset() first so no covered cell stays hidden).
func clear_populations() -> void:
	for pop: Object in _pops:
		if is_instance_valid(pop) and pop.has_signal("overview_changed") and pop.is_connected("overview_changed", _on_changed):
			pop.disconnect("overview_changed", _on_changed)
	_pops.clear()


## Profile dictionary of rendering_profiles.json plus optional lod_hysteresis_fraction and settle_ms.
func set_lod_profile(profile: Dictionary) -> void:
	_profile = profile
	_hysteresis = float(profile.get("lod_hysteresis_fraction", 0.2))
	_settle_ms = int(profile.get("settle_ms", 250))
	_roles_dirty = true


## Groups exist for the level cells intersecting `rect`; replaces every existing group.
func set_world_rect(rect: Rect2) -> void:
	reset()
	_world_rect = rect
	for lvl in _levels.size():
		var size := _levels[lvl]
		var lo := Vector2i(floori(rect.position.x / size), floori(rect.position.y / size))
		var hi := Vector2i(ceili(rect.end.x / size) - 1, ceili(rect.end.y / size) - 1)
		for gx in range(lo.x, hi.x + 1):
			for gz in range(lo.y, hi.y + 1):
				var g := OverviewGroup.new(lvl, size, Vector2i(gx, gz))
				if lvl + 1 < _levels.size():
					var ratio := int(roundf(_levels[lvl + 1] / size))
					g.parent_key = Vector2i(floori(float(gx) / ratio), floori(float(gz) / ratio))
				_groups[lvl][g.key] = g


func world_rect() -> Rect2:
	return _world_rect


## World replacement: every group is deactivated (cells revealed) and dropped, outstanding builds are discarded.
func reset() -> void:
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if g.active:
				_set_active(g, false)
			g.free_nodes()
		_groups[lvl] = {}
		_blocked[lvl] = {}
	_epoch += 1
	_capture = {}
	_roles_dirty = true
	_withheld = false


func set_vegetation_hidden(hidden: bool) -> void:
	_veg_hidden = hidden
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if g.active and g.canopy != null:
				g.canopy.visible = not hidden


## Cells (Vector2i, objects_m units) pinned by the ActiveEditArea and the selected object's world bounds
## (zero size = none); groups holding either are blocked. Call every frame before service().
func set_blockers(pinned_cells: Dictionary, selected_bounds: AABB) -> void:
	_selected = selected_bounds
	for lvl in _levels.size():
		var blocked: Dictionary = _blocked[lvl]
		blocked.clear()
		var size := _levels[lvl]
		for cell: Vector2i in pinned_cells:
			blocked[Vector2i(floori(cell.x * _cell_m / size), floori(cell.y * _cell_m / size))] = true
		if selected_bounds.size != Vector3.ZERO:
			var lo := Vector2i(floori(selected_bounds.position.x / size), floori(selected_bounds.position.z / size))
			var hi := Vector2i(floori(selected_bounds.end.x / size), floori(selected_bounds.end.z / size))
			for gx in range(lo.x, hi.x + 1):
				for gz in range(lo.y, hi.y + 1):
					blocked[Vector2i(gx, gz)] = true


## Once per frame after the populations: collects finished builds, creates one mesh pair, refreshes roles,
## switches the cut and starts one build.
func service(camera: Camera3D) -> void:
	var now := Time.get_ticks_msec()
	if _cam.update(camera, now):
		_roles_dirty = true
	_collect_jobs()
	_make_one_mesh()
	if _roles_dirty:
		_refresh_roles()
	_apply_activation(_cam.settled(now, _settle_ms))
	_advance_capture()
	_start_capture(now)


func has_pending_work() -> bool:
	if not _jobs.is_empty() or not _capture.is_empty() or _withheld:
		return true
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if not g.current and not _blocked[lvl].has(g.key):
				return true
	return false


## {"area": AABB of the hit group, "distance": m, "level_m", "key"} for the nearest active proxy lobe along the
## ray, or {}. Only visible lobes count: canopy lobes are skipped while vegetation is hidden.
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_d := INF
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if not g.active:
				continue
			var local := origin - Vector3(g.rect.position.x, 0.0, g.rect.position.y)
			var d := _ray_lobes(local, dir, g.solid_boxes)
			if not _veg_hidden:
				d = minf(d, _ray_lobes(local, dir, g.canopy_boxes))
			if d < best_d:
				best_d = d
				best = {"area": g.world_aabb(), "distance": d, "level_m": g.level_m, "key": g.key}
	return best


func group(level: int, key: Vector2i) -> OverviewGroup:
	return _groups[level].get(key)


func groups(level: int) -> Array:
	return _groups[level].values()


func level_count() -> int:
	return _levels.size()


func level_m(level: int) -> float:
	return _levels[level]


## Counters for the bench and the status line. Triangle counts are estimates of the active proxies.
func stats() -> Dictionary:
	var out := {"groups": 0, "built": 0, "active": {}, "proxy_triangles": 0, "built_triangles": 0,
		"cells_covered": 0, "pending_builds": 0, "jobs": _jobs.size(), "mesh_builds": int(_timing.mesh_builds),
		"last_worker_ms": int(_timing.last_worker) / 1000.0, "max_worker_ms": int(_timing.max_worker) / 1000.0,
		"last_mesh_ms": int(_timing.last_mesh) / 1000.0, "max_mesh_ms": int(_timing.max_mesh) / 1000.0}
	for lvl in _levels.size():
		out.active[int(_levels[lvl])] = 0
		for g: OverviewGroup in _groups[lvl].values():
			out.groups += 1
			out.built += 1 if g.current else 0
			out.pending_builds += 0 if g.current else 1
			out.built_triangles += g.triangles
			if g.active:
				out.active[int(g.level_m)] = int(out.active.get(int(g.level_m), 0)) + 1
				out.proxy_triangles += g.triangles
				out.cells_covered += int(pow(g.level_m / _cell_m, 2.0))
	return out


func _ray_lobes(local_origin: Vector3, dir: Vector3, boxes: PackedVector3Array) -> float:
	var best := INF
	for i in range(0, boxes.size(), 2):
		var box := AABB(boxes[i], boxes[i + 1])
		if box.has_point(local_origin):
			return 0.0
		var hit: Variant = box.intersects_ray(local_origin, dir)
		if hit != null:
			best = minf(best, local_origin.distance_to(hit as Vector3))
	return best


# --- Invalidation ------------------------------------------------------------------------

func _on_changed(rect: Rect2) -> void:
	var now := Time.get_ticks_msec()
	for lvl in _levels.size():
		var size := _levels[lvl]
		var lo := Vector2i(floori(rect.position.x / size), floori(rect.position.y / size))
		var hi := Vector2i(ceili(rect.end.x / size) - 1, ceili(rect.end.y / size) - 1)
		var groups_here: Dictionary = _groups[lvl]
		if (hi.x - lo.x + 1) * (hi.y - lo.y + 1) > groups_here.size():
			for g: OverviewGroup in groups_here.values():
				if rect.intersects(g.rect):
					_invalidate(g, now)
			continue
		for gx in range(lo.x, hi.x + 1):
			for gz in range(lo.y, hi.y + 1):
				var g: OverviewGroup = groups_here.get(Vector2i(gx, gz))
				if g != null:
					_invalidate(g, now)


## Reveals the group's cells at once and discards its proxy and any build in flight (new generation).
func _invalidate(g: OverviewGroup, now: int) -> void:
	g.dirty_ms = now
	if g.active:
		_set_active(g, false)
	if g.current or g.building or not g.result.is_empty():
		g.gen += 1
		g.building = false
		g.result = {}
		g.current = false
		g.drop_meshes()
	g.invalidated = true


# --- Builds ------------------------------------------------------------------------------

func _collect_jobs() -> void:
	for i in range(_jobs.size() - 1, -1, -1):
		var job := _jobs[i]
		if not WorkerThreadPool.is_task_completed(int(job.task)):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job.task))
		_jobs.remove_at(i)
		var g: OverviewGroup = job.group
		if int(job.epoch) != _epoch or int(job.gen) != g.gen:
			continue
		var out: Dictionary = job.out
		g.building = false
		g.result = out.result
		g.worker_usec = int(out.usec)
		_timing.last_worker = g.worker_usec
		_timing.max_worker = maxi(int(_timing.max_worker), g.worker_usec)


func _make_one_mesh() -> void:
	var best: OverviewGroup = null
	var best_score := INF
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if g.result.is_empty():
				continue
			var score := _score(g)
			if score < best_score:
				best_score = score
				best = g
	if best == null:
		return
	best.apply_result(self, _material)
	_timing.mesh_builds = int(_timing.mesh_builds) + 1
	_timing.last_mesh = best.mesh_usec
	_timing.max_mesh = maxi(int(_timing.max_mesh), best.mesh_usec)


## Picks the most wanted group that needs a proxy and starts capturing its members (one capture at a time).
func _start_capture(now: int) -> void:
	if not _capture.is_empty() or _jobs.size() >= MAX_JOBS:
		return
	var best: OverviewGroup = null
	var best_score := INF
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			if g.current or g.building or not g.result.is_empty() or now - g.dirty_ms < _settle_ms \
					or _blocked[lvl].has(g.key):
				continue
			var score := _score(g)
			if score < best_score:
				best_score = score
				best = g
	if best == null:
		return
	var cells: Array[Rect2] = []
	var steps := int(ceilf(best.level_m / _cell_m))
	for ix in steps:
		for iz in steps:
			cells.append(Rect2(best.rect.position + Vector2(ix, iz) * _cell_m, Vector2(_cell_m, _cell_m)))
	best.building = true
	best.complete = true
	_cap_positions = PackedVector3Array()
	_cap_assets = PackedInt32Array()
	_cap_sxz = PackedFloat32Array()
	_cap_sy = PackedFloat32Array()
	_capture = {"group": best, "gen": best.gen, "epoch": _epoch, "cells": cells, "next": 0}


## Reads members cell by cell within CAPTURE_BUDGET_MS per frame, then hands the plain arrays to a worker.
## An invalidation (new generation) abandons the capture.
func _advance_capture() -> void:
	if _capture.is_empty():
		return
	var g: OverviewGroup = _capture.group
	if int(_capture.epoch) != _epoch or int(_capture.gen) != g.gen:
		_capture = {}
		return
	var t0 := Time.get_ticks_usec()
	var cells: Array[Rect2] = _capture.cells
	while int(_capture.next) < cells.size() and float(Time.get_ticks_usec() - t0) / 1000.0 < CAPTURE_BUDGET_MS:
		_capture_cell(g, cells[int(_capture.next)])
		_capture.next = int(_capture.next) + 1
	if int(_capture.next) < cells.size():
		return
	g.members = _cap_positions.size()
	if _cap_positions.is_empty():
		g.building = false
		g.result = OverviewClusterBuilder.empty_result()
	else:
		var input := {"origin": g.rect.position, "size_m": g.level_m, "cell_m": grid_cell_m(g.level_m),
			"positions": _cap_positions, "assets": _cap_assets, "scale_xz": _cap_sxz, "scale_y": _cap_sy,
			"table": _table.duplicate()}
		var out := {}
		var task := WorkerThreadPool.add_task(OverviewClusterBuilder.run.bind(input, out), false, "overview_group")
		_jobs.append({"task": task, "group": g, "gen": g.gen, "epoch": _epoch, "out": out})
	_capture = {}


## Appends the members of one cell rect; asset parameters are resolved here, on the main thread.
func _capture_cell(g: OverviewGroup, rect: Rect2) -> void:
	for pop: Object in _pops:
		for m: Dictionary in pop.call("overview_members", rect):
			var row := _row_of(str(m.asset_id))
			if row == NO_ROW:
				g.complete = g.complete and _registry != null and _registry.descriptor(str(m.asset_id)) != null
				continue
			var xf: Transform3D = m.xf
			_cap_positions.append(xf.origin)
			_cap_assets.append(row)
			_cap_sxz.append((xf.basis.x.length() + xf.basis.z.length()) * 0.5)
			_cap_sy.append(xf.basis.y.length())


## Groups the camera wants proxies for come first, then nearest first (idle prefetch of the others).
func _score(g: OverviewGroup) -> float:
	var wanted := g.group_level >= g.level
	return _effective(g) + (0.0 if wanted else 1.0e9)


## Table row of an asset's overview parameters; NO_ROW for assets without geometry (kind none or no descriptor).
func _row_of(asset_id: String) -> int:
	if _rows.has(asset_id):
		return _rows[asset_id]
	var row := NO_ROW
	var d := _registry.descriptor(asset_id) if _registry != null else null
	if d != null and str(d.overview.kind) != "none":
		row = _table.size() / OverviewClusterBuilder.ROW
		_table.append_array(OverviewClusterBuilder.table_row(d.overview))
	_rows[asset_id] = row
	return row


# --- Roles and the hierarchy cut ---------------------------------------------------------

func _effective(g: OverviewGroup) -> float:
	return _cam.effective_to_box(Vector3(g.rect.position.x, g.y_lo, g.rect.position.y),
			Vector3(g.rect.end.x, g.y_hi, g.rect.end.y))


func _refresh_roles() -> void:
	_roles_dirty = false
	for lvl in _levels.size():
		for g: OverviewGroup in _groups[lvl].values():
			g.group_level = LodPolicy.group_level_for(_effective(g), _profile, _levels.size(), g.group_level, _hysteresis)


func _apply_activation(settled: bool) -> void:
	var off: Array[OverviewGroup] = []
	var on: Array[OverviewGroup] = []
	_withheld = OverviewCut.compute(_groups, _blocked, settled, off, on)
	for g in off:
		_set_active(g, false)
	for g in on:
		_set_active(g, true)


func _set_active(g: OverviewGroup, on: bool) -> void:
	g.active = on
	for pop: Object in _pops:
		pop.call("set_cells_covered", g.rect, on)
	if g.canopy != null:
		g.canopy.visible = on and not _veg_hidden
	if g.solid != null:
		g.solid.visible = on
