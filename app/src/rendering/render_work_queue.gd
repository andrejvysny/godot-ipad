class_name RenderWorkQueue
extends RefCounted
## Coalescing queue of (cell, asset) group builds, nearest cell first (spec §12.3). A group is queued once;
## pop() sorts lazily, only when entries were added or the focus moved by more than a cell.

var _items: Dictionary = {}  # "cx,cz|asset" -> [Vector2i, asset_id]
var _order: Array[String] = []  # nearest last
var _dirty: bool = false
var _sorted_focus := Vector3.INF
var _cell_size: float


func _init(cell_size_m: float) -> void:
	_cell_size = cell_size_m


static func key_of(cell: Vector2i, asset_id: String) -> String:
	return "%d,%d|%s" % [cell.x, cell.y, asset_id]


func push(cell: Vector2i, asset_id: String) -> void:
	var key := key_of(cell, asset_id)
	if not _items.has(key):
		_items[key] = [cell, asset_id]
		_dirty = true


func erase(cell: Vector2i, asset_id: String) -> void:
	_items.erase(key_of(cell, asset_id))


func size() -> int:
	return _items.size()


func is_empty() -> bool:
	return _items.is_empty()


func clear() -> void:
	_items.clear()
	_order.clear()


## [cell, asset_id] of the nearest queued group, removed from the queue; [] when empty.
func pop(focus: Vector3) -> Array:
	if _dirty or (not _items.is_empty() and focus.distance_to(_sorted_focus) > _cell_size):
		_sort(focus)
	while not _order.is_empty():
		var key: String = _order.pop_back()
		if _items.has(key):
			var item: Array = _items[key]
			_items.erase(key)
			return item
	return []


func _sort(focus: Vector3) -> void:
	_dirty = false
	_sorted_focus = focus
	var dist: Dictionary = {}
	for key: String in _items:
		var c: Vector2i = (_items[key] as Array)[0]
		dist[key] = Vector2((c.x + 0.5) * _cell_size - focus.x, (c.y + 0.5) * _cell_size - focus.z).length()
	_order.assign(_items.keys())
	_order.sort_custom(func(a: String, b: String) -> bool: return dist[a] > dist[b])
