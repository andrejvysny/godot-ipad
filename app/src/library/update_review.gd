class_name UpdateReview
extends RefCounted
## The review of moving objects of binding B to an exact newer version V2 (shared spec §7, IP-SPEC §4): what the two
## frozen descriptors differ in (anchor, bounds, footprint, limits, material slots, collision) and which placed
## objects have a scale or height offset outside V2's limits. Placed anchor position, rotation and scale are kept; a
## value outside the new limits blocks automatic preservation until the user picks an explicit alternative
## ("exclude" those objects, or "limit": set them to the nearest limit shown). Nothing is ever clamped silently.

const DescriptorDiff := preload("res://addons/assetstudio/project/as_descriptor_diff.gd")
const EXCLUDE := "exclude"
const LIMIT := "limit"

var old_binding: AssetBinding
var new_binding: AssetBinding
var object_ids: Array[String] = []
var differences := PackedStringArray()
## [{object_id, field ("uniform_scale" | "height_offset_m"), value, low, high, proposed}]
var conflicts: Array[Dictionary] = []
var choice := ""


## `object_ids`: the records the user wants to move (all of them reference `old_binding`).
static func build(doc: WorldDocument, old_binding_id: String, new_binding_id: String, object_ids: Array) -> UpdateReview:
	var r := UpdateReview.new()
	r.old_binding = doc.assets.get_binding(old_binding_id)
	r.new_binding = doc.assets.get_binding(new_binding_id)
	if r.old_binding == null or r.new_binding == null:
		return r
	for id: String in object_ids:
		var rec := doc.get_object(id)
		if rec != null and rec.binding_id == old_binding_id:
			r.object_ids.append(id)
			r._check_limits(rec)
	var old_d: Variant = JSON.parse_string(r.old_binding.descriptor_json)
	var new_d: Variant = JSON.parse_string(r.new_binding.descriptor_json)
	if old_d is Dictionary and new_d is Dictionary:
		r.differences = DescriptorDiff.diff(old_d, new_d)
	return r


func _check_limits(rec: ObjectRecord) -> void:
	if not new_binding.in_scale(rec.uniform_scale):
		conflicts.append({"object_id": rec.object_id, "field": "uniform_scale", "value": rec.uniform_scale,
				"low": new_binding.scale_min, "high": new_binding.scale_max,
				"proposed": clampf(rec.uniform_scale, new_binding.scale_min, new_binding.scale_max)})
	if not new_binding.in_height_offset(rec.height_offset_m):
		conflicts.append({"object_id": rec.object_id, "field": "height_offset_m", "value": rec.height_offset_m,
				"low": new_binding.height_offset_min_m, "high": new_binding.height_offset_max_m,
				"proposed": clampf(rec.height_offset_m, new_binding.height_offset_min_m, new_binding.height_offset_max_m)})


func is_valid() -> bool:
	return old_binding != null and new_binding != null and not object_ids.is_empty()


## True while out-of-range objects exist and the user has not chosen what happens to them.
func needs_choice() -> bool:
	return not conflicts.is_empty() and choice == ""


func conflicting_ids() -> Array[String]:
	var out: Array[String] = []
	for c: Dictionary in conflicts:
		if not out.has(str(c.object_id)):
			out.append(str(c.object_id))
	return out


func set_choice(value: String) -> String:
	if value != EXCLUDE and value != LIMIT:
		return "Unknown choice '%s'." % value
	choice = value
	return ""


## {"ids": Array, "overrides": Dictionary}: what ToolController.rebind_objects() receives. Empty ids while a choice
## is still missing, so a caller can never apply an unreviewed range violation.
func plan() -> Dictionary:
	if needs_choice() or not is_valid():
		return {"ids": [], "overrides": {}}
	var bad := conflicting_ids()
	var ids: Array = []
	var overrides := {}
	for id in object_ids:
		if choice == EXCLUDE and bad.has(id):
			continue
		ids.append(id)
	if choice == LIMIT:
		for c: Dictionary in conflicts:
			if not overrides.has(c.object_id):
				overrides[c.object_id] = {}
			overrides[c.object_id][c.field] = c.proposed
	return {"ids": ids, "overrides": overrides}


## One text block for the dialog body: versions, differences, objects with out-of-range values.
func summary() -> String:
	var lines := PackedStringArray()
	lines.append("%d object(s) move from %s to %s." % [object_ids.size(), old_binding.asset_ref.version_id, new_binding.asset_ref.version_id])
	lines.append("Placed position, rotation and scale are kept.")
	if differences.is_empty():
		lines.append("No difference in anchor, bounds, limits, material slots or collision.")
	else:
		lines.append("Differences:")
		for d in differences:
			lines.append("- " + d)
	if not conflicts.is_empty():
		lines.append("%d object(s) have a value outside the new limits:" % conflicting_ids().size())
		for c: Dictionary in conflicts:
			lines.append("- %s %s is outside %s..%s (nearest limit %s)" % [str(c.object_id).substr(0, 8),
					c.field, AssetBinding.dec(c.low), AssetBinding.dec(c.high), AssetBinding.dec(c.proposed)])
	return "\n".join(lines)
