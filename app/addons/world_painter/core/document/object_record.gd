class_name ObjectRecord
extends RefCounted
## Persistent placed-object record (spec §10.4). Values are float64 (GDScript float), not
## Vector3/Quaternion, because those are float32 and would lose precision in the saved file.
## `position` is the world position of the asset's placement anchor; the scene node origin is
## derived as position - (rotation * scale) * anchor_local by the presenter.
## Treat instances as values: clone() before changing anything that history may reference.

const FIELDS_V4 := ["object_id", "binding_id", "position", "rotation_xyzw", "uniform_scale", "grounding",
	"height_offset_m", "origin", "scatter_operation_id", "f64le"]
const UUID_PATTERN := "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

var object_id: String = ""
var binding_id: String = ""  # key into WorldDocument.assets (ADR 0014)
var position := PackedFloat64Array([0.0, 0.0, 0.0])
var rotation_xyzw := PackedFloat64Array([0.0, 0.0, 0.0, 1.0])
var uniform_scale: float = 1.0
var grounding: String = WorldConstants.GROUNDING_FOLLOW
var height_offset_m: float = 0.0
var origin: String = WorldConstants.ORIGIN_MANUAL
var scatter_operation_id: String = ""  # "" means none (null in JSON)


static func new_uuid_v4() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


func clone() -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = object_id
	r.binding_id = binding_id
	r.position = position.duplicate()
	r.rotation_xyzw = rotation_xyzw.duplicate()
	r.uniform_scale = uniform_scale
	r.grounding = grounding
	r.height_offset_m = height_offset_m
	r.origin = origin
	r.scatter_operation_id = scatter_operation_id
	return r


func equals(other: ObjectRecord) -> bool:
	return other != null and object_id == other.object_id and binding_id == other.binding_id \
		and position == other.position \
		and rotation_xyzw == other.rotation_xyzw and uniform_scale == other.uniform_scale \
		and grounding == other.grounding and height_offset_m == other.height_offset_m \
		and origin == other.origin and scatter_operation_id == other.scatter_operation_id


func get_position_v3() -> Vector3:
	return Vector3(position[0], position[1], position[2])


func set_position(x: float, y: float, z: float) -> void:
	position = PackedFloat64Array([x, y, z])


## Yaw about +Y in radians. The file keeps a full quaternion so later formats need no
## Euler-order assumption; the PoC only edits yaw.
func get_yaw() -> float:
	return 2.0 * atan2(rotation_xyzw[1], rotation_xyzw[3])


func set_yaw(yaw: float) -> void:
	rotation_xyzw = PackedFloat64Array([0.0, sin(yaw * 0.5), 0.0, cos(yaw * 0.5)])


func get_quaternion() -> Quaternion:
	return Quaternion(rotation_xyzw[0], rotation_xyzw[1], rotation_xyzw[2], rotation_xyzw[3])


## Scene-node transform for an asset whose placement anchor is `anchor_local`.
## Anchor is applied after rotation and scale (spec §14.3).
func node_transform(anchor_local: Vector3) -> Transform3D:
	var basis := Basis(get_quaternion().normalized()).scaled(Vector3.ONE * uniform_scale)
	return Transform3D(basis, get_position_v3() - basis * anchor_local)


## Decimal fields are for readability; `f64le` holds the exact IEEE-754 bits (little-endian
## hex) because Godot 4.7's JSON number parser is not correctly rounded (ADR 0003).
func to_dict() -> Dictionary:
	return {
		"object_id": object_id,
		"binding_id": binding_id,
		"position": [position[0], position[1], position[2]],
		"rotation_xyzw": [rotation_xyzw[0], rotation_xyzw[1], rotation_xyzw[2], rotation_xyzw[3]],
		"uniform_scale": uniform_scale,
		"grounding": grounding,
		"height_offset_m": height_offset_m,
		"origin": origin,
		"scatter_operation_id": scatter_operation_id if scatter_operation_id != "" else null,
		"f64le": {
			"position": [f64_hex(position[0]), f64_hex(position[1]), f64_hex(position[2])],
			"rotation_xyzw": [f64_hex(rotation_xyzw[0]), f64_hex(rotation_xyzw[1]),
				f64_hex(rotation_xyzw[2]), f64_hex(rotation_xyzw[3])],
			"uniform_scale": f64_hex(uniform_scale),
			"height_offset_m": f64_hex(height_offset_m),
		},
	}


static func f64_hex(v: float) -> String:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, v)
	return b.hex_encode()


## Returns NAN for malformed input (callers reject non-finite values anyway).
static func f64_from_hex(h: Variant) -> float:
	if typeof(h) != TYPE_STRING or h.length() != 16 or not h.is_valid_hex_number(false):
		return NAN
	return h.hex_decode().decode_double(0)


## Exact value from `bits` if it agrees with the readable decimal; NAN otherwise.
static func _exact(decimal: float, bits: Variant) -> float:
	var v := f64_from_hex(bits)
	if not is_finite(v) or absf(v - decimal) > 1e-9 * maxf(1.0, absf(decimal)):
		return NAN
	return v


## Structural parse of a schema 4 record; the binding must exist in the lock (checked by the codec).
## Returns [ObjectRecord, ""] on success or [null, error].
static func from_dict(d: Variant) -> Array:
	var parsed := _parse(d, false)
	return [parsed[0], parsed[1]]


## Schema 2/3 record: returns [ObjectRecord (binding_id empty), "", asset_id, asset_version] or
## [null, error, "", 0]. The codec maps the catalog asset to a bundled binding.
static func from_legacy_dict(d: Variant) -> Array:
	return _parse(d, true)


static func _parse(d: Variant, legacy: bool) -> Array:
	var fail := func(msg: String) -> Array: return [null, msg, "", 0]
	if typeof(d) != TYPE_DICTIONARY:
		return fail.call("object record is not an object")
	var required := ["object_id", "asset_id", "asset_version", "position", "rotation_xyzw",
		"uniform_scale", "grounding", "height_offset_m", "origin", "scatter_operation_id"] if legacy \
		else FIELDS_V4.filter(func(k: String) -> bool: return k != "f64le")
	for key in required:
		if not d.has(key):
			return fail.call("object record missing field '%s'" % key)
	if not legacy:
		for key in d:
			if not FIELDS_V4.has(key):
				return fail.call("object record has unknown field '%s'" % str(key))
	var r := ObjectRecord.new()
	if typeof(d.object_id) != TYPE_STRING or not is_uuid(d.object_id):
		return fail.call("object_id is not a lowercase UUID")
	r.object_id = d.object_id
	var tag := " (object %s)" % r.object_id
	var legacy_id := ""
	var legacy_version := 0
	if legacy:
		if typeof(d.asset_id) != TYPE_STRING or d.asset_id == "":
			return fail.call("asset_id must be a non-empty string" + tag)
		if not _is_json_int(d.asset_version) or int(d.asset_version) < 1:
			return fail.call("asset_version must be a positive integer" + tag)
		legacy_id = d.asset_id
		legacy_version = int(d.asset_version)
	else:
		if typeof(d.binding_id) != TYPE_STRING or not AssetBinding.is_valid_id(d.binding_id):
			return fail.call("binding_id must be b + 32 lowercase hex digits" + tag)
		r.binding_id = d.binding_id
	var err := _parse_fields(r, d, tag)
	return [null, err, "", 0] if err != "" else [r, "", legacy_id, legacy_version]


static func _parse_fields(r: ObjectRecord, d: Dictionary, tag: String) -> String:
	var pos: Variant = _finite_array(d.position, 3)
	if pos == null:
		return "position must be 3 finite numbers" + tag
	r.position = pos
	var rot: Variant = _finite_array(d.rotation_xyzw, 4)
	if rot == null:
		return "rotation_xyzw must be 4 finite numbers" + tag
	r.rotation_xyzw = rot
	var qlen := sqrt(rot[0] * rot[0] + rot[1] * rot[1] + rot[2] * rot[2] + rot[3] * rot[3])
	if absf(qlen - 1.0) > 1e-6:
		return "rotation_xyzw is not a unit quaternion" + tag
	if not _is_finite_number(d.uniform_scale) or float(d.uniform_scale) <= 0.0:
		return "uniform_scale must be a positive finite number" + tag
	r.uniform_scale = float(d.uniform_scale)
	if typeof(d.grounding) != TYPE_STRING or d.grounding not in [WorldConstants.GROUNDING_FOLLOW, WorldConstants.GROUNDING_FIXED]:
		return "grounding '%s' is not allowed%s" % [str(d.grounding), tag]
	r.grounding = d.grounding
	if not _is_finite_number(d.height_offset_m):
		return "height_offset_m must be finite" + tag
	r.height_offset_m = float(d.height_offset_m)
	if typeof(d.origin) != TYPE_STRING or d.origin not in [WorldConstants.ORIGIN_MANUAL, WorldConstants.ORIGIN_SCATTER]:
		return "origin '%s' is not allowed%s" % [str(d.origin), tag]
	r.origin = d.origin
	if d.scatter_operation_id == null:
		r.scatter_operation_id = ""
	elif typeof(d.scatter_operation_id) == TYPE_STRING and is_uuid(d.scatter_operation_id):
		r.scatter_operation_id = d.scatter_operation_id
	else:
		return "scatter_operation_id must be null or a UUID" + tag
	var err := _apply_exact_bits(r, d.get("f64le"))
	return err + tag if err != "" else ""


static func _apply_exact_bits(r: ObjectRecord, bits: Variant) -> String:
	if typeof(bits) != TYPE_DICTIONARY:
		return "f64le exact-value block missing"
	if typeof(bits.get("position")) != TYPE_ARRAY or bits.position.size() != 3 \
			or typeof(bits.get("rotation_xyzw")) != TYPE_ARRAY or bits.rotation_xyzw.size() != 4:
		return "f64le arrays malformed"
	for i in 3:
		r.position[i] = _exact(r.position[i], bits.position[i])
	for i in 4:
		r.rotation_xyzw[i] = _exact(r.rotation_xyzw[i], bits.rotation_xyzw[i])
	r.uniform_scale = _exact(r.uniform_scale, bits.get("uniform_scale"))
	r.height_offset_m = _exact(r.height_offset_m, bits.get("height_offset_m"))
	for v in [r.uniform_scale, r.height_offset_m] + Array(r.position) + Array(r.rotation_xyzw):
		if not is_finite(v):
			return "f64le exact bits missing or disagree with decimal fields"
	return ""


static func is_uuid(s: String) -> bool:
	var re := RegEx.create_from_string(UUID_PATTERN)
	return re.search(s) != null


static func _is_finite_number(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func _is_json_int(v: Variant) -> bool:
	return _is_finite_number(v) and float(v) == floorf(float(v))


static func _finite_array(v: Variant, n: int) -> Variant:
	if typeof(v) != TYPE_ARRAY or v.size() != n:
		return null
	var out := PackedFloat64Array()
	for x in v:
		if not _is_finite_number(x):
			return null
		out.append(float(x))
	return out
