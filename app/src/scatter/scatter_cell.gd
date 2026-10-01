class_name ScatterCell
extends RefCounted
## Bucketed scatter data of one render cell plus its built state. Lists hold copies of the instance data
## (layer indices shift on removal, copies do not), grouped per asset in layer order:
## xz = (x, z) pairs, attr = (yaw, scale, flags) triples.

const DECORATIVE := 0
const MEANINGFUL := 1

var key: Vector2i
var kind: int
var xz := {}  # asset_id -> PackedFloat32Array
var attr := {}  # asset_id -> PackedFloat32Array
var keys := {}  # asset_id -> PackedInt64Array thinning keys (lazy cache, see ScatterDensity)
var batches := {}  # asset_id -> ScatterBatch
var role := ""  # meaningful cells: current individual role
var density := -1.0  # decorative cells: density of the current batches
var wanted := false  # decorative cells: inside the ground-cover band
var built := false
var drawn := 0  # instances in the batches (after thinning)
var total := 0  # instances bucketed here
var y_ref := NAN  # ground height at the cell centre, for distance estimates


func _init(key_: Vector2i, kind_: int) -> void:
	key = key_
	kind = kind_


func count() -> int:
	var n := 0
	for list: PackedFloat32Array in xz.values():
		n += list.size() / 2
	return n


func add(asset_id: String, x: float, z: float, yaw: float, scale_value: float, flags: int) -> void:
	var p: PackedFloat32Array = xz.get(asset_id, PackedFloat32Array())
	p.append(x)
	p.append(z)
	xz[asset_id] = p
	var a: PackedFloat32Array = attr.get(asset_id, PackedFloat32Array())
	a.append(yaw)
	a.append(scale_value)
	a.append(float(flags))
	attr[asset_id] = a


func same_data(other: ScatterCell) -> bool:
	if xz.size() != other.xz.size():
		return false
	for asset_id: String in xz:
		if not other.xz.has(asset_id) or xz[asset_id] != other.xz[asset_id] or attr[asset_id] != other.attr[asset_id]:
			return false
	return true


func take(other: ScatterCell) -> void:
	xz = other.xz
	attr = other.attr
	keys = {}
