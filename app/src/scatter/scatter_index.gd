class_name ScatterIndex
extends RefCounted
## Spatial hash (2 m cells) over a ScatterLayer for spacing tests and brush queries. The index
## stores layer instance indices; removal goes through remove_indices() because the layer
## compacts its arrays and shifts every later index (the hash is then rebuilt, O(n)).

const CELL_M := 2.0

var _layer: ScatterLayer
var _cells := {}  # Vector2i -> PackedInt32Array of layer indices


func _init(layer: ScatterLayer) -> void:
	_layer = layer
	rebuild()


func layer() -> ScatterLayer:
	return _layer


func rebuild() -> void:
	_cells = {}
	for i in _layer.count():
		_register(i)


## Registers the instance most recently appended to the layer.
func add_last() -> void:
	_register(_layer.count() - 1)


func remove_indices(indices: PackedInt32Array) -> void:
	if indices.is_empty():
		return
	_layer.remove_indices(indices)
	rebuild()


## True when any instance lies within `dist` (inclusive) of (x, z).
func has_within(x: float, z: float, dist: float) -> bool:
	var d2 := dist * dist
	for cell in _cells_around(x, z, dist):
		for i: int in _cells.get(cell, PackedInt32Array()):
			var dx: float = _layer.x[i] - x
			var dz: float = _layer.z[i] - z
			if dx * dx + dz * dz <= d2:
				return true
	return false


## Indices of instances inside the disc (centre, radius), cell order then insertion order.
func indices_in_disc(cx: float, cz: float, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var r2 := radius * radius
	for cell in _cells_around(cx, cz, radius):
		for i: int in _cells.get(cell, PackedInt32Array()):
			var dx: float = _layer.x[i] - cx
			var dz: float = _layer.z[i] - cz
			if dx * dx + dz * dz <= r2:
				out.append(i)
	return out


func _register(i: int) -> void:
	var key := _key(_layer.x[i], _layer.z[i])
	var list: PackedInt32Array = _cells.get(key, PackedInt32Array())
	list.append(i)
	_cells[key] = list


static func _key(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / CELL_M), floori(z / CELL_M))


static func _cells_around(x: float, z: float, radius: float) -> Array[Vector2i]:
	var lo := _key(x - radius, z - radius)
	var hi := _key(x + radius, z + radius)
	var out: Array[Vector2i] = []
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			out.append(Vector2i(cx, cz))
	return out
