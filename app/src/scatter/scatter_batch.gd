class_name ScatterBatch
extends RefCounted
## One MultiMeshInstance3D of the scatter instances of one (cell, asset) at one representation. The node
## sits at the cell origin and the buffer is cell-local (float32 precision does not depend on the distance
## from the world origin). The whole buffer is replaced when it changes (a scatter cell holds few instances,
## and instance identity is not needed: rebuilding a dirty cell is cheaper than tracking slots); an identical
## buffer is never uploaded again. Never casts shadows.

var node: MultiMeshInstance3D
var rep := ""
var count := 0
var origin: Vector3
var buffer := PackedFloat32Array()  # count * 12 floats: three rows of (basis row, origin component)

var _mm := MultiMesh.new()


func _init(cell_origin: Vector3) -> void:
	origin = cell_origin
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	node = MultiMeshInstance3D.new()
	node.multimesh = _mm
	node.position = origin
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func multimesh() -> MultiMesh:
	return _mm


## True when the buffer was uploaded.
func apply(new_buffer: PackedFloat32Array, new_count: int, local_aabb: AABB, mesh: Mesh) -> bool:
	if _mm.mesh != mesh:
		_mm.mesh = mesh
	_mm.custom_aabb = local_aabb
	if new_count == count and new_buffer == buffer:
		return false
	if new_count != _mm.instance_count:
		_mm.instance_count = new_count  # clears the GPU data: the whole buffer follows
	_mm.buffer = new_buffer
	buffer = new_buffer
	count = new_count
	return true


func local_transform(k: int) -> Transform3D:
	var o := k * 12
	var b := buffer
	return Transform3D(Basis(Vector3(b[o], b[o + 4], b[o + 8]), Vector3(b[o + 1], b[o + 5], b[o + 9]),
			Vector3(b[o + 2], b[o + 6], b[o + 10])), Vector3(b[o + 3], b[o + 7], b[o + 11]))


func free_node() -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()
