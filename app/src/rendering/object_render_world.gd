class_name ObjectRenderWorld
extends ObjectBatchStore
## Draws presented object records through per-(cell, asset, representation) MultiMesh batches (spec §5, §7,
## §8.1, §8.3); ownership and batch primitives are in ObjectBatchStore.
## Work is split: CPU state and removals/updates of existing slots are applied immediately and flushed in
## the next service_frame regardless of budget; building batches for a newly attached world (clear() then
## upserts) is scheduled, nearest cells first, within the frame budget. Each 32 m cell has its own role
## (ObjectLodDirector); role changes of built cells wait for settled navigation and never touch pinned cells.

signal placeholders_reported(text: String)

var _pin_check := Callable()
var _camera: Camera3D
var _lod: ObjectLodDirector
var _recheck: Dictionary = {}  # Vector2i -> true: pinned cells whose representation is re-evaluated once unpinned
var _notice_sent: bool = false


func setup(registry: RenderAssetRegistry, cache: RenderAssetCache, cell_size_m: float, is_hidden: Callable,
		catalog: AssetCatalog = null) -> void:
	_res = RenderWorldResources.new(registry, cache)
	_cell_size = maxf(cell_size_m, 1.0)
	_is_hidden = is_hidden
	_catalog = catalog
	_queue = RenderWorkQueue.new(_cell_size)
	_lod = ObjectLodDirector.new(_cell_size)
	_lod.set_profile({})
	_pool = PromotedNodePool.new(self, POOL_MAX)
	_preview = ObjectPreviewOwners.new(self)
	_attaching = true


func set_camera(camera: Camera3D) -> void:
	_camera = camera


func set_pin_check(check: Callable) -> void:
	_pin_check = check


## Profile dictionary of rendering_profiles.json (tree_detail_radius_m, near_min_role) plus the optional
## lod_hysteresis_fraction and settle_ms of its stability section.
func set_lod_profile(profile: Dictionary) -> void:
	_lod.set_profile(profile)


## Compatibility: only the minimum unselected role of the current profile changes.
func set_default_role(role: String) -> void:
	set_lod_profile(_lod.profile.merged({"near_min_role": role}, true))


func world_epoch() -> int:
	return _res.epoch


## World replacement: epoch + 1, outstanding cache work of the old epoch cancelled, every node released.
func clear() -> void:
	for cell: RenderCell in _cells.values():
		for key: String in cell.batches.keys():
			_retire_batch(cell, key)
	_release_promoted()
	_preview.clear()
	_selected = ""
	for dict: Dictionary in [_asset, _xf, _cell_of, _owner, _cells, _asset_cells, _wanted, _dirty, _covered, _recheck]:
		dict.clear()
	_queue.clear()
	_lod.reset()
	_res.next_epoch()
	_attaching = true
	_notice_sent = false
	overview_changed.emit(EVERYTHING)


func upsert(id: String, asset_id: String, world_xf: Transform3D) -> void:
	var key := _cell_key(world_xf.origin)
	var old_key := key
	if _asset.has(id):
		old_key = _cell_of[id]
		if _asset[id] == asset_id and old_key == key:
			if _xf[id] != world_xf:
				_xf[id] = world_xf
				_apply_transform(id)
				_emit_changed(key)
			return
		_detach(id, id == _selected and _asset[id] == asset_id)
	_asset[id] = asset_id
	_xf[id] = world_xf
	_cell_of[id] = key
	if not _owner.has(id):
		_owner[id] = ""
	var cell := _cell(key)
	cell.y_lo = minf(cell.y_lo, world_xf.origin.y)
	cell.y_hi = maxf(cell.y_hi, world_xf.origin.y)
	if cell.role == "":
		cell.role = _lod.initial_role(cell)
		cell.wanted = cell.role
	if not cell.members.has(asset_id):
		cell.members[asset_id] = {}
	(cell.members[asset_id] as Dictionary)[id] = true
	if not _asset_cells.has(asset_id):
		_asset_cells[asset_id] = {}
	(_asset_cells[asset_id] as Dictionary)[key] = true
	if not _wanted.has(asset_id):
		_wanted[asset_id] = true
		_res.rep_for(asset_id, cell.role, 2)
	if id == _selected:
		if _owner[id] != "promoted":
			_promote(id)
		else:
			_apply_transform(id)
	else:
		_attach_owner(id)
	_emit_changed(old_key)
	if old_key != key:
		_emit_changed(key)


func remove(id: String) -> void:
	if not _asset.has(id):
		return
	var key: Vector2i = _cell_of[id]
	_detach(id, false)
	for dict: Dictionary in [_asset, _xf, _cell_of, _owner]:
		dict.erase(id)
	if id == _selected:
		_selected = ""
	_emit_changed(key)


## Promotes `id` to a pooled node showing the `selected` tier; the previous selection returns to its batch.
## Both ownership changes and their uploads are applied before returning.
func set_selected(id: String) -> void:
	var want := id if _asset.has(id) else ""
	if want == _selected:
		return
	var prev := _selected
	_selected = want
	if prev != "":
		_release_promoted()
		_owner[prev] = ""
		_attach_owner(prev)
		_preview.restore(prev)
	if want != "":
		_promote(want)
	_flush_dirty()


func set_vegetation_visibility_changed() -> void:
	for cell: RenderCell in _cells.values():
		for batch: InstanceBatch in cell.batches.values():
			batch.node.visible = _batch_visible(batch)
	if _promoted != null:
		_promoted.visible = not _hidden(_selected)
	_preview.refresh_visibility()


## Applies pending slot updates, then builds queued groups until `budget_ms` is spent (at least one).
func service_frame(budget_ms: float) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	_update_focus()
	_flush_dirty()
	for asset_id in _res.poll_ready():
		_queue_asset(asset_id)
	_service_lod()
	_upgrade_promoted()
	var built := _run_queue(t0, budget_ms)
	_report_placeholders()
	return {"built": built, "pending": _queue.size()}


func has_pending_work() -> bool:
	return not _queue.is_empty() or not _res.awaiting.is_empty() or not _dirty.is_empty() \
			or _lod.busy() or not _recheck.is_empty()


func stats() -> Dictionary:
	var promoted := {"asset": _asset[_selected], "rep": _promoted_rep} if _promoted != null else {}
	var out := RenderWorldStats.collect(_cells, _res, {"full_uploads": _retired_full, "partial_uploads": _retired_partial,
		"batch_builds": _builds, "pending_builds": _queue.size(), "world_epoch": _res.epoch,
		"covered_cells": _covered.size(), "lod_evaluations": _lod.evaluated,
		"pooled_nodes": _pool.total + _preview.pool_total()}, promoted)
	_preview.add_stats(out)
	return out


## Fixed-area Texture Preview (spec 11.3). `variants`: low material resource path -> replacement Material,
## shared by every object of one asset. The object leaves its batch slot and shows its current
## representation on a pooled node with per-surface overrides in the same call; the selected object keeps
## its promoted node and gets the overrides there. Returns the ids bound; an id whose group is not built
## yet (or is a placeholder) is not bound and may be offered again.
func begin_preview_owners(entries: Dictionary) -> PackedStringArray:
	return _preview.begin(entries)


func begin_preview_owner(id: String, variants: Dictionary) -> bool:
	return _preview.begin({id: variants}).size() == 1


## Returns the objects to their batch slots (or clears the promoted node's overrides) in one call.
func end_preview_owners(ids: PackedStringArray) -> void:
	_preview.end(ids)


func end_preview_owner(id: String) -> void:
	_preview.end(PackedStringArray([id]))


## Objects with preview bindings (preview nodes and the promoted node), sorted.
func preview_owner_ids() -> PackedStringArray:
	return _preview.ids()


func preview_node(id: String) -> MeshInstance3D:
	return _preview.node_of(id)


## True while the object's 32 m cell is pinned by an active edit.
func is_object_pinned(id: String) -> bool:
	return _cell_of.has(id) and _pinned(_cell_of[id])


func covered_cell_count() -> int:
	return _covered.size()


func cell_role(key: Vector2i) -> String:
	var cell: RenderCell = _cells.get(key)
	return "" if cell == null else cell.role


func cell_wanted_role(key: Vector2i) -> String:
	var cell: RenderCell = _cells.get(key)
	return "" if cell == null else cell.wanted


func _pinned(key: Vector2i) -> bool:
	return _pin_check.is_valid() and bool(_pin_check.call(key))


func _update_focus() -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	var pos := _camera.global_position
	var forward := -_camera.global_transform.basis.z
	_focus = pos + forward * minf(-pos.y / forward.y, 2000.0) if forward.y < -0.05 and pos.y > 0.0 else pos


func _queue_asset(asset_id: String) -> void:
	for key: Vector2i in (_asset_cells.get(asset_id, {}) as Dictionary):
		_queue_cell_asset(_cells[key], asset_id)


func _queue_cell_asset(cell: RenderCell, asset_id: String) -> void:
	var cur: String = cell.reps.get(asset_id, "")
	if cur == "":
		return
	var cand := _res.rep_for(asset_id, cell.role, _priority(cell))
	if _should_switch(cur, cand, cell.role):
		if _pinned(cell.key) and cur != RenderWorldResources.PLACEHOLDER:
			_recheck[cell.key] = true
		else:
			_queue.push(cell.key, asset_id)


## A built group keeps its valid representation until the wanted one is READY (LOD-02).
func _should_switch(cur: String, cand: String, role: String) -> bool:
	if cand == cur:
		return false
	if cur == RenderWorldResources.PLACEHOLDER:
		return true
	return cand == role


## Camera/profile driven role evaluation in bounded chunks, then the role changes that may apply now:
## only after navigation settled, never in pinned cells (EDIT-04; their edits still apply immediately).
func _service_lod() -> void:
	var now := Time.get_ticks_msec()
	_lod.track(_camera, now)
	_lod.step(_cells)
	if not _lod.settled(now):
		return
	for key: Vector2i in _lod.pending.keys():
		var cell: RenderCell = _cells.get(key)
		if cell == null:
			_lod.pending.erase(key)
		elif not _pinned(key):
			_lod.pending.erase(key)
			cell.role = cell.wanted
			_recheck[key] = true
	for key: Vector2i in _recheck.keys():
		var cell: RenderCell = _cells.get(key)
		if cell == null:
			_recheck.erase(key)
		elif not _pinned(key):
			_recheck.erase(key)
			for asset_id: String in cell.members:
				_queue_cell_asset(cell, asset_id)


func _run_queue(t0: int, budget_ms: float) -> int:
	var built := 0
	while not _queue.is_empty():
		if built > 0 and float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			break
		var item := _queue.pop(_focus)
		var cell: RenderCell = _cells.get(item[0])
		if cell == null or not cell.members.has(item[1]):
			continue
		var cur: String = cell.reps.get(item[1], "")
		if cur != "" and cur != RenderWorldResources.PLACEHOLDER and _pinned(cell.key):
			_recheck[cell.key] = true
			continue
		_build_group(cell, item[1])
		built += 1
	if _queue.is_empty():
		_attaching = false
	return built


## Builds or switches one (cell, asset) group atomically: the new batch is complete and uploaded before the
## old one is retired, all within one call.
func _build_group(cell: RenderCell, asset_id: String) -> void:
	_queue.erase(cell.key, asset_id)
	var cur: String = cell.reps.get(asset_id, "")
	if cell.reps.is_empty():
		cell.role = _lod.initial_role(cell)
		cell.wanted = cell.role
	var rep := _res.rep_for(asset_id, cell.role, _priority(cell))
	if cur != "" and not _should_switch(cur, rep, cell.role):
		return
	var ids: Array[String] = []
	for id: String in (cell.members[asset_id] as Dictionary):
		if _owner[id] != "promoted" and _owner[id] != ObjectPreviewOwners.OWNER:
			ids.append(id)
	if ids.is_empty():
		if _preview.retarget(cell, asset_id, rep):
			cell.reps[asset_id] = rep
		return
	var batch := _batch_for(cell, asset_id, rep)
	if batch == null:
		return
	var aabb := _res.render_aabb(asset_id, rep)
	var key := "%s|%s" % [asset_id, rep]
	for id in ids:
		batch.add(id, _inst_xf(id, rep), aabb)
		_owner[id] = key
	batch.flush()
	batch.node.visible = _batch_visible(batch)
	_dirty.erase(batch)
	if cur != "":
		_retire_batch(cell, "%s|%s" % [asset_id, cur])
	cell.reps[asset_id] = rep
	_preview.retarget(cell, asset_id, rep)


func _report_placeholders() -> void:
	if _attaching or _notice_sent:
		return
	var text := RenderWorldStats.placeholder_notice(_cells, _asset_cells, _res)
	if text != "":
		_notice_sent = true
		placeholders_reported.emit(text)
