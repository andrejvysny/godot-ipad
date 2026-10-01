class_name LabProbe
extends RefCounted
## A deliberately small pressure-independent edit for the native feasibility gate.

var document: WorldDocument
var radius_m := 4.0
var _transaction: EditTransaction
var _stroke: PaintStroke
var _paused := false


func is_active() -> bool:
	return _transaction != null


func begin(position: Vector2) -> Dictionary:
	_transaction = EditTransaction.new()
	_transaction.begin(document, "probe", "Input Lab probe")
	_stroke = PaintStroke.new()
	_paused = false
	return _stroke.begin(document, _transaction, {"radius": radius_m,
		"strength": 1.0, "target_blend": 1.0, "pressure_enabled": false}, position, 1.0)


func sample(timestamp: float, position: Vector2) -> Dictionary:
	if _paused:
		_paused = false
		return _stroke.resume(timestamp, position, 1.0)
	return _stroke.add_sample(timestamp, position, 1.0)


func pause(timestamp: float) -> void:
	if is_active():
		_stroke.pause(timestamp)
		_paused = true


func finish(timestamp: float) -> WorldChange:
	if not is_active():
		return null
	_stroke.finish(timestamp)
	var change := _transaction.finish()
	_transaction = null
	_stroke = null
	return change


func cancel() -> Dictionary:
	if not is_active():
		return {"controls": []}
	var touched := _stroke.cancel()
	_transaction = null
	_stroke = null
	return touched
