class_name WorldValidator
extends RefCounted
## Semantic validation of an authored world against the trusted catalog (spec §17.5,
## docs/world-format.md §4, §7). Returns diagnostics; never modifies the document.

const UNIT_QUAT_TOLERANCE := 1e-6
const GROUNDING_TOLERANCE_M := 1e-3
## Ids < 4 need base bits 29-31 (0xE0000000) and overlay bits 24-26 (0x07000000) clear
## (ids occupy bits 27-31 / 22-26). Fast path; ControlCodec stays authoritative for anything
## this mask flags.
const CONTROL_UNSUPPORTED_FAST_MASK := 0xE7000000
const MAX_ERRORS_PER_REGION := 1
const MAX_SCATTER_ERRORS := 5


## Structural errors only (ADR 0014 D8): format, limits, lock identity, records against the effective
## (policy) limits of their bindings. Unavailable bindings are not errors; see availability().
static func validate(doc: WorldDocument, catalog: AssetCatalog) -> PackedStringArray:
	var errors := PackedStringArray()
	if doc == null:
		errors.append("document is null")
		return errors
	if doc.layout == null:
		errors.append("document has no layout")
		return errors
	var layout_err := WorldLayout.validate(doc.layout.min_region, doc.layout.region_count)
	if layout_err != "":
		errors.append("invalid layout: " + layout_err)
		return errors
	if doc.schema_version != WorldConstants.SCHEMA_VERSION_V4:
		errors.append("unsupported schema_version %d (documents are schema %d)" % [
			doc.schema_version, WorldConstants.SCHEMA_VERSION_V4])
		return errors
	if catalog == null:
		errors.append("no trusted catalog loaded")
	var limits := WorldLimits.for_schema(doc.schema_version)
	errors.append_array(_validate_regions(doc))
	var rules_err := "rules are missing" if doc.rules == null else doc.rules.range_error()
	if rules_err != "":
		errors.append(rules_err)
	if catalog != null:
		var lock_errors := _validate_lock(doc, catalog, limits)
		errors.append_array(lock_errors)
		errors.append_array(_validate_objects(doc, limits))
		errors.append_array(_validate_scatter(doc.scatter, doc.assets, doc.layout, limits))
	errors.append_array(_validate_paths(doc))
	return errors


## {"unavailable": {binding_id: reason}} for the bindings `doc` references (ADR 0014 D8).
static func availability(doc: WorldDocument) -> Dictionary:
	return doc.assets.availability(doc)


## Referenced bindings exist, and the policy of an available bundled binding stays within the catalog entry.
static func _validate_lock(doc: WorldDocument, catalog: AssetCatalog, limits: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var ids := doc.assets.referenced_ids(doc)
	if ids.size() > int(limits.max_bindings):
		errors.append("%d referenced bindings exceed the limit of %d" % [ids.size(), int(limits.max_bindings)])
		return errors
	for id in ids:
		var b := doc.assets.get_binding(id)
		if b == null:
			errors.append("unknown binding '%s'" % id)
		elif b.is_bundled():
			var err := _bundled_policy_error(b, catalog)
			if err != "":
				errors.append(err)
	return errors


static func _bundled_policy_error(b: AssetBinding, catalog: AssetCatalog) -> String:
	if b.catalog_id != catalog.catalog_id or b.catalog_version != catalog.catalog_version \
			or b.catalog_sha256 != catalog.sha256:
		return ""
	var def := catalog.get_asset(b.asset_id)
	if def == null or def.version != b.asset_version:
		return ""
	var tag := " (binding %s)" % b.binding_id
	if b.scale_min < def.scale_min - AssetBinding.eps_of(def.scale_min) \
			or b.scale_max > def.scale_max + AssetBinding.eps_of(def.scale_max):
		return "policy scale_range outside catalog limits of '%s'%s" % [b.asset_id, tag]
	if b.height_offset_min_m < def.height_offset_min_m - AssetBinding.eps_of(def.height_offset_min_m) \
			or b.height_offset_max_m > def.height_offset_max_m + AssetBinding.eps_of(def.height_offset_max_m):
		return "policy height_offset_range_m outside catalog limits of '%s'%s" % [b.asset_id, tag]
	if b.scatter_allowed and not (def.scatter_allowed and def.scatter_mesh != ""):
		return "policy scatter_allowed is true for '%s', which the catalog does not allow%s" % [b.asset_id, tag]
	return ""


## "" when every binding the lock holds is referenced (a serialized lock lists only referenced bindings).
static func unreferenced_binding_error(doc: WorldDocument) -> String:
	var referenced := {}
	for id in doc.assets.referenced_ids(doc):
		referenced[id] = true
	for id in doc.assets.ids():
		if not referenced.has(id):
			return "asset lock binding %s is not referenced by any object record or scatter instance" % id
	return ""


static func _validate_regions(doc: WorldDocument) -> PackedStringArray:
	var errors := PackedStringArray()
	for loc in doc.regions:
		if not doc.layout.is_valid_region(loc):
			errors.append("unexpected region %s" % str(loc))
	for loc in doc.layout.region_locations():
		var r: RegionBuffers = doc.regions.get(loc)
		if r == null:
			errors.append("missing region %s" % str(loc))
			continue
		if r.heights.size() != WorldConstants.REGION_SAMPLE_COUNT or r.control.size() != WorldConstants.REGION_SAMPLE_COUNT \
				or r.color.size() != WorldConstants.REGION_MAP_BYTES:
			errors.append("region %s buffers have %d/%d samples and %d color bytes, expected %d/%d" % [
				str(loc), r.heights.size(), r.control.size(), r.color.size(),
				WorldConstants.REGION_SAMPLE_COUNT, WorldConstants.REGION_MAP_BYTES])
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


static func _validate_objects(doc: WorldDocument, limits: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if doc.objects.size() > int(limits.max_objects):
		errors.append("%d objects exceed the limit of %d" % [doc.objects.size(), int(limits.max_objects)])
		return errors
	for id in doc.sorted_object_ids():
		var r: ObjectRecord = doc.objects[id]
		var err := validate_object(r, doc.assets, doc.layout)
		if err == "" and r.object_id != id:
			err = "object stored under key %s has object_id %s" % [id, r.object_id]
		if err != "":
			errors.append(err)
	return errors


static func _validate_scatter(layer: ScatterLayer, assets: WorldAssetLock, layout: WorldLayout,
		limits: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if layer == null:
		errors.append("scatter layer is missing")
		return errors
	var n := layer.count()
	if layer.flags.size() != n or layer.x.size() != n or layer.z.size() != n \
			or layer.yaw.size() != n or layer.scale.size() != n:
		errors.append("scatter arrays have inconsistent lengths")
		return errors
	if n > int(limits.max_scatter_instances):
		errors.append("%d scatter instances exceed the limit of %d" % [n, int(limits.max_scatter_instances)])
		return errors
	var slot_ok := {}  # slot -> AssetBinding or null
	for i in n:
		if errors.size() >= MAX_SCATTER_ERRORS:
			break
		var s := layer.slot[i]
		if s < 0 or s >= layer.binding_ids.size():
			errors.append("scatter instance %d slot %d is out of range" % [i, s])
			continue
		if not slot_ok.has(s):
			slot_ok[s] = _scatter_binding(layer.binding_ids[s], assets, errors)
		var b: AssetBinding = slot_ok[s]
		if b != null:
			var err := _scatter_instance_error(layer, i, b, layout)
			if err != "":
				errors.append(err)
	return errors


## Returns the binding when it may be scattered, else null and appends the reason.
static func _scatter_binding(id: String, assets: WorldAssetLock, errors: PackedStringArray) -> AssetBinding:
	var b := assets.get_binding(id)
	if b == null:
		errors.append("scatter uses unknown binding '%s'" % id)
	elif not b.scatter_allowed:
		errors.append("scatter binding '%s' is not scatter_allowed" % id)
	else:
		return b
	return null


static func _scatter_instance_error(layer: ScatterLayer, i: int, b: AssetBinding, layout: WorldLayout) -> String:
	if (layer.flags[i] & ~ScatterLayer.FLAGS_ALLOWED) != 0:
		return "scatter instance %d has unknown flag bits 0x%x" % [i, layer.flags[i]]
	var px := layer.x[i]
	var pz := layer.z[i]
	if not (is_finite(px) and is_finite(pz)) or not layout.is_inside_world(px, pz):
		return "scatter instance %d position (%s, %s) is outside the world extent" % [i, px, pz]
	if not (absf(layer.yaw[i]) <= WorldConstants.YAW_LIMIT):
		return "scatter instance %d yaw %s is not finite within +-%s" % [i, layer.yaw[i], WorldConstants.YAW_LIMIT]
	if not b.in_scale(layer.scale[i]):
		return "scatter instance %d scale %s outside [%s, %s]" % [i, layer.scale[i], b.scale_min, b.scale_max]
	return ""


static func _validate_paths(doc: WorldDocument) -> PackedStringArray:
	var errors := PackedStringArray()
	if doc.paths.size() > WorldConstants.MAX_PATHS:
		errors.append("%d paths exceed the limit of %d" % [doc.paths.size(), WorldConstants.MAX_PATHS])
	for id in doc.sorted_path_ids():
		var err := validate_path(doc.paths[id], doc.layout)
		if err == "" and doc.paths[id].path_id != id:
			err = "path stored under key %s has path_id %s" % [id, doc.paths[id].path_id]
		if err != "":
			errors.append(err)
	return errors


## Returns "" when the path satisfies docs/world-format.md §6.
static func validate_path(p: PathRecord, layout: WorldLayout) -> String:
	if p == null:
		return "path record is null"
	if not ObjectRecord.is_uuid(p.path_id):
		return "path_id '%s' is not a lowercase UUID" % p.path_id
	var tag := " (path %s)" % p.path_id
	if not (p.width_m >= WorldConstants.PATH_WIDTH_MIN and p.width_m <= WorldConstants.PATH_WIDTH_MAX):
		return "width_m %s outside [%s, %s]%s" % [p.width_m, WorldConstants.PATH_WIDTH_MIN, WorldConstants.PATH_WIDTH_MAX, tag]
	if p.points.size() < WorldConstants.PATH_POINTS_MIN or p.points.size() > WorldConstants.PATH_POINTS_MAX:
		return "%d points, allowed %d..%d%s" % [p.points.size(), WorldConstants.PATH_POINTS_MIN, WorldConstants.PATH_POINTS_MAX, tag]
	for pt in p.points:
		if not (is_finite(pt.x) and is_finite(pt.y)) or not layout.is_inside_world(pt.x, pt.y):
			return "point (%s, %s) is outside the world extent%s" % [pt.x, pt.y, tag]
	return ""


## Returns "" when the record is valid against the effective limits of its binding.
static func validate_object(r: ObjectRecord, assets: WorldAssetLock, layout: WorldLayout) -> String:
	if r == null:
		return "object record is null"
	if not ObjectRecord.is_uuid(r.object_id):
		return "object_id '%s' is not a lowercase UUID" % r.object_id
	var tag := " (object %s)" % r.object_id
	var b := assets.get_binding(r.binding_id)
	if b == null:
		return "unknown binding '%s'%s" % [r.binding_id, tag]
	var err := _validate_transform(r, b, layout)
	if err != "":
		return err + tag
	if r.grounding != WorldConstants.GROUNDING_FOLLOW and r.grounding != WorldConstants.GROUNDING_FIXED:
		return "grounding '%s' is not allowed%s" % [r.grounding, tag]
	if r.origin != WorldConstants.ORIGIN_MANUAL and r.origin != WorldConstants.ORIGIN_SCATTER:
		return "origin '%s' is not allowed%s" % [r.origin, tag]
	if r.scatter_operation_id != "" and not ObjectRecord.is_uuid(r.scatter_operation_id):
		return "scatter_operation_id is not a UUID" + tag
	return ""


static func _validate_transform(r: ObjectRecord, b: AssetBinding, layout: WorldLayout) -> String:
	if r.position.size() != 3 or r.rotation_xyzw.size() != 4:
		return "transform arrays malformed"
	for v in Array(r.position) + Array(r.rotation_xyzw):
		if not is_finite(v):
			return "transform has non-finite values"
	if not layout.is_inside_world(r.position[0], r.position[2]):
		return "position (%s, %s) is outside the world extent" % [r.position[0], r.position[2]]
	var q := r.rotation_xyzw
	var qlen := sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
	if absf(qlen - 1.0) > UNIT_QUAT_TOLERANCE:
		return "rotation_xyzw is not a unit quaternion"
	if not b.in_scale(r.uniform_scale):
		return "uniform_scale %s outside [%s, %s]" % [r.uniform_scale, b.scale_min, b.scale_max]
	if not b.in_height_offset(r.height_offset_m):
		return "height_offset_m %s outside [%s, %s]" % [r.height_offset_m, b.height_offset_min_m, b.height_offset_max_m]
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
