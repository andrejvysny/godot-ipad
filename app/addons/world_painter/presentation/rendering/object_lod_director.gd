class_name ObjectLodDirector
extends RefCounted
## Per-cell wanted role of ObjectRenderWorld (spec §4.2, §8.1): the effective distance of each cell's 3D box to
## the camera goes through LodPolicy.individual_role with hysteresis. Cells are re-evaluated only when the
## camera moved (LodCameraTracker: position > 0.25 m, orientation or fov) or the profile changed, in passes of at most CHUNK cells
## per frame, nearest first. A cell that was never built takes its wanted role at once (first builds); a built
## cell goes into `pending` and changes role only after navigation settled (see settled()).
## Without a camera every cell is evaluated at distance 0, i.e. the profile's minimum role.

const CHUNK := 256
const ORDER_SHIFT := 1048576.0  # sort key = floor(distance * 16) * ORDER_SHIFT + index

var profile: Dictionary = {}
var hysteresis: float = 0.2
var settle_ms: int = 250
var pending: Dictionary = {}  # Vector2i -> true: built cells whose wanted role differs from their role
var evaluated: int = 0  # cells evaluated so far (cumulative)

var _cell_size: float
var _cam := LodCameraTracker.new()
var _again := true
var _order: Array[Vector2i] = []
var _cursor: int = 0
var _in_pass := false


func _init(cell_size_m: float) -> void:
	_cell_size = cell_size_m


func set_profile(p: Dictionary) -> void:
	profile = p
	hysteresis = float(p.get("lod_hysteresis_fraction", 0.2))
	settle_ms = int(p.get("settle_ms", 250))
	_again = true


func request_pass() -> void:
	_again = true


func reset() -> void:
	pending.clear()
	_order.clear()
	_cursor = 0
	_in_pass = false
	_again = true


func settled(now_ms: int) -> bool:
	return _cam.settled(now_ms, settle_ms)


func busy() -> bool:
	return _in_pass or _again or not pending.is_empty()


## Notes camera motion; a moved camera restarts the evaluation (after the running pass).
func track(camera: Camera3D, now_ms: int) -> void:
	if _cam.update(camera, now_ms):
		_again = true


## Effective distance of the cell's box to the camera.
func effective(cell: RenderCell) -> float:
	if cell.y_lo > cell.y_hi:
		return 0.0
	return _cam.effective_to_box(Vector3(cell.origin.x, cell.y_lo, cell.origin.z),
			Vector3(cell.origin.x + _cell_size, cell.y_hi, cell.origin.z + _cell_size))


## Role of a cell that has just been created (no hysteresis anchor).
func initial_role(cell: RenderCell) -> String:
	return LodPolicy.individual_role(effective(cell), profile, "", hysteresis)


## Evaluates up to CHUNK cells of the running pass, starting one when requested.
func step(cells: Dictionary) -> void:
	if not _in_pass:
		if not _again or cells.is_empty():
			_again = false
			return
		_begin(cells)
	var stop := mini(_cursor + CHUNK, _order.size())
	while _cursor < stop:
		var cell: RenderCell = cells.get(_order[_cursor])
		_cursor += 1
		if cell != null:
			_evaluate(cell)
	_in_pass = _cursor < _order.size()


func _begin(cells: Dictionary) -> void:
	_again = false
	_in_pass = true
	_cursor = 0
	var keys := cells.keys()
	var sorted := PackedFloat64Array()
	for i in keys.size():
		var cell: RenderCell = cells[keys[i]]
		var d := Vector2((cell.key.x + 0.5) * _cell_size - _cam.pos.x, (cell.key.y + 0.5) * _cell_size - _cam.pos.z).length() \
				if _cam.has_camera else 0.0
		sorted.append(floorf(d * 16.0) * ORDER_SHIFT + float(i))
	sorted.sort()
	_order.clear()
	for v in sorted:
		_order.append(keys[int(fmod(v, ORDER_SHIFT))])


func _evaluate(cell: RenderCell) -> void:
	evaluated += 1
	cell.wanted = LodPolicy.individual_role(effective(cell), profile, cell.wanted, hysteresis)
	if cell.reps.is_empty():
		cell.role = cell.wanted
		pending.erase(cell.key)
	elif cell.wanted != cell.role:
		pending[cell.key] = true
	else:
		pending.erase(cell.key)
