class_name ObjectPreviewOwners
extends RefCounted
## Texture Preview bindings of ObjectRenderWorld (spec 11.3). A bound object is drawn by a pooled MeshInstance3D
## with per-surface override materials instead of its batch slot, or, when selected, by the promoted node with
## the same overrides. Owner value "preview" in ObjectBatchStore._owner; never promotes geometry: the node shows
## the cell's current representation (retarget() follows LOD role changes). The override materials are shared
## variants created by the caller; shared low-tier materials and meshes are never modified.
## `_variants[id]` exists exactly while the object is bound (preview node or promoted node).

const OWNER := "preview"
const POOL_MAX := 160

var _store: ObjectBatchStore
var _pool: PromotedNodePool
var _nodes: Dictionary = {}  # id -> MeshInstance3D, only for owner "preview"
var _variants: Dictionary = {}  # id -> Dictionary(low material resource path -> Material)


func _init(store: ObjectBatchStore) -> void:
	_store = store
	_pool = PromotedNodePool.new(store, POOL_MAX, "preview")


func ids() -> PackedStringArray:
	var out := PackedStringArray(_variants.keys())
	out.sort()
	return out


func node_of(id: String) -> MeshInstance3D:
	return _nodes.get(id)


func pool_total() -> int:
	return _pool.total


## Binds every entry (id -> variants) it can and flushes the touched batches once, so no frame sees an object
## twice or not at all. Returns the ids bound.
func begin(entries: Dictionary) -> PackedStringArray:
	var done := PackedStringArray()
	for id: String in entries:
		if _begin_one(id, entries[id] as Dictionary):
			done.append(id)
	_store._flush_dirty()
	return done


func end(id_list: PackedStringArray) -> void:
	for id in id_list:
		_end_one(id)
	if _nodes.is_empty():
		_pool.free_idle()
	_store._flush_dirty()


## Selected object deselected: it is batch-owned again and returns to its preview node when it is still bound.
func restore(id: String) -> void:
	if not _variants.has(id):
		return
	var variants: Dictionary = _variants[id]
	_variants.erase(id)
	_begin_one(id, variants)
	_store._flush_dirty()


## Drops the binding of a removed or re-created object.
func forget(id: String) -> void:
	_variants.erase(id)
	release_node(id)


## Returns the preview node to the pool but keeps the binding (the object is being promoted).
func release_node(id: String) -> void:
	if _nodes.has(id):
		_pool.release(_nodes[id])
		_nodes.erase(id)


func clear() -> void:
	for id: String in _nodes.keys():
		release_node(id)
	_variants.clear()
	_pool.free_idle()


func update_transform(id: String) -> void:
	var rep := _rep_of(id)
	(_nodes[id] as MeshInstance3D).transform = _store._inst_xf(id, rep)


## The cell's representation of an asset changed: bound preview nodes show the new mesh. True if any did.
func retarget(cell: RenderCell, asset_id: String, rep: String) -> bool:
	var any := false
	for id: String in (cell.members.get(asset_id, {}) as Dictionary):
		if _nodes.has(id):
			_show(id, rep)
			any = true
	return any


## Sets the override of every surface of `node`'s mesh whose low material has a variant for object `id`.
func apply(node: MeshInstance3D, id: String) -> void:
	var mesh := node.mesh
	if mesh == null:
		return
	var variants: Dictionary = _variants.get(id, {})
	for s in mesh.get_surface_count():
		var low := mesh.surface_get_material(s)
		var variant: Material = null
		if low != null and variants.has(low.resource_path):
			variant = variants[low.resource_path]
		node.set_surface_override_material(s, variant)


## Preview nodes follow the same visibility as batches: hidden when an overview covers the cell or the
## vegetation is hidden.
func refresh_visibility() -> void:
	for id: String in _nodes:
		(_nodes[id] as MeshInstance3D).visible = _visible(id)


func add_stats(out: Dictionary) -> void:
	for id: String in _nodes:
		var rep := _rep_of(id)
		var tri := _store._res.triangles(_store._asset[id], rep)
		out.instances += 1
		out.estimated_triangles += tri
		if (_nodes[id] as MeshInstance3D).visible:
			out.visible_instances += 1
			out.visible_triangles += tri
	out["preview_nodes"] = _nodes.size()


func _begin_one(id: String, variants: Dictionary) -> bool:
	var owner := _store.owner_of(id)
	if owner == "":
		return false
	if owner == "promoted":
		_variants[id] = variants
		apply(_store._promoted, id)
		return true
	if owner == OWNER:
		_variants[id] = variants
		_show(id, _rep_of(id))
		return true
	var rep: String = owner.rsplit("|", true, 1)[1]
	if rep == RenderWorldResources.PLACEHOLDER:
		return false
	var node := _pool.acquire()
	if node == null:
		return false
	_store._leave_batch(id)
	_variants[id] = variants
	_nodes[id] = node
	_store._owner[id] = OWNER
	_show(id, rep)
	return true


func _end_one(id: String) -> void:
	if not _variants.has(id):
		return
	_variants.erase(id)
	var owner := _store.owner_of(id)
	if owner == OWNER:
		release_node(id)
		_store._owner[id] = ""
		_store._attach_owner(id)
	elif owner == "promoted":
		apply(_store._promoted, id)


func _show(id: String, rep: String) -> void:
	var node: MeshInstance3D = _nodes[id]
	node.mesh = _store._res.mesh_of(_store._asset[id], rep)
	node.transform = _store._inst_xf(id, rep)
	node.visible = _visible(id)
	apply(node, id)


func _visible(id: String) -> bool:
	return _store.is_object_visible(id)


func _rep_of(id: String) -> String:
	if _store._size_policy_enabled:
		return _store._size_visibility.rep_of(id)
	var cell: RenderCell = _store._cells[_store._cell_of[id]]
	return cell.reps.get(_store._asset[id], RenderWorldResources.PLACEHOLDER)


func retarget_object(id: String, rep: String) -> void:
	if _nodes.has(id):
		_show(id, rep)
