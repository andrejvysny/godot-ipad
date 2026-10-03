class_name ActiveEditArea
extends RefCounted
## Operation-scoped render pins (spec §8.2). Only the latest circle and one trailing circle (the position
## where the stroke last advanced by half a radius) are ever pinned, so a long stroke pins a bounded
## number of cells. After end() the pins release once `settle_ms` have passed (checked by tick()).
## Circles are in world XZ; cells use mathematical floor.

const MAX_RADIUS_M := 128.0

var _cell_size: float
var _settle_ms: int
var _op_id: Variant = null
var _current := {}  # {"center": Vector3, "radius": float} or {}
var _trail := {}
var _ended_ms: int = -1
var _pinned: Dictionary = {}  # Vector2i -> true


func _init(cell_size_m: float = 32.0, settle_ms: int = 250) -> void:
	_cell_size = maxf(cell_size_m, 0.001)
	_settle_ms = settle_ms


func begin(op_id: Variant, center: Vector3, radius: float) -> void:
	_op_id = op_id
	_current = _circle(center, radius)
	_trail = {}
	_ended_ms = -1
	_refresh()


func update(op_id: Variant, center: Vector3, radius: float) -> void:
	if _op_id == null or op_id != _op_id or _ended_ms >= 0:
		return
	var next := _circle(center, radius)
	var anchor: Dictionary = _trail if not _trail.is_empty() else _current
	if _flat_distance(anchor.center, next.center) >= 0.5 * float(next.radius):
		_trail = _current
	_current = next
	_refresh()


func end(op_id: Variant, _outcome: String = "") -> void:
	if _op_id == null or op_id != _op_id or _ended_ms >= 0:
		return
	_ended_ms = Time.get_ticks_msec()


func tick(now_ms: int) -> void:
	if _ended_ms >= 0 and now_ms - _ended_ms >= _settle_ms:
		_op_id = null
		_current = {}
		_trail = {}
		_ended_ms = -1
		_refresh()


## True from begin() until the pins have been released.
func is_active() -> bool:
	return _op_id != null and _ended_ms < 0


func has_pins() -> bool:
	return not _pinned.is_empty()


func operation_id() -> Variant:
	return _op_id


func pinned_cells(cell_size: float) -> Dictionary:
	var out := {}
	for circle: Dictionary in [_current, _trail]:
		if not circle.is_empty():
			_add_cells(out, circle, cell_size)
	return out


## Currently pinned cells (Vector2i -> true); read only.
func pinned_set() -> Dictionary:
	return _pinned


func is_pinned(cell: Vector2i) -> bool:
	return _pinned.has(cell)


func _refresh() -> void:
	_pinned = pinned_cells(_cell_size)


func _circle(center: Vector3, radius: float) -> Dictionary:
	return {"center": center, "radius": clampf(radius, 0.0, MAX_RADIUS_M)}


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func _add_cells(out: Dictionary, circle: Dictionary, cell_size: float) -> void:
	var c: Vector3 = circle.center
	var r: float = circle.radius
	var lo := Vector2i(floori((c.x - r) / cell_size), floori((c.z - r) / cell_size))
	var hi := Vector2i(floori((c.x + r) / cell_size), floori((c.z + r) / cell_size))
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			var nx := clampf(c.x, cx * cell_size, (cx + 1) * cell_size)
			var nz := clampf(c.z, cz * cell_size, (cz + 1) * cell_size)
			if Vector2(nx - c.x, nz - c.z).length() <= r:
				out[Vector2i(cx, cz)] = true
