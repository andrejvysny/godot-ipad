class_name EditTransaction
extends RefCounted
## Live operation boundary (spec §16). Tools call capture_* immediately before the first
## mutation of each region map or object, then mutate the document directly. finish()
## produces a WorldChange (or null for a no-op); rollback() restores every captured value.

var operation_id: String = ""
var tool_id: String = ""
var label: String = ""
var settings_snapshot: Dictionary = {}
var start_revision: int = 0
var max_payload_bytes: int = 64 * 1024 * 1024
var budget_exceeded := false

var _doc: WorldDocument
var _before_heights: Dictionary = {}
var _before_controls: Dictionary = {}
var _before_objects: Dictionary = {}
var _payload := 0
var _open := false


func begin(doc: WorldDocument, p_tool_id: String, p_label: String, settings: Dictionary = {}) -> void:
	_doc = doc
	tool_id = p_tool_id
	label = p_label
	settings_snapshot = settings.duplicate(true)
	operation_id = ObjectRecord.new_uuid_v4()
	start_revision = doc.document_revision
	_open = true


func is_open() -> bool:
	return _open


## Returns false when capturing would exceed the action-memory budget; the caller must
## then roll back instead of mutating.
func capture_heights(loc: Vector2i) -> bool:
	assert(_open)
	if _before_heights.has(loc):
		return true
	var r := _doc.get_region(loc)
	if r == null:
		return false
	if not _reserve(r.heights.size() * 8):  # before + eventual after
		return false
	_before_heights[loc] = r.heights.duplicate()
	return true


func capture_controls(loc: Vector2i) -> bool:
	assert(_open)
	if _before_controls.has(loc):
		return true
	var r := _doc.get_region(loc)
	if r == null:
		return false
	if not _reserve(r.control.size() * 8):
		return false
	_before_controls[loc] = r.control.duplicate()
	return true


func capture_object(id: String) -> bool:
	assert(_open)
	if _before_objects.has(id):
		return true
	if not _reserve(WorldChange.OBJECT_RECORD_BYTES_ESTIMATE * 2):
		return false
	var rec := _doc.get_object(id)
	_before_objects[id] = rec.clone() if rec != null else null
	return true


func has_captured_heights(loc: Vector2i) -> bool:
	return _before_heights.has(loc)


func has_captured_controls(loc: Vector2i) -> bool:
	return _before_controls.has(loc)


func captured_object_ids() -> Array:
	return _before_objects.keys()


func touched_height_regions() -> Array:
	return _before_heights.keys()


func touched_control_regions() -> Array:
	return _before_controls.keys()


func _reserve(n: int) -> bool:
	if _payload + n > max_payload_bytes:
		budget_exceeded = true
		return false
	_payload += n
	return true


## Closes the transaction. Unchanged captures are dropped; returns null when nothing changed.
func finish() -> WorldChange:
	assert(_open)
	_open = false
	var c := WorldChange.new()
	c.operation_id = operation_id
	c.label = label
	c.tool_id = tool_id
	for loc in _before_heights:
		var now: PackedFloat32Array = _doc.get_region(loc).heights
		if now != _before_heights[loc]:
			c.before_heights[loc] = _before_heights[loc]
			c.after_heights[loc] = now.duplicate()
	for loc in _before_controls:
		var now_c: PackedInt32Array = _doc.get_region(loc).control
		if now_c != _before_controls[loc]:
			c.before_controls[loc] = _before_controls[loc]
			c.after_controls[loc] = now_c.duplicate()
	for id in _before_objects:
		var before: ObjectRecord = _before_objects[id]
		var after := _doc.get_object(id)
		var same := (before == null and after == null) or (before != null and before.equals(after))
		if not same:
			c.before_objects[id] = before
			c.after_objects[id] = after.clone() if after != null else null
	_clear()
	if c.before_heights.is_empty() and c.before_controls.is_empty() and c.before_objects.is_empty():
		return null
	c.affected_world_bounds = _bounds_of(c)
	c.compute_payload_bytes()
	return c


## Restores all captured values. Returns {heights: [...], controls: [...], objects: [...]}
## so presenters can refresh exactly what was touched.
func rollback() -> Dictionary:
	var touched := {
		"heights": _before_heights.keys(),
		"controls": _before_controls.keys(),
		"objects": _before_objects.keys(),
	}
	if _doc != null:
		for loc in _before_heights:
			_doc.get_region(loc).heights = (_before_heights[loc] as PackedFloat32Array).duplicate()
			_doc.invalidate_height_range(loc)
		for loc in _before_controls:
			_doc.get_region(loc).control = (_before_controls[loc] as PackedInt32Array).duplicate()
		for id in _before_objects:
			var rec: ObjectRecord = _before_objects[id]
			if rec == null:
				_doc.remove_object(id)
			else:
				_doc.put_object(rec.clone())
	_open = false
	_clear()
	return touched


func _clear() -> void:
	_before_heights = {}
	_before_controls = {}
	_before_objects = {}
	_payload = 0


static func _bounds_of(c: WorldChange) -> Rect2:
	var span := WorldConstants.REGION_SAMPLES * WorldConstants.SAMPLE_SPACING
	var rect := Rect2()
	var first := true
	for loc in c.before_heights.keys() + c.before_controls.keys():
		var r := Rect2(Vector2(loc) * span, Vector2(span, span))
		rect = r if first else rect.merge(r)
		first = false
	return rect
