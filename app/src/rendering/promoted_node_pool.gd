class_name PromotedNodePool
extends RefCounted
## At most `limit` reusable MeshInstance3D nodes for promoted (selected) objects (spec §8.3). Nodes are created
## lazily, parented to `host`, never cast shadows and are hidden with their mesh dropped while pooled.

var total: int = 0

var _host: Node3D
var _limit: int
var _free: Array[MeshInstance3D] = []


func _init(host: Node3D, limit: int) -> void:
	_host = host
	_limit = limit


## Null when `limit` nodes are already in use.
func acquire() -> MeshInstance3D:
	if not _free.is_empty():
		return _free.pop_back()
	if total >= _limit:
		return null
	var node := MeshInstance3D.new()
	node.name = "promoted_%d" % total
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_host.add_child(node)
	total += 1
	return node


func release(node: MeshInstance3D) -> void:
	node.mesh = null
	node.visible = false
	_free.append(node)
