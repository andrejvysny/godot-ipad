class_name InstanceBatch
extends RefCounted
## One MultiMeshInstance3D of identical instances inside one render cell (spec §7.2-§7.4).
## The node sits at the cell origin; stored transforms are cell-local (world minus `origin`), so float32
## precision does not depend on the distance from the world origin. CPU arrays are the source of truth
## and are never read back from the GPU. Active slots are the dense prefix [0, count); inactive
## capacity is never drawn (visible_instance_count == count). Buffer layout per instance (12 floats):
## three rows of (basis row, origin component), like ScatterRenderer.

const FLOATS := 12
const MIN_CAPACITY := 16
const PARTIAL_LIMIT := 32

var node: MultiMeshInstance3D
var origin: Vector3
var ids := PackedStringArray()  # slot -> id
var slot_of: Dictionary = {}  # id -> slot
var xforms := PackedFloat32Array()  # capacity * FLOATS, cell-local
var count: int = 0
var capacity: int = 0
var full_uploads: int = 0
var partial_uploads: int = 0
var custom_aabb := AABB()  # cell-local, conservative
var mesh_aabb := AABB()  # union of the render AABBs (mesh space) passed to add/update

var _mm := MultiMesh.new()
var _dirty: Dictionary = {}  # slot -> true
var _realloc: bool = false
var _all_dirty: bool = false
var _has_bounds: bool = false
var _count_at_recompute: int = 0
var _shrink_due: bool = false


func _init(cell_origin: Vector3, mesh: Mesh) -> void:
	origin = cell_origin
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = mesh
	node = MultiMeshInstance3D.new()
	node.multimesh = _mm
	node.position = origin
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func multimesh() -> MultiMesh:
	return _mm


func has(id: String) -> bool:
	return slot_of.has(id)


func add(id: String, world_xf: Transform3D, render_aabb: AABB) -> int:
	if slot_of.has(id):
		update(id, world_xf, render_aabb)
		return slot_of[id]
	if count + 1 > capacity:
		_grow(count + 1)
	var slot := count
	count += 1
	_count_at_recompute = maxi(_count_at_recompute, count)
	ids[slot] = id
	slot_of[id] = slot
	_write(slot, world_xf, render_aabb)
	return slot


## Swap-removal: the last active slot moves into the hole.
func remove(id: String) -> bool:
	if not slot_of.has(id):
		return false
	var slot: int = slot_of[id]
	var last := count - 1
	if slot != last:
		var moved := ids[last]
		ids[slot] = moved
		slot_of[moved] = slot
		for k in FLOATS:
			xforms[slot * FLOATS + k] = xforms[last * FLOATS + k]
		_dirty[slot] = true
	ids[last] = ""
	slot_of.erase(id)
	count = last
	_dirty.erase(last)
	if count * 2 < _count_at_recompute:
		_shrink_due = true
	return true


func update(id: String, world_xf: Transform3D, render_aabb: AABB) -> void:
	if slot_of.has(id):
		_write(slot_of[id], world_xf, render_aabb)


func is_dirty() -> bool:
	return _realloc or _all_dirty or not _dirty.is_empty() or _shrink_due


## Uploads pending CPU changes. Few dirty slots use per-slot setters, otherwise one full buffer assignment.
func flush() -> void:
	if _shrink_due:
		_recompute_bounds()
	if _realloc:
		_mm.instance_count = capacity  # clears GPU data: the whole buffer follows
		_realloc = false
		_all_dirty = true
	if _all_dirty or _dirty.size() > PARTIAL_LIMIT:
		if capacity > 0:
			_mm.buffer = xforms
			full_uploads += 1
	elif not _dirty.is_empty():
		for slot: int in _dirty:
			if slot < count:
				_mm.set_instance_transform(slot, _read(slot))
		partial_uploads += 1
	_dirty.clear()
	_all_dirty = false
	_mm.visible_instance_count = count


## Cell-local AABB moved to world space.
func world_aabb() -> AABB:
	return AABB(custom_aabb.position + origin, custom_aabb.size)


func local_transform(slot: int) -> Transform3D:
	return _read(slot)


func _grow(needed: int) -> void:
	var cap := maxi(MIN_CAPACITY, capacity)
	while cap < needed:
		cap *= 2
	capacity = cap
	ids.resize(cap)
	xforms.resize(cap * FLOATS)
	_realloc = true


func _write(slot: int, world_xf: Transform3D, render_aabb: AABB) -> void:
	var b := world_xf.basis
	var o := world_xf.origin - origin
	var i := slot * FLOATS
	xforms[i] = b.x.x
	xforms[i + 1] = b.y.x
	xforms[i + 2] = b.z.x
	xforms[i + 3] = o.x
	xforms[i + 4] = b.x.y
	xforms[i + 5] = b.y.y
	xforms[i + 6] = b.z.y
	xforms[i + 7] = o.y
	xforms[i + 8] = b.x.z
	xforms[i + 9] = b.y.z
	xforms[i + 10] = b.z.z
	xforms[i + 11] = o.z
	_dirty[slot] = true
	_grow_bounds(Transform3D(b, o), render_aabb)


func _read(slot: int) -> Transform3D:
	var i := slot * FLOATS
	var basis := Basis(Vector3(xforms[i], xforms[i + 4], xforms[i + 8]),
			Vector3(xforms[i + 1], xforms[i + 5], xforms[i + 9]),
			Vector3(xforms[i + 2], xforms[i + 6], xforms[i + 10]))
	return Transform3D(basis, Vector3(xforms[i + 3], xforms[i + 7], xforms[i + 11]))


func _grow_bounds(local_xf: Transform3D, render_aabb: AABB) -> void:
	mesh_aabb = render_aabb if not _has_bounds else mesh_aabb.merge(render_aabb)
	var box := local_xf * render_aabb
	var grown := box if not _has_bounds else custom_aabb.merge(box)
	_has_bounds = true
	if grown != custom_aabb:
		custom_aabb = grown
		_mm.custom_aabb = grown


## Shrinks the bounds to the active members; undersized bounds are never left behind (§7.4).
func _recompute_bounds() -> void:
	_shrink_due = false
	_count_at_recompute = count
	if count == 0:
		return
	var box := _read(0) * mesh_aabb
	for slot in range(1, count):
		box = box.merge(_read(slot) * mesh_aabb)
	custom_aabb = box
	_mm.custom_aabb = box
