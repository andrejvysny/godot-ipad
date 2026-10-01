class_name ObjectEdits
extends RefCounted
## Pure edits of one ObjectRecord (spec §14). Callers clone the record first and own history.


## Yaw in degrees, normalized to (-180, 180]; snapped to multiples of snap_deg when > 0.
static func apply_yaw(rec: ObjectRecord, deg: float, snap_deg: float) -> void:
	var d := deg
	if snap_deg > 0.0:
		d = roundf(d / snap_deg) * snap_deg
	d = fposmod(d, 360.0)
	if d > 180.0:
		d -= 360.0
	rec.set_yaw(deg_to_rad(d))


## Returns "" or an error; the record is unchanged on error.
static func apply_scale(rec: ObjectRecord, value: float, asset: AssetDefinition) -> String:
	if not is_finite(value) or value <= 0.0:
		return "Scale must be a positive number."
	rec.uniform_scale = clampf(value, asset.scale_min, asset.scale_max)
	return ""


## Moves the anchor with the offset so the object keeps its ground contact: y += new - old.
static func apply_height_offset(rec: ObjectRecord, value: float, asset: AssetDefinition) -> String:
	if not is_finite(value):
		return "Height must be a finite number."
	var new_offset := clampf(value, asset.height_offset_min_m, asset.height_offset_max_m)
	rec.set_position(rec.position[0], rec.position[1] + new_offset - rec.height_offset_m, rec.position[2])
	rec.height_offset_m = new_offset
	return ""


static func apply_grounding(rec: ObjectRecord, mode: String, doc: WorldDocument) -> String:
	if mode == WorldConstants.GROUNDING_FOLLOW:
		var h := doc.sample_height(rec.position[0], rec.position[2])
		if is_nan(h):
			return "No terrain under the object."
		rec.set_position(rec.position[0], h + rec.height_offset_m, rec.position[2])
	elif mode != WorldConstants.GROUNDING_FIXED:
		return "Unknown grounding mode '%s'." % mode
	rec.grounding = mode
	return ""
