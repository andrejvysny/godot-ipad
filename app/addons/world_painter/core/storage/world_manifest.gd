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
	if bytes.size() > int(WorldLimits.zip_envelope().max_manifest_bytes):
		return [{}, "manifest is %d bytes, limit %d" % [bytes.size(), int(WorldLimits.zip_envelope().max_manifest_bytes)]]
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return [{}, "invalid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]]
	var m: Variant = json.data
	if typeof(m) != TYPE_DICTIONARY:
		return [{}, "root is not an object"]
	var err := _check_header(m)
	if err == "":
		var limits := WorldLimits.for_schema(int(m.schema_version))
		if bytes.size() > int(limits.max_manifest_bytes):
			err = "manifest is %d bytes, limit %d" % [bytes.size(), int(limits.max_manifest_bytes)]
	if err == "":
		err = _check_asset_lock(m.asset_lock, m.payload_files) if int(m.schema_version) == WorldConstants.SCHEMA_VERSION_V4 \
			else _check_catalog(m.catalog)
	var layout: WorldLayout = null
	if err == "":
		var layout_result := _layout_of_terrain(m)
		layout = layout_result[0]
		err = layout_result[1]
	if err == "":
		err = _check_terrain(m.terrain, int(m.schema_version), layout)
	if err == "":
		err = _check_payloads(m.payload_files, int(m.schema_version), layout)
	if err == "" and not is_hex64(m.authored_content_hash):
		err = "authored_content_hash is missing or not a real sha256"
	return [{}, err] if err != "" else [m, ""]


static func _check_header(m: Dictionary) -> String:
	if not same(m.get("format"), WorldCodec.FORMAT):
		return "unknown format '%s' (expected '%s')" % [str(m.get("format")), WorldCodec.FORMAT]
	if not is_json_int(m.get("schema_version")) or not _is_supported_schema(int(m.schema_version)):
		return "unsupported schema_version %s (this build reads %d, %d and %d)" % [str(m.get("schema_version")),
			WorldConstants.SCHEMA_VERSION, WorldConstants.SCHEMA_VERSION_LAYOUT, WorldConstants.SCHEMA_VERSION_V4]
	var keys: Array = WorldCodec.MANIFEST_KEYS_V4 if int(m.schema_version) == WorldConstants.SCHEMA_VERSION_V4 \
		else WorldCodec.MANIFEST_KEYS
	var err := exact_keys(m, keys, "manifest")
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


static func _is_supported_schema(v: int) -> bool:
	return v == WorldConstants.SCHEMA_VERSION or v == WorldConstants.SCHEMA_VERSION_LAYOUT \
		or v == WorldConstants.SCHEMA_VERSION_V4


## Layout of a manifest that passed _check_header. Returns [WorldLayout, ""] or [null, error].
## Schema 2 is always the legacy layout; schema 3 reads terrain.layout and rejects the legacy one;
## schema 4 reads terrain.layout and accepts every valid layout.
static func _layout_of_terrain(m: Dictionary) -> Array:
	if int(m.schema_version) == WorldConstants.SCHEMA_VERSION:
		return [WorldLayout.legacy(), ""]
	if typeof(m.terrain) != TYPE_DICTIONARY:
		return [null, "terrain must be an object"]
	if not m.terrain.has("layout"):
		return [null, "terrain missing field 'layout'"]
	var parsed := WorldLayout.from_manifest(m.terrain.layout)
	if parsed[1] != "":
		return [null, parsed[1]]
	var layout: WorldLayout = parsed[0]
	if layout.is_legacy() and int(m.schema_version) == WorldConstants.SCHEMA_VERSION_LAYOUT:
		return [null, "schema 3 must not use the legacy 2x2 layout"]
	return [layout, ""]


## Layout of a manifest returned by parse() (already validated).
static func layout_of(m: Dictionary) -> WorldLayout:
	var parsed := _layout_of_terrain(m)
	return parsed[0] if parsed[0] != null else WorldLayout.legacy()


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


static func _check_asset_lock(a: Variant, payloads: Variant) -> String:
	if typeof(a) != TYPE_DICTIONARY:
		return "asset_lock must be an object"
	var err := exact_keys(a, ["path", "sha256"], "asset_lock")
	if err != "":
		return err
	if not same(a.path, WorldConstants.ASSET_LOCK_FILE):
		return "asset_lock.path must be '%s'" % WorldConstants.ASSET_LOCK_FILE
	if not is_hex64(a.sha256):
		return "asset_lock.sha256 is missing or not a real sha256"
	if typeof(payloads) == TYPE_ARRAY:
		for e: Variant in payloads:
			if typeof(e) == TYPE_DICTIONARY and same(e.get("path"), WorldConstants.ASSET_LOCK_FILE) \
					and not same(e.get("sha256"), a.sha256):
				return "asset_lock sha256 differs from the payload_files entry of '%s'" % WorldConstants.ASSET_LOCK_FILE
	return ""


static func _check_terrain(t: Variant, schema: int, layout: WorldLayout) -> String:
	if typeof(t) != TYPE_DICTIONARY:
		return "terrain must be an object"
	var keys: Array = WorldCodec.TERRAIN_KEYS if schema == WorldConstants.SCHEMA_VERSION else WorldCodec.TERRAIN_KEYS_V3
	var err := exact_keys(t, keys, "terrain")
	if err != "":
		return err
	if not _is_number(t.sample_spacing_m) or float(t.sample_spacing_m) != WorldConstants.SAMPLE_SPACING:
		return "unsupported terrain.sample_spacing_m %s" % str(t.sample_spacing_m)
	if not is_json_int(t.region_samples) or int(t.region_samples) != WorldConstants.REGION_SAMPLES:
		return "unsupported terrain.region_samples %s" % str(t.region_samples)
	if not _region_locations_match(t.region_locations, layout):
		return "terrain.region_locations must be exactly the %d regions of the layout %s" % [
			layout.region_total(), str(layout.to_manifest())]
	var enc := {"height_encoding": WorldConstants.HEIGHT_ENCODING,
		"control_encoding": WorldConstants.CONTROL_ENCODING, "control_schema": WorldConstants.CONTROL_SCHEMA,
		"color_encoding": WorldConstants.COLOR_ENCODING}
	for k in enc:
		if not same(t[k], enc[k]):
			return "unsupported terrain.%s '%s' (expected '%s')" % [k, str(t[k]), enc[k]]
	if typeof(t.material_slots) != TYPE_DICTIONARY or t.material_slots != WorldConstants.MATERIAL_SLOTS:
		return "unsupported terrain.material_slots %s (expected %s)" % [str(t.material_slots), str(WorldConstants.MATERIAL_SLOTS)]
	return TerrainRules.from_dict(t.rules)[1]


static func _region_locations_match(v: Variant, layout: WorldLayout) -> bool:
	var expected := layout.region_locations()
	if typeof(v) != TYPE_ARRAY or v.size() != expected.size():
		return false
	for i in v.size():
		var p: Variant = v[i]
		if typeof(p) != TYPE_ARRAY or p.size() != 2 or not is_json_int(p[0]) or not is_json_int(p[1]):
			return false
		if Vector2i(int(p[0]), int(p[1])) != expected[i]:
			return false
	return true


static func _check_payloads(v: Variant, schema: int, layout: WorldLayout) -> String:
	var expected := WorldCodec.payload_paths(layout, schema)
	if typeof(v) != TYPE_ARRAY or v.size() != expected.size():
		return "payload_files must list exactly the %d payload files" % expected.size()
	var total := 0
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
		if int(e.bytes) > WorldCodec.payload_limit(e.path, schema):
			return "payload %s is %d bytes, limit %d" % [e.path, int(e.bytes), WorldCodec.payload_limit(e.path, schema)]
		if not is_hex64(e.sha256):
			return "payload %s sha256 is missing or a placeholder" % e.path
		total += int(e.bytes)
	var max_total := int(WorldLimits.for_schema(schema).max_total_bytes)
	if total > max_total:
		return "payload files total %d bytes, limit %d" % [total, max_total]
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
