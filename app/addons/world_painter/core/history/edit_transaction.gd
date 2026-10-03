class_name EditTransaction
extends RefCounted
## Live operation boundary (spec §16). Tools call capture_* immediately before the first
## mutation of each region map, object, path, the scatter layer or the rules, then mutate the document directly. finish()
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
var _before_colors: Dictionary = {}
var _before_objects: Dictionary = {}
var _before_paths: Dictionary = {}
var _before_scatter: ScatterLayer = null
var _before_rules: TerrainRules = null
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


func capture_colors(loc: Vector2i) -> bool:
	assert(_open)
	if _before_colors.has(loc):
		return true
	var r := _doc.get_region(loc)
	if r == null:
		return false
	if not _reserve(r.color.size() * 2):
		return false
	_before_colors[loc] = r.color.duplicate()
	return true


func capture_scatter() -> bool:
	assert(_open)
	if _before_scatter != null:
		return true
	if not _reserve(_doc.scatter.count() * WorldChange.SCATTER_INSTANCE_BYTES_ESTIMATE * 2):
		return false
	_before_scatter = _doc.scatter.clone()
	return true


func capture_path(id: String) -> bool:
	assert(_open)
	if _before_paths.has(id):
		return true
	var rec := _doc.get_path_record(id)
	var points := rec.points.size() if rec != null else 0
	if not _reserve(WorldChange.OBJECT_RECORD_BYTES_ESTIMATE + points * WorldChange.PATH_POINT_BYTES * 2):
		return false
	_before_paths[id] = rec.clone() if rec != null else null
	return true


func capture_rules() -> bool:
	assert(_open)
	if _before_rules != null:
		return true
	if not _reserve(WorldChange.OBJECT_RECORD_BYTES_ESTIMATE):
		return false
	_before_rules = _doc.rules.clone()
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


func has_captured_colors(loc: Vector2i) -> bool:
	return _before_colors.has(loc)


func has_captured_scatter() -> bool:
	return _before_scatter != null


func has_captured_rules() -> bool:
	return _before_rules != null


func captured_path_ids() -> Array:
	return _before_paths.keys()


func captured_object_ids() -> Array:
	return _before_objects.keys()


func touched_height_regions() -> Array:
	return _before_heights.keys()


func touched_control_regions() -> Array:
	return _before_controls.keys()


func touched_color_regions() -> Array:
	return _before_colors.keys()


## Read-only views of the captured before-values for samplers (the arrays are never mutated; do not edit them).
func before_heights(loc: Vector2i) -> PackedFloat32Array:
	return _before_heights.get(loc, PackedFloat32Array())


func before_controls(loc: Vector2i) -> PackedInt32Array:
	return _before_controls.get(loc, PackedInt32Array())


func before_colors(loc: Vector2i) -> PackedByteArray:
	return _before_colors.get(loc, PackedByteArray())


## The record captured before the operation; null when the object was created by it (or never captured).
func before_object(id: String) -> ObjectRecord:
	return _before_objects.get(id)


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
	for loc in _before_colors:
		var now_col: PackedByteArray = _doc.get_region(loc).color
		if now_col != _before_colors[loc]:
			c.before_colors[loc] = _before_colors[loc]
			c.after_colors[loc] = now_col.duplicate()
	for id in _before_objects:
		var before: ObjectRecord = _before_objects[id]
		var after := _doc.get_object(id)
		var same := (before == null and after == null) or (before != null and before.equals(after))
		if not same:
			c.before_objects[id] = before
			c.after_objects[id] = after.clone() if after != null else null
	_finish_paths_scatter_rules(c)
	_clear()
	if c.is_empty():
		return null
	c.affected_world_bounds = _bounds_of(c)
	c.compute_payload_bytes()
	return c


func _finish_paths_scatter_rules(c: WorldChange) -> void:
	for id in _before_paths:
		var before: PathRecord = _before_paths[id]
		var after := _doc.get_path_record(id)
		if not ((before == null and after == null) or (before != null and before.equals(after))):
			c.before_paths[id] = before
			c.after_paths[id] = after.clone() if after != null else null
	if _before_scatter != null and not _before_scatter.equals(_doc.scatter):
		c.before_scatter = _before_scatter
		c.after_scatter = _doc.scatter.clone()
	if _before_rules != null and not _before_rules.equals(_doc.rules):
		c.before_rules = _before_rules
		c.after_rules = _doc.rules.clone()


## Restores all captured values. Returns {heights, controls, colors, objects, paths, scatter,
## rules} (key lists; scatter/rules are bools) so presenters can refresh exactly what was touched.
func rollback() -> Dictionary:
	var touched := {
		"heights": _before_heights.keys(),
		"controls": _before_controls.keys(),
		"colors": _before_colors.keys(),
		"objects": _before_objects.keys(),
		"paths": _before_paths.keys(),
		"scatter": _before_scatter != null,
		"rules": _before_rules != null,
	}
	if _doc != null:
		for loc in _before_heights:
			_doc.get_region(loc).heights = (_before_heights[loc] as PackedFloat32Array).duplicate()
			_doc.invalidate_height_range(loc)
		for loc in _before_controls:
			_doc.get_region(loc).control = (_before_controls[loc] as PackedInt32Array).duplicate()
		for loc in _before_colors:
			_doc.get_region(loc).color = (_before_colors[loc] as PackedByteArray).duplicate()
		for id in _before_objects:
			var rec: ObjectRecord = _before_objects[id]
			if rec == null:
				_doc.remove_object(id)
			else:
				_doc.put_object(rec.clone())
		for id in _before_paths:
			var prec: PathRecord = _before_paths[id]
			if prec == null:
				_doc.remove_path(id)
			else:
				_doc.put_path(prec.clone())
		if _before_scatter != null:
			_doc.scatter = _before_scatter.clone()
		if _before_rules != null:
			_doc.rules = _before_rules.clone()
	_open = false
	_clear()
	return touched


func _clear() -> void:
	_before_heights = {}
	_before_controls = {}
	_before_colors = {}
	_before_objects = {}
	_before_paths = {}
	_before_scatter = null
	_before_rules = null
	_payload = 0


func _bounds_of(c: WorldChange) -> Rect2:
	var span := WorldConstants.REGION_SAMPLES * WorldConstants.SAMPLE_SPACING
	var rects: Array[Rect2] = []
	for loc in c.before_heights.keys() + c.before_controls.keys() + c.before_colors.keys():
		rects.append(Rect2(Vector2(loc) * span, Vector2(span, span)))
	for d in [c.before_paths, c.after_paths]:
		for id in d:
			if d[id] != null:
				rects.append((d[id] as PathRecord).bounds())
	if c.has_scatter() or c.has_rules():
		rects.append(_doc.layout.extent_rect())
	var rect := Rect2()
	for i in rects.size():
		rect = rects[i] if i == 0 else rect.merge(rects[i])
	return rect
