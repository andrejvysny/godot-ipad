class_name ObjectBatchStore
extends Node3D
## Ownership layer of ObjectRenderWorld (spec §5, §7, §8.3): per-(cell, asset, representation) MultiMesh
## batches. Every presented record has exactly one visible owner: a batch slot or the promoted selected-object
## node (`_owner[id]`: "" = still queued, "promoted", or the batch key "<asset>|<rep>" inside the record's
## cell). Cells are floor(world XZ / cell_size) of the applied transform's origin; batch nodes sit at the
## cell origin and hold cell-local transforms. A batch is drawn only when its cell is not covered by an
## overview group and vegetation is not hidden. Scheduling, LOD and the public API live in ObjectRenderWorld.

## Meaningful (non-decorative) instances were added, removed, moved or re-grounded inside `rect` (world XZ);
## the overview groups overlapping it must rebuild. clear() reports an unbounded rect.
signal overview_changed(rect: Rect2)

const POOL_MAX := 4
const SELECTED_ROLE := "selected"
const NEAR_PRIORITY_M := 96.0
const EVERYTHING := Rect2(-1.0e7, -1.0e7, 2.0e7, 2.0e7)

var _res: RenderWorldResources
var _catalog: AssetCatalog
var _cell_size: float = 32.0
var _is_hidden := Callable()
var _covered: Dictionary = {}  # Vector2i -> true: cells whose batches an overview group draws instead
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
var _focus := Vector3.ZERO
var _selected: String = ""
var _promoted: MeshInstance3D
var _promoted_rep: String = ""
var _pool: PromotedNodePool
var _retired_full: int = 0
var _retired_partial: int = 0
var _builds: int = 0


## Meaningful instances whose origin lies in `rect` (half-open, world XZ): [{"asset_id": String, "xf": Transform3D}].
func overview_members(rect: Rect2) -> Array:
	var out: Array = []
	var lo := Vector2i(floori(rect.position.x / _cell_size), floori(rect.position.y / _cell_size))
	var hi := Vector2i(ceili(rect.end.x / _cell_size) - 1, ceili(rect.end.y / _cell_size) - 1)
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var cell: RenderCell = _cells.get(Vector2i(cx, cz))
			if cell == null:
				continue
			for asset_id: String in cell.members:
				for id: String in (cell.members[asset_id] as Dictionary):
					var xf: Transform3D = _xf[id]
					if rect.has_point(Vector2(xf.origin.x, xf.origin.z)):
						out.append({"asset_id": asset_id, "xf": xf})
	return out


## Hides (covered) or shows the individual batches of every cell whose rect lies inside `rect`. Covered
## batches stay built; independent of the LOD role and of vegetation hiding.
func set_cells_covered(rect: Rect2, covered: bool) -> void:
	var lo := Vector2i(ceili(rect.position.x / _cell_size), ceili(rect.position.y / _cell_size))
	var hi := Vector2i(floori(rect.end.x / _cell_size) - 1, floori(rect.end.y / _cell_size) - 1)
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var key := Vector2i(cx, cz)
			if covered:
				_covered[key] = true
			else:
				_covered.erase(key)
			var cell: RenderCell = _cells.get(key)
			if cell != null:
				for batch: InstanceBatch in cell.batches.values():
					batch.node.visible = _batch_visible(batch)


func is_object_covered(id: String) -> bool:
	return _cell_of.has(id) and _covered.has(_cell_of[id])


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


func _emit_changed(key: Vector2i) -> void:
	overview_changed.emit(Rect2(Vector2(key) * _cell_size, Vector2(_cell_size, _cell_size)))


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
			else _res.rep_for(asset_id, cell.role, 0)
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


## A batch is drawn only when no overview group covers its cell and vegetation is not hidden.
func _batch_visible(batch: InstanceBatch) -> bool:
	return not _covered.has(_cell_key(batch.origin)) and not _batch_hidden(batch)


func _flush_dirty() -> void:
	for batch: InstanceBatch in _dirty.keys():
		batch.flush()
		batch.node.visible = _batch_visible(batch)
	_dirty.clear()


func _priority(cell: RenderCell) -> int:
	var center := cell.origin + Vector3(_cell_size, 0.0, _cell_size) * 0.5
	return 1 if Vector2(center.x - _focus.x, center.z - _focus.z).length() <= NEAR_PRIORITY_M else 2


## Implemented by ObjectRenderWorld: builds or switches one (cell, asset) group.
func _build_group(_cell: RenderCell, _asset_id: String) -> void:
	pass
