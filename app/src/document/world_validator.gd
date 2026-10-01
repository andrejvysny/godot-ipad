class_name WorldValidator
extends RefCounted
## Semantic validation of an authored world against the trusted catalog (spec §17.5,
## docs/world-format.md §4, §7). Returns diagnostics; never modifies the document.

const MAX_OBJECTS := 2000
const UNIT_QUAT_TOLERANCE := 1e-6
const GROUNDING_TOLERANCE_M := 1e-3
## Bits 23-26 and 28-31: set only when base or overlay id >= 2. Fast path; ControlCodec
## stays authoritative for anything this mask flags.
const CONTROL_UNSUPPORTED_FAST_MASK := 0xF7800000
const MAX_ERRORS_PER_REGION := 1


static func validate(doc: WorldDocument, catalog: AssetCatalog) -> PackedStringArray:
	var errors := PackedStringArray()
	if doc == null:
		errors.append("document is null")
		return errors
	if doc.schema_version != WorldConstants.SCHEMA_VERSION:
		errors.append("unsupported schema_version %d" % doc.schema_version)
	errors.append_array(_validate_catalog_identity(doc, catalog))
	errors.append_array(_validate_regions(doc))
	if catalog != null:
		errors.append_array(_validate_objects(doc, catalog))
	return errors


static func _validate_catalog_identity(doc: WorldDocument, catalog: AssetCatalog) -> PackedStringArray:
	var errors := PackedStringArray()
	if catalog == null:
		errors.append("no trusted catalog loaded")
		return errors
	if doc.catalog_id != catalog.catalog_id or doc.catalog_version != catalog.catalog_version:
		errors.append("incompatible catalog '%s' v%d (trusted catalog is '%s' v%d)" % [
			doc.catalog_id, doc.catalog_version, catalog.catalog_id, catalog.catalog_version])
	if doc.catalog_sha256 != catalog.sha256:
		errors.append("incompatible catalog content hash %s (trusted catalog hash is %s)" % [
			doc.catalog_sha256, catalog.sha256])
	return errors


static func _validate_regions(doc: WorldDocument) -> PackedStringArray:
	var errors := PackedStringArray()
	for loc in doc.regions:
		if not WorldConstants.is_valid_region(loc):
			errors.append("unexpected region %s" % str(loc))
	for loc in WorldConstants.REGION_LOCATIONS:
		var r: RegionBuffers = doc.regions.get(loc)
		if r == null:
			errors.append("missing region %s" % str(loc))
			continue
		if r.heights.size() != WorldConstants.REGION_SAMPLE_COUNT or r.control.size() != WorldConstants.REGION_SAMPLE_COUNT:
			errors.append("region %s buffers have %d/%d samples, expected %d" % [
				str(loc), r.heights.size(), r.control.size(), WorldConstants.REGION_SAMPLE_COUNT])
			continue
		errors.append_array(_validate_heights(loc, r.heights))
		errors.append_array(_validate_control(loc, r.control))
	return errors


static func _validate_heights(loc: Vector2i, heights: PackedFloat32Array) -> PackedStringArray:
	var errors := PackedStringArray()
	var lo := WorldConstants.HEIGHT_MIN
	var hi := WorldConstants.HEIGHT_MAX
	var i := 0
	for h in heights:
		# Written so NaN fails the comparison and is rejected.
		if not (h >= lo and h <= hi):
			errors.append("region %s height[%d] = %s is not finite within [%s, %s]" % [str(loc), i, str(h), lo, hi])
			if errors.size() >= MAX_ERRORS_PER_REGION:
				break
		i += 1
	return errors


static func _validate_control(loc: Vector2i, control: PackedInt32Array) -> PackedStringArray:
	var errors := PackedStringArray()
	var i := 0
	for v in control:
		if (v & CONTROL_UNSUPPORTED_FAST_MASK) != 0 and not ControlCodec.is_supported(v):
			errors.append("region %s control[%d] = 0x%08x uses unsupported material ids (base %d, overlay %d)" % [
				str(loc), i, v & ControlCodec.U32, ControlCodec.get_base(v), ControlCodec.get_overlay(v)])
			if errors.size() >= MAX_ERRORS_PER_REGION:
				break
		i += 1
	return errors


static func _validate_objects(doc: WorldDocument, catalog: AssetCatalog) -> PackedStringArray:
	var errors := PackedStringArray()
	if doc.objects.size() > MAX_OBJECTS:
		errors.append("%d objects exceed the limit of %d" % [doc.objects.size(), MAX_OBJECTS])
	for id in doc.sorted_object_ids():
		var r: ObjectRecord = doc.objects[id]
		var err := validate_object(r, catalog)
		if err == "" and r.object_id != id:
			err = "object stored under key %s has object_id %s" % [id, r.object_id]
		if err != "":
			errors.append(err)
	return errors


## Returns "" when the record is valid for the trusted catalog.
static func validate_object(r: ObjectRecord, catalog: AssetCatalog) -> String:
	if r == null:
		return "object record is null"
	if not ObjectRecord.is_uuid(r.object_id):
		return "object_id '%s' is not a lowercase UUID" % r.object_id
	var tag := " (object %s)" % r.object_id
	var a := catalog.get_asset(r.asset_id)
	if a == null:
		return "unknown asset '%s'%s" % [r.asset_id, tag]
	if a.version != r.asset_version:
		return "asset '%s' v%d is incompatible with trusted v%d%s" % [r.asset_id, r.asset_version, a.version, tag]
	var err := _validate_transform(r, a)
	if err != "":
		return err + tag
	if r.grounding != WorldConstants.GROUNDING_FOLLOW and r.grounding != WorldConstants.GROUNDING_FIXED:
		return "grounding '%s' is not allowed%s" % [r.grounding, tag]
	if r.origin != WorldConstants.ORIGIN_MANUAL and r.origin != WorldConstants.ORIGIN_SCATTER:
		return "origin '%s' is not allowed%s" % [r.origin, tag]
	if r.scatter_operation_id != "" and not ObjectRecord.is_uuid(r.scatter_operation_id):
		return "scatter_operation_id is not a UUID" + tag
	return ""


static func _validate_transform(r: ObjectRecord, a: AssetDefinition) -> String:
	if r.position.size() != 3 or r.rotation_xyzw.size() != 4:
		return "transform arrays malformed"
	for v in Array(r.position) + Array(r.rotation_xyzw):
		if not is_finite(v):
			return "transform has non-finite values"
	if not WorldConstants.is_inside_world(r.position[0], r.position[2]):
		return "position (%s, %s) is outside the world extent" % [r.position[0], r.position[2]]
	var q := r.rotation_xyzw
	var qlen := sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
	if absf(qlen - 1.0) > UNIT_QUAT_TOLERANCE:
		return "rotation_xyzw is not a unit quaternion"
	if not a.scale_in_range(r.uniform_scale):
		return "uniform_scale %s outside [%s, %s]" % [r.uniform_scale, a.scale_min, a.scale_max]
	if not a.height_offset_in_range(r.height_offset_m):
		return "height_offset_m %s outside [%s, %s]" % [r.height_offset_m, a.height_offset_min_m, a.height_offset_max_m]
	return ""


## FOLLOW_TERRAIN consistency report (docs/world-format.md §4). Report only: never re-snaps.
## Returns [{object_id, expected_y, actual_y, delta}] for |delta| > 1 mm (NAN delta when the
## terrain has no sample at the object's X/Z).
static func grounding_report(doc: WorldDocument, _catalog: AssetCatalog) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in doc.sorted_object_ids():
		var r: ObjectRecord = doc.objects[id]
		if r.grounding != WorldConstants.GROUNDING_FOLLOW:
			continue
		var expected := doc.sample_height(r.position[0], r.position[2]) + r.height_offset_m
		var actual: float = r.position[1]
		var delta := actual - expected
		if is_nan(delta) or absf(delta) > GROUNDING_TOLERANCE_M:
			out.append({"object_id": id, "expected_y": expected, "actual_y": actual, "delta": delta})
	return out
