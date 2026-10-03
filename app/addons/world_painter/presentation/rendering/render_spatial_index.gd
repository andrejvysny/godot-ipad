class_name RenderSpatialIndex
extends RefCounted
## Uniform XZ grid over world AABBs (rendering performance spec §7.1/§15.1). Pure logic.
## An entry is registered in EVERY cell its AABB overlaps, so an overhanging crown is found from
## any cell it covers. Cell key = floor(coord / cell) (mathematical floor, negative-safe).

var _cell: float
var _cells: Dictionary = {}  # Vector2i -> Dictionary(id -> true)
var _bounds: Dictionary = {}  # id -> AABB
var _rects: Dictionary = {}  # id -> Rect2i (position = first cell, size = last cell - first cell)
var _rect_dirty: bool = false
var _min_cell := Vector2i.ZERO
var _max_cell := Vector2i.ZERO


func _init(cell_size_m: float = 32.0) -> void:
	_cell = maxf(cell_size_m, 0.001)


func put(id: String, bounds: AABB) -> void:
	remove(id)
	var b := bounds.abs()
	var lo := _key(b.position.x, b.position.z)
	var hi := _key(b.end.x, b.end.z)
	_bounds[id] = b
	_rects[id] = Rect2i(lo, hi - lo)
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var key := Vector2i(cx, cz)
			if not _cells.has(key):
				_cells[key] = {}
				if _cells.size() == 1:
					_min_cell = key
					_max_cell = key
				else:
					_min_cell = Vector2i(mini(_min_cell.x, cx), mini(_min_cell.y, cz))
					_max_cell = Vector2i(maxi(_max_cell.x, cx), maxi(_max_cell.y, cz))
			(_cells[key] as Dictionary)[id] = true


func remove(id: String) -> void:
	if not _bounds.has(id):
		return
	var rect: Rect2i = _rects[id]
	var lo := rect.position
	var hi := rect.position + rect.size
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var key := Vector2i(cx, cz)
			var cell: Dictionary = _cells[key]
			cell.erase(id)
			if cell.is_empty():
				_cells.erase(key)
				if cx == _min_cell.x or cx == _max_cell.x or cz == _min_cell.y or cz == _max_cell.y:
					_rect_dirty = true
	_bounds.erase(id)
	_rects.erase(id)


func has(id: String) -> bool:
	return _bounds.has(id)


func bounds_of(id: String) -> AABB:
	return _bounds.get(id, AABB())


func size() -> int:
	return _bounds.size()


func cell_count() -> int:
	return _cells.size()


func clear() -> void:
	_cells.clear()
	_bounds.clear()
	_rects.clear()
	_rect_dirty = false


func query_aabb(box: AABB) -> PackedStringArray:
	var out := PackedStringArray()
	if _cells.is_empty() or not box.position.is_finite() or not box.size.is_finite():
		return out
	var b := box.abs()
	var found: Dictionary = {}
	var lo := _clamp_cell(_key(b.position.x, b.position.z))
	var hi := _clamp_cell(_key(b.end.x, b.end.z))
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var cell: Dictionary = _cells.get(Vector2i(cx, cz), {})
			for id: String in cell:
				if not found.has(id) and (_bounds[id] as AABB).intersects(b):
					found[id] = true
	return _sorted(found.keys())


func query_ray(origin: Vector3, dir: Vector3, max_distance: float) -> PackedStringArray:
	if _cells.is_empty() or not origin.is_finite() or not dir.is_finite() \
			or dir.length_squared() < 1e-12 or not is_finite(max_distance) or max_distance < 0.0:
		return PackedStringArray()
	var d := dir.normalized()
	var end := origin + d * max_distance
	var found: Dictionary = {}
	if absf(d.x) < 1e-12 and absf(d.z) < 1e-12:
		_collect_cell(_key(origin.x, origin.z), origin, end, found)
		return _sorted(found.keys())
	_refresh_rect()
	var span := _clip_xz(origin, d, max_distance)
	if span.x > span.y:
		return PackedStringArray()
	_walk_cells(origin, d, span, end, found)
	return _sorted(found.keys())


## Ids whose AABB centre lies within `radius` of `point`, nearest first, ties by id.
func query_near(point: Vector3, radius: float, max_count: int) -> PackedStringArray:
	if _cells.is_empty() or max_count <= 0 or not point.is_finite() or not is_finite(radius) or radius < 0.0:
		return PackedStringArray()
	var lo := _clamp_cell(_key(point.x - radius, point.z - radius))
	var hi := _clamp_cell(_key(point.x + radius, point.z + radius))
	var found: Dictionary = {}
	var limit := radius * radius
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var cell: Dictionary = _cells.get(Vector2i(cx, cz), {})
			for id: String in cell:
				if not found.has(id):
					var d2 := ((_bounds[id] as AABB).get_center() - point).length_squared()
					if d2 <= limit:
						found[id] = d2
	var items: Array = []
	for id: String in found:
		items.append([found[id], id])
	items.sort_custom(_near_less)
	var out := PackedStringArray()
	for i in mini(items.size(), max_count):
		out.append((items[i] as Array)[1])
	return out


static func _near_less(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return (a[0] as float) < (b[0] as float)
	return (a[1] as String) < (b[1] as String)


func _key(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / _cell), floori(z / _cell))


func _clamp_cell(c: Vector2i) -> Vector2i:
	_refresh_rect()
	return Vector2i(clampi(c.x, _min_cell.x, _max_cell.x), clampi(c.y, _min_cell.y, _max_cell.y))


func _refresh_rect() -> void:
	if not _rect_dirty:
		return
	_rect_dirty = false
	var first := true
	for key: Vector2i in _cells:
		if first:
			_min_cell = key
			_max_cell = key
			first = false
		else:
			_min_cell = Vector2i(mini(_min_cell.x, key.x), mini(_min_cell.y, key.y))
			_max_cell = Vector2i(maxi(_max_cell.x, key.x), maxi(_max_cell.y, key.y))


static func _sorted(ids: Array) -> PackedStringArray:
	var out := PackedStringArray(ids)
	out.sort()
	return out


func _collect_cell(key: Vector2i, origin: Vector3, end: Vector3, found: Dictionary) -> void:
	var cell: Dictionary = _cells.get(key, {})
	for id: String in cell:
		if found.has(id):
			continue
		var b: AABB = _bounds[id]
		if b.has_point(origin) or b.intersects_segment(origin, end):
			found[id] = true


## Parameter interval [t0, t1] (metres along d) of the segment inside the occupied XZ rectangle.
func _clip_xz(origin: Vector3, d: Vector3, max_distance: float) -> Vector2:
	var t0 := 0.0
	var t1 := max_distance
	var lo := Vector2(_min_cell.x * _cell, _min_cell.y * _cell)
	var hi := Vector2((_max_cell.x + 1) * _cell, (_max_cell.y + 1) * _cell)
	var o := Vector2(origin.x, origin.z)
	var v := Vector2(d.x, d.z)
	for axis in 2:
		if absf(v[axis]) < 1e-12:
			if o[axis] < lo[axis] or o[axis] > hi[axis]:
				return Vector2(1.0, 0.0)
			continue
		var ta := (lo[axis] - o[axis]) / v[axis]
		var tb := (hi[axis] - o[axis]) / v[axis]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	return Vector2(t0, t1)


func _walk_cells(origin: Vector3, d: Vector3, span: Vector2, end: Vector3, found: Dictionary) -> void:
	var start := origin + d * span.x
	var cell := Vector2i(clampi(floori(start.x / _cell), _min_cell.x, _max_cell.x),
			clampi(floori(start.z / _cell), _min_cell.y, _max_cell.y))
	var dv := Vector2(d.x, d.z)
	var ov := Vector2(origin.x, origin.z)
	var step := Vector2i(int(signf(d.x)), int(signf(d.z)))
	var t_max := Vector2(INF, INF)
	var t_delta := Vector2(INF, INF)
	for axis in 2:
		if absf(dv[axis]) < 1e-12:
			continue
		var edge := (cell[axis] + (1 if step[axis] > 0 else 0)) * _cell
		t_max[axis] = (edge - ov[axis]) / dv[axis]
		t_delta[axis] = _cell / absf(dv[axis])
	var budget := (_max_cell.x - _min_cell.x) + (_max_cell.y - _min_cell.y) + 4
	while budget > 0:
		budget -= 1
		_collect_cell(cell, origin, end, found)
		var axis := 0 if t_max.x < t_max.y else 1
		if t_max[axis] > span.y:
			break
		cell[axis] += step[axis]
		t_max[axis] += t_delta[axis]
		if cell.x < _min_cell.x or cell.x > _max_cell.x or cell.y < _min_cell.y or cell.y > _max_cell.y:
			break
