class_name WorldChange
extends RefCounted
## One completed, already-applied action as immutable value snapshots (spec §16.1).
## Region maps are private duplicates; object/path values are cloned records. A null before-record
## means creation, a null after-record means deletion. Never reference live nodes or images.
## Scatter and rules are whole-value snapshots: null means "untouched by this action".

var operation_id: String = ""
var label: String = ""
var tool_id: String = ""
var before_heights: Dictionary = {}  # Vector2i -> PackedFloat32Array
var after_heights: Dictionary = {}
var before_controls: Dictionary = {}  # Vector2i -> PackedInt32Array
var after_controls: Dictionary = {}
var before_colors: Dictionary = {}  # Vector2i -> PackedByteArray (RGBA8)
var after_colors: Dictionary = {}
var before_objects: Dictionary = {}  # object_id -> ObjectRecord or null
var after_objects: Dictionary = {}
var before_scatter: ScatterLayer = null
var after_scatter: ScatterLayer = null
var before_paths: Dictionary = {}  # path_id -> PathRecord or null (null = absent)
var after_paths: Dictionary = {}
var before_rules: TerrainRules = null
var after_rules: TerrainRules = null
var affected_world_bounds := Rect2()
var payload_bytes: int = 0

const OBJECT_RECORD_BYTES_ESTIMATE := 256
const SCATTER_INSTANCE_BYTES_ESTIMATE := 24
const PATH_POINT_BYTES := 8


func height_regions() -> Array:
	return before_heights.keys()


func control_regions() -> Array:
	return before_controls.keys()


func color_regions() -> Array:
	return before_colors.keys()


func object_ids() -> Array:
	return before_objects.keys()


func path_ids() -> Array:
	return before_paths.keys()


func has_scatter() -> bool:
	return before_scatter != null


func has_rules() -> bool:
	return before_rules != null


func is_empty() -> bool:
	return before_heights.is_empty() and before_controls.is_empty() and before_colors.is_empty() \
		and before_objects.is_empty() and before_paths.is_empty() \
		and not has_scatter() and not has_rules()


func compute_payload_bytes() -> int:
	var total := 0
	for d in [before_heights, after_heights, before_controls, after_controls]:
		for k in d:
			total += d[k].size() * 4
	for d in [before_colors, after_colors]:
		for k in d:
			total += d[k].size()
	total += (before_objects.size() + after_objects.size()) * OBJECT_RECORD_BYTES_ESTIMATE
	for layer in [before_scatter, after_scatter]:
		if layer != null:
			total += layer.count() * SCATTER_INSTANCE_BYTES_ESTIMATE
	for d in [before_paths, after_paths]:
		for k in d:
			if d[k] != null:
				total += (d[k] as PathRecord).points.size() * PATH_POINT_BYTES
	payload_bytes = total
	return total


## Writes one side of the change into `doc`. Arrays are duplicated so the snapshot stays
## immutable after the document is edited again. Does not touch document_revision.
func apply_to(doc: WorldDocument, use_after: bool) -> void:
	var heights: Dictionary = after_heights if use_after else before_heights
	var controls: Dictionary = after_controls if use_after else before_controls
	var colors: Dictionary = after_colors if use_after else before_colors
	var objs: Dictionary = after_objects if use_after else before_objects
	var path_values: Dictionary = after_paths if use_after else before_paths
	for loc in heights:
		doc.get_region(loc).heights = (heights[loc] as PackedFloat32Array).duplicate()
		doc.invalidate_height_range(loc)
	for loc in controls:
		doc.get_region(loc).control = (controls[loc] as PackedInt32Array).duplicate()
	for loc in colors:
		doc.get_region(loc).color = (colors[loc] as PackedByteArray).duplicate()
	for id in objs:
		var rec: ObjectRecord = objs[id]
		if rec == null:
			doc.remove_object(id)
		else:
			doc.put_object(rec.clone())
	for id in path_values:
		var prec: PathRecord = path_values[id]
		if prec == null:
			doc.remove_path(id)
		else:
			doc.put_path(prec.clone())
	var scatter: ScatterLayer = after_scatter if use_after else before_scatter
	if scatter != null:
		doc.scatter = scatter.clone()
	var rules: TerrainRules = after_rules if use_after else before_rules
	if rules != null:
		doc.rules = rules.clone()
