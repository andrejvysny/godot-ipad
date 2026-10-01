class_name WorldManifest
extends RefCounted
## Strict manifest.json parser (docs/world-format.md §3). Exact key sets, integral integers
## (JSON numbers arrive as floats), exact terrain block, exact payload set with real hashes.
## Unknown format/schema fails with an explicit diagnostic; nothing is remapped.

const HEX64_PATTERN := "^[0-9a-f]{64}$"
const PLACEHOLDER_HASH := "0000000000000000000000000000000000000000000000000000000000000000"


## Returns [Dictionary, ""] or [{}, error]. The dictionary is the parsed JSON (numbers are
## floats); callers convert with int() after this check has proven them integral.
static func parse(bytes: PackedByteArray) -> Array:
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return [{}, "invalid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]]
	var m: Variant = json.data
	if typeof(m) != TYPE_DICTIONARY:
		return [{}, "root is not an object"]
	var err := _check_header(m)
	if err == "":
		err = _check_catalog(m.catalog)
	if err == "":
		err = _check_terrain(m.terrain)
	if err == "":
		err = _check_payloads(m.payload_files)
	if err == "" and not is_hex64(m.authored_content_hash):
		err = "authored_content_hash is missing or not a real sha256"
	return [{}, err] if err != "" else [m, ""]


static func _check_header(m: Dictionary) -> String:
	if not same(m.get("format"), WorldCodec.FORMAT):
		return "unknown format '%s' (expected '%s')" % [str(m.get("format")), WorldCodec.FORMAT]
	if not is_json_int(m.get("schema_version")) or int(m.schema_version) != WorldConstants.SCHEMA_VERSION:
		return "unsupported schema_version %s (this build reads %d)" % [str(m.get("schema_version")), WorldConstants.SCHEMA_VERSION]
	var err := exact_keys(m, WorldCodec.MANIFEST_KEYS, "manifest")
	if err != "":
		return err
	if typeof(m.world_id) != TYPE_STRING or not ObjectRecord.is_uuid(m.world_id):
		return "world_id is not a lowercase UUID"
	if not is_json_int(m.document_revision) or float(m.document_revision) < 0.0:
		return "document_revision must be a non-negative integer"
	if typeof(m.created_with) != TYPE_DICTIONARY:
		return "created_with must be an object"
	err = exact_keys(m.created_with, WorldCodec.CREATED_WITH_KEYS, "created_with")
	if err != "":
		return err
	for k in WorldCodec.CREATED_WITH_KEYS:
		if typeof(m.created_with[k]) != TYPE_STRING or m.created_with[k] == "":
			return "created_with.%s must be a non-empty string" % k
	return ""


static func _check_catalog(c: Variant) -> String:
	if typeof(c) != TYPE_DICTIONARY:
		return "catalog must be an object"
	var err := exact_keys(c, WorldCodec.CATALOG_KEYS, "catalog")
	if err != "":
		return err
	if typeof(c.id) != TYPE_STRING or c.id == "":
		return "catalog.id must be a non-empty string"
	if not is_json_int(c.version) or float(c.version) < 1.0:
		return "catalog.version must be a positive integer"
	if not is_hex64(c.sha256):
		return "catalog.sha256 is missing or not a real sha256"
	return ""


static func _check_terrain(t: Variant) -> String:
	if typeof(t) != TYPE_DICTIONARY:
		return "terrain must be an object"
	var err := exact_keys(t, WorldCodec.TERRAIN_KEYS, "terrain")
	if err != "":
		return err
	if not _is_number(t.sample_spacing_m) or float(t.sample_spacing_m) != WorldConstants.SAMPLE_SPACING:
		return "unsupported terrain.sample_spacing_m %s" % str(t.sample_spacing_m)
	if not is_json_int(t.region_samples) or int(t.region_samples) != WorldConstants.REGION_SAMPLES:
		return "unsupported terrain.region_samples %s" % str(t.region_samples)
	if not _region_locations_match(t.region_locations):
		return "terrain.region_locations must be exactly %s" % str(WorldConstants.REGION_LOCATIONS)
	var enc := {"height_encoding": WorldConstants.HEIGHT_ENCODING,
		"control_encoding": WorldConstants.CONTROL_ENCODING, "control_schema": WorldConstants.CONTROL_SCHEMA}
	for k in enc:
		if not same(t[k], enc[k]):
			return "unsupported terrain.%s '%s' (expected '%s')" % [k, str(t[k]), enc[k]]
	if typeof(t.material_slots) != TYPE_DICTIONARY or t.material_slots != WorldConstants.MATERIAL_SLOTS:
		return "unsupported terrain.material_slots %s (expected %s)" % [str(t.material_slots), str(WorldConstants.MATERIAL_SLOTS)]
	return ""


static func _region_locations_match(v: Variant) -> bool:
	if typeof(v) != TYPE_ARRAY or v.size() != WorldConstants.REGION_LOCATIONS.size():
		return false
	for i in v.size():
		var p: Variant = v[i]
		if typeof(p) != TYPE_ARRAY or p.size() != 2 or not is_json_int(p[0]) or not is_json_int(p[1]):
			return false
		if Vector2i(int(p[0]), int(p[1])) != WorldConstants.REGION_LOCATIONS[i]:
			return false
	return true


static func _check_payloads(v: Variant) -> String:
	var expected := WorldCodec.payload_paths()
	if typeof(v) != TYPE_ARRAY or v.size() != expected.size():
		return "payload_files must list exactly the %d payload files" % expected.size()
	for i in v.size():
		var e: Variant = v[i]
		if typeof(e) != TYPE_DICTIONARY:
			return "payload_files[%d] is not an object" % i
		var err := exact_keys(e, WorldCodec.PAYLOAD_KEYS, "payload_files[%d]" % i)
		if err != "":
			return err
		if not same(e.path, expected[i]):
			return "payload_files[%d] is '%s', expected '%s' (exact set, sorted by path)" % [i, str(e.path), expected[i]]
		if not is_json_int(e.bytes) or float(e.bytes) < 0.0:
			return "payload %s bytes must be a non-negative integer" % e.path
		if WorldCodec.is_region_path(e.path) and int(e.bytes) != WorldConstants.REGION_MAP_BYTES:
			return "payload %s must be %d bytes, manifest says %d" % [e.path, WorldConstants.REGION_MAP_BYTES, int(e.bytes)]
		if not is_hex64(e.sha256):
			return "payload %s sha256 is missing or a placeholder" % e.path
	return ""


static func exact_keys(d: Dictionary, keys: Array, what: String) -> String:
	for k in keys:
		if not d.has(k):
			return "%s missing field '%s'" % [what, k]
	for k in d:
		if not keys.has(k):
			return "%s has unknown field '%s'" % [what, str(k)]
	return ""


## Type-checked equality: `==` between mismatched Variant types is a runtime script error.
static func same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


static func is_hex64(v: Variant) -> bool:
	return typeof(v) == TYPE_STRING and v != PLACEHOLDER_HASH \
		and RegEx.create_from_string(HEX64_PATTERN).search(v) != null


static func _is_number(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func is_json_int(v: Variant) -> bool:
	return _is_number(v) and float(v) == floorf(float(v)) and absf(float(v)) <= WorldCodec.MAX_JSON_INT
