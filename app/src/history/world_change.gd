class_name WorldChange
extends RefCounted
## One completed, already-applied action as immutable value snapshots (spec §16.1).
## Region maps are private duplicates; object values are cloned records. A null before-record
## means creation, a null after-record means deletion. Never reference live nodes or images.

var operation_id: String = ""
var label: String = ""
var tool_id: String = ""
var before_heights: Dictionary = {}  # Vector2i -> PackedFloat32Array
var after_heights: Dictionary = {}
var before_controls: Dictionary = {}  # Vector2i -> PackedInt32Array
var after_controls: Dictionary = {}
var before_objects: Dictionary = {}  # object_id -> ObjectRecord or null
var after_objects: Dictionary = {}
var affected_world_bounds := Rect2()
var payload_bytes: int = 0

const OBJECT_RECORD_BYTES_ESTIMATE := 256


func height_regions() -> Array:
	return before_heights.keys()


func control_regions() -> Array:
	return before_controls.keys()


func object_ids() -> Array:
	return before_objects.keys()


func compute_payload_bytes() -> int:
	var total := 0
	for d in [before_heights, after_heights, before_controls, after_controls]:
		for k in d:
			total += d[k].size() * 4
	total += (before_objects.size() + after_objects.size()) * OBJECT_RECORD_BYTES_ESTIMATE
	payload_bytes = total
	return total


## Writes one side of the change into `doc`. Arrays are duplicated so the snapshot stays
## immutable after the document is edited again. Does not touch document_revision.
func apply_to(doc: WorldDocument, use_after: bool) -> void:
	var heights: Dictionary = after_heights if use_after else before_heights
	var controls: Dictionary = after_controls if use_after else before_controls
	var objs: Dictionary = after_objects if use_after else before_objects
	for loc in heights:
		doc.get_region(loc).heights = (heights[loc] as PackedFloat32Array).duplicate()
		doc.invalidate_height_range(loc)
	for loc in controls:
		doc.get_region(loc).control = (controls[loc] as PackedInt32Array).duplicate()
	for id in objs:
		var rec: ObjectRecord = objs[id]
		if rec == null:
			doc.remove_object(id)
		else:
			doc.put_object(rec.clone())
