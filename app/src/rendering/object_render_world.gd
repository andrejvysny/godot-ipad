class_name ObjectRenderWorld
extends Node3D
## Draws presented object records through per-(cell, asset, representation) MultiMesh batches (spec §5, §7,
## §8.3). Every presented record has exactly one visible owner: a batch slot or the promoted selected-object
## node (`_owner[id]`: "" = still queued, "promoted", or the batch key "<asset>|<rep>" inside the record's
## cell). Cells are floor(world XZ / cell_size) of the applied transform's origin; batch nodes sit at the
## cell origin and hold cell-local transforms.
## Work is split: CPU state and removals/updates of existing slots are applied immediately and flushed in
## the next service_frame regardless of budget; building batches for a newly attached world (clear() then
## upserts) is scheduled, nearest cells first, within the frame budget.

signal placeholders_reported(text: String)

const POOL_MAX := 4
const SELECTED_ROLE := "selected"
const DEFER_RECHECK_MS := 100
const NEAR_PRIORITY_M := 96.0

var _res: RenderWorldResources
var _catalog: AssetCatalog
var _cell_size: float = 32.0
var _is_hidden := Callable()
var _pin_check := Callable()
var _camera: Camera3D
var _role: String = "mid"
var _asset: Dictionary = {}  # id -> asset_id
var _xf: Dictionary = {}  # id -> applied world Transform3D
var _cell_of: Dictionary = {}  # id -> Vector2i
var _owner: Dictionary = {}
var _cells: Dictionary = {}  # Vector2i -> RenderCell
var _asset_cells: Dictionary = {}  # asset_id -> Dictionary(Vector2i -> true)
var _wanted: Dictionary = {}  # asset_id -> true once its meshes were requested this epoch
var _queue: RenderWorkQueue
var _dirty: Dictionary = {}  # InstanceBatch -> true
var _attaching: bool = false
var _role_dirty: bool = false
var _role_deferred: bool = false
var _defer_check_ms: int = 0
var _focus := Vector3.ZERO
var _selected: String = ""
var _promoted: MeshInstance3D
var _promoted_rep: String = ""
var _pool: PromotedNodePool
var _notice_sent: bool = false
var _retired_full: int = 0
var _retired_partial: int = 0
var _builds: int = 0


func setup(registry: RenderAssetRegistry, cache: RenderAssetCache, cell_size_m: float, is_hidden: Callable,
		catalog: AssetCatalog = null) -> void:
	_res = RenderWorldResources.new(registry, cache)
	_cell_size = maxf(cell_size_m, 1.0)
	_is_hidden = is_hidden
	_catalog = catalog
	_queue = RenderWorkQueue.new(_cell_size)
	_pool = PromotedNodePool.new(self, POOL_MAX)
	_attaching = true


func set_camera(camera: Camera3D) -> void:
	_camera = camera


func set_pin_check(check: Callable) -> void:
	_pin_check = check


func set_default_role(role: String) -> void:
	if role != _role:
		_role = role
		_role_dirty = true


func world_epoch() -> int:
	return _res.epoch


## World replacement: epoch + 1, outstanding cache work of the old epoch cancelled, every node released.
func clear() -> void:
	for cell: RenderCell in _cells.values():
		for key: String in cell.batches.keys():
			_retire_batch(cell, key)
	_release_promoted()
	_selected = ""
	for dict: Dictionary in [_asset, _xf, _cell_of, _owner, _cells, _asset_cells, _wanted, _dirty]:
		dict.clear()
	_queue.clear()
	_res.next_epoch()
	_attaching = true
	_notice_sent = false
	_role_dirty = false
	_role_deferred = false


func upsert(id: String, asset_id: String, world_xf: Transform3D) -> void:
	var key := _cell_key(world_xf.origin)
	if _asset.has(id):
		if _asset[id] == asset_id and _cell_of[id] == key:
			_xf[id] = world_xf
			_apply_transform(id)
			return
		_detach(id, id == _selected and _asset[id] == asset_id)
	_asset[id] = asset_id
	_xf[id] = world_xf
	_cell_of[id] = key
	if not _owner.has(id):
		_owner[id] = ""
	var cell := _cell(key)
	if not cell.members.has(asset_id):
		cell.members[asset_id] = {}
	(cell.members[asset_id] as Dictionary)[id] = true
	if not _asset_cells.has(asset_id):
		_asset_cells[asset_id] = {}
	(_asset_cells[asset_id] as Dictionary)[key] = true
	if not _wanted.has(asset_id):
		_wanted[asset_id] = true
		_res.rep_for(asset_id, _role, 2)
	if id == _selected:
		if _owner[id] != "promoted":
			_promote(id)
		else:
			_apply_transform(id)
	else:
		_attach_owner(id)


func remove(id: String) -> void:
	if not _asset.has(id):
		return
	_detach(id, false)
	for dict: Dictionary in [_asset, _xf, _cell_of, _owner]:
		dict.erase(id)
	if id == _selected:
		_selected = ""


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
	if want != "":
		_promote(want)
	_flush_dirty()


func set_vegetation_visibility_changed() -> void:
	for cell: RenderCell in _cells.values():
		for batch: InstanceBatch in cell.batches.values():
			batch.node.visible = not _batch_hidden(batch)
	if _promoted != null:
		_promoted.visible = not _hidden(_selected)


## Applies pending slot updates, then builds queued groups until `budget_ms` is spent (at least one).
func service_frame(budget_ms: float) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	_update_focus()
	_flush_dirty()
	for asset_id in _res.poll_ready():
		_queue_asset(asset_id)
	_service_role_change()
	_upgrade_promoted()
	var built := _run_queue(t0, budget_ms)
	_report_placeholders()
	return {"built": built, "pending": _queue.size()}


func has_pending_work() -> bool:
	return not _queue.is_empty() or not _res.awaiting.is_empty() or not _dirty.is_empty() \
			or _role_dirty or _role_deferred


func stats() -> Dictionary:
	var promoted := {"asset": _asset[_selected], "rep": _promoted_rep} if _promoted != null else {}
	return RenderWorldStats.collect(_cells, _res, {"full_uploads": _retired_full, "partial_uploads": _retired_partial,
		"batch_builds": _builds, "pending_builds": _queue.size(), "world_epoch": _res.epoch,
		"pooled_nodes": _pool.total}, promoted)


func owner_of(id: String) -> String:
	return _owner.get(id, "")


func batch_of(id: String) -> InstanceBatch:
	var owner := owner_of(id)
	if owner == "" or owner == "promoted":
		return null
	return (_cells[_cell_of[id]] as RenderCell).batches.get(owner)


func promoted_node() -> MeshInstance3D:
	return _promoted


func promoted_rep() -> String:
	return _promoted_rep


func _cell_key(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / _cell_size), floori(p.z / _cell_size))


func _cell(key: Vector2i) -> RenderCell:
	if not _cells.has(key):
		var cell := RenderCell.new()
		cell.key = key
		cell.origin = Vector3(key.x * _cell_size, 0.0, key.y * _cell_size)
		_cells[key] = cell
	return _cells[key]


## Instance transform of `id` for a representation; the placeholder box is fitted to the catalog bounds.
func _inst_xf(id: String, rep: String) -> Transform3D:
	var xf: Transform3D = _xf[id]
	if rep != RenderWorldResources.PLACEHOLDER:
		return xf
	var b := _bounds(_asset[id])
	return xf * Transform3D(Basis.from_scale(b.size), b.get_center())


func _bounds(asset_id: String) -> AABB:
	var asset := _catalog.get_asset(asset_id) if _catalog != null else null
	return asset.bounds if asset != null else RenderWorldResources.UNIT_BOX


## Adds an unowned record to its group: immediately when the group exists or the world is settled.
func _attach_owner(id: String) -> void:
	var cell: RenderCell = _cells[_cell_of[id]]
	var asset_id: String = _asset[id]
	if cell.reps.has(asset_id):
		_batch_add(cell, id, cell.reps[asset_id])
	elif _attaching:
		_queue.push(cell.key, asset_id)
	else:
		_build_group(cell, asset_id)


func _batch_add(cell: RenderCell, id: String, rep: String) -> void:
	var asset_id: String = _asset[id]
	var batch := _batch_for(cell, asset_id, rep)
	if batch == null:
		return
	batch.add(id, _inst_xf(id, rep), _res.render_aabb(asset_id, rep))
	_owner[id] = "%s|%s" % [asset_id, rep]
	_dirty[batch] = true


func _batch_for(cell: RenderCell, asset_id: String, rep: String) -> InstanceBatch:
	var key := "%s|%s" % [asset_id, rep]
	if cell.batches.has(key):
		return cell.batches[key]
	var mesh := _res.mesh_of(asset_id, rep, _priority(cell))
	if mesh == null:
		return null
	var batch := InstanceBatch.new(cell.origin, mesh)
	batch.node.name = "batch_%d_%d_%s" % [cell.key.x, cell.key.y, key.replace("|", "_")]
	add_child(batch.node)
	cell.batches[key] = batch
	_builds += 1
	return batch


func _apply_transform(id: String) -> void:
	var owner := owner_of(id)
	if owner == "promoted":
		_promoted.transform = _inst_xf(id, _promoted_rep)
	elif owner != "":
		var cell: RenderCell = _cells[_cell_of[id]]
		var parts := owner.rsplit("|", true, 1)
		var batch: InstanceBatch = cell.batches[owner]
		batch.update(id, _inst_xf(id, parts[1]), _res.render_aabb(parts[0], parts[1]))
		_dirty[batch] = true


## Takes `id` out of its batch (or promoted node unless `keep_promoted`) and out of its group membership.
func _detach(id: String, keep_promoted: bool) -> void:
	var cell: RenderCell = _cells[_cell_of[id]]
	var asset_id: String = _asset[id]
	var owner := owner_of(id)
	if owner == "promoted":
		if keep_promoted:
			_drop_membership(cell, id, asset_id)
			return
		_release_promoted()
	elif owner != "":
		var batch: InstanceBatch = cell.batches[owner]
		batch.remove(id)
		_dirty[batch] = true
		if batch.count == 0:
			_retire_batch(cell, owner)
	_owner[id] = ""
	_drop_membership(cell, id, asset_id)


func _drop_membership(cell: RenderCell, id: String, asset_id: String) -> void:
	var group: Dictionary = cell.members[asset_id]
	group.erase(id)
	if group.is_empty():
		_drop_group(cell, asset_id)


func _drop_group(cell: RenderCell, asset_id: String) -> void:
	for key: String in cell.batches.keys():
		if key.begins_with(asset_id + "|"):
			_retire_batch(cell, key)
	cell.members.erase(asset_id)
	cell.reps.erase(asset_id)
	_queue.erase(cell.key, asset_id)
	var cells: Dictionary = _asset_cells[asset_id]
	cells.erase(cell.key)
	if cells.is_empty():
		_asset_cells.erase(asset_id)
		_wanted.erase(asset_id)
	if cell.members.is_empty():
		_cells.erase(cell.key)


func _retire_batch(cell: RenderCell, key: String) -> void:
	var batch: InstanceBatch = cell.batches[key]
	_retired_full += batch.full_uploads
	_retired_partial += batch.partial_uploads
	_dirty.erase(batch)
	cell.batches.erase(key)
	remove_child(batch.node)
	batch.node.free()


func _promote(id: String) -> void:
	var cell: RenderCell = _cells[_cell_of[id]]
	var owner := owner_of(id)
	if owner != "" and owner != "promoted":
		var batch: InstanceBatch = cell.batches[owner]
		batch.remove(id)
		_dirty[batch] = true
		if batch.count == 0:
			_retire_batch(cell, owner)
	var asset_id: String = _asset[id]
	var rep := SELECTED_ROLE if _res.mesh(asset_id, SELECTED_ROLE, 0) != null \
			else _res.rep_for(asset_id, _role, 0)
	if _promoted == null:
		_promoted = _pool.acquire()
	_promoted.mesh = _res.mesh_of(asset_id, rep, 0)
	_promoted_rep = rep
	_promoted.transform = _inst_xf(id, rep)
	_promoted.visible = not _hidden(id)
	_owner[id] = "promoted"


func _release_promoted() -> void:
	if _promoted != null:
		_pool.release(_promoted)
		_promoted = null
		_promoted_rep = ""


func _upgrade_promoted() -> void:
	if _promoted == null or _promoted_rep == SELECTED_ROLE:
		return
	var mesh := _res.mesh(_asset[_selected], SELECTED_ROLE, 0)
	if mesh != null:
		_promoted.mesh = mesh
		_promoted_rep = SELECTED_ROLE
		_promoted.transform = _inst_xf(_selected, SELECTED_ROLE)


func _hidden(id: String) -> bool:
	return _is_hidden.is_valid() and bool(_is_hidden.call(id))


func _batch_hidden(batch: InstanceBatch) -> bool:
	return batch.count > 0 and _hidden(batch.ids[0])


func _pinned(key: Vector2i) -> bool:
	return _pin_check.is_valid() and bool(_pin_check.call(key))


func _priority(cell: RenderCell) -> int:
	var center := cell.origin + Vector3(_cell_size, 0.0, _cell_size) * 0.5
	return 1 if Vector2(center.x - _focus.x, center.z - _focus.z).length() <= NEAR_PRIORITY_M else 2


func _update_focus() -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	var pos := _camera.global_position
	var forward := -_camera.global_transform.basis.z
	_focus = pos + forward * minf(-pos.y / forward.y, 2000.0) if forward.y < -0.05 and pos.y > 0.0 else pos


func _flush_dirty() -> void:
	for batch: InstanceBatch in _dirty.keys():
		batch.flush()
		batch.node.visible = not _batch_hidden(batch)
	_dirty.clear()


func _queue_asset(asset_id: String) -> void:
	for key: Vector2i in (_asset_cells.get(asset_id, {}) as Dictionary):
		var cell: RenderCell = _cells[key]
		var cur: String = cell.reps.get(asset_id, "")
		if cur == "":
			continue
		var cand := _res.rep_for(asset_id, _role, _priority(cell))
		if _should_switch(cur, cand):
			if _pinned(key) and cur != RenderWorldResources.PLACEHOLDER:
				_role_deferred = true
			else:
				_queue.push(key, asset_id)


## A built group keeps its valid representation until the wanted one is READY (LOD-02).
func _should_switch(cur: String, cand: String) -> bool:
	if cand == cur:
		return false
	if cur == RenderWorldResources.PLACEHOLDER:
		return true
	return cand == _role


func _service_role_change() -> void:
	var now := Time.get_ticks_msec()
	if _role_dirty or (_role_deferred and now - _defer_check_ms >= DEFER_RECHECK_MS):
		_role_dirty = false
		_role_deferred = false
		_defer_check_ms = now
		for asset_id: String in _asset_cells.keys():
			_res.rep_for(asset_id, _role, 2)
			_queue_asset(asset_id)


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
			_role_deferred = true
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
	var rep := _res.rep_for(asset_id, _role, _priority(cell))
	if cur != "" and not _should_switch(cur, rep):
		return
	var ids: Array[String] = []
	for id: String in (cell.members[asset_id] as Dictionary):
		if _owner[id] != "promoted":
			ids.append(id)
	if ids.is_empty():
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
	batch.node.visible = not _batch_hidden(batch)
	_dirty.erase(batch)
	if cur != "":
		_retire_batch(cell, "%s|%s" % [asset_id, cur])
	cell.reps[asset_id] = rep


func _report_placeholders() -> void:
	if _attaching or _notice_sent:
		return
	var text := RenderWorldStats.placeholder_notice(_cells, _asset_cells, _res)
	if text != "":
		_notice_sent = true
		placeholders_reported.emit(text)
