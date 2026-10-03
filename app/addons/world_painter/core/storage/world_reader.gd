class_name WorldReader
extends RefCounted
## Builds a WorldDocument from a verified generation (WorldCodec.load_verified): schema 4 directly,
## schema 2/3 through in-memory conversion to bundled bindings (ADR 0014 D1, D9). Never writes anything.


## `verified` = {manifest, files}. Returns [WorldDocument, ""] or [null, error].
static func read(verified: Dictionary, catalog: AssetCatalog) -> Array:
	var m: Dictionary = verified.manifest
	var schema := int(m.schema_version)
	var legacy := schema != WorldConstants.SCHEMA_VERSION_V4
	if legacy and (m.catalog.id != catalog.catalog_id or int(m.catalog.version) != catalog.catalog_version \
			or m.catalog.sha256 != catalog.sha256):
		return [null, "incompatible catalog '%s' v%d sha256 %s (trusted catalog is '%s' v%d sha256 %s)" % [
			m.catalog.id, int(m.catalog.version), m.catalog.sha256,
			catalog.catalog_id, catalog.catalog_version, catalog.sha256]]
	var doc := WorldDocument.new()
	doc.source_schema = schema
	doc.layout = WorldManifest.layout_of(m)
	doc.world_id = m.world_id
	doc.document_revision = int(m.document_revision)
	doc.rules = (TerrainRules.from_dict(m.terrain.rules))[0]
	doc.assets = WorldAssetLock.new(catalog)
	var files: Dictionary = verified.files
	var err := _read_regions(doc, files)
	if err == "" and not legacy:
		err = _read_lock(doc, files, catalog)
	if err == "":
		var obj_err := _read_objects_checked(doc, files[WorldCodec.OBJECTS_FILE], schema, catalog)
		err = "objects.json: " + obj_err if obj_err != "" else ""
	if err == "":
		err = _read_scatter(doc, files[WorldConstants.SCATTER_FILE], schema, catalog)
	if err == "":
		var paths := PathRecord.decode_all(files[WorldConstants.PATHS_FILE])
		err = paths[1]
		doc.paths = paths[0] if err == "" else {}
	if err == "":
		err = _check_hash(doc, files, m, legacy)
	if err == "":
		var errors := WorldValidator.validate(doc, catalog)
		err = "; ".join(errors)
	return [null, err] if err != "" else [doc, ""]


static func _read_regions(doc: WorldDocument, files: Dictionary) -> String:
	for loc in doc.layout.region_locations():
		var stem := WorldConstants.region_file_stem(loc)
		var r := RegionBuffers.new(loc)
		var err := r.set_from_bytes(files[stem + ".height.f32le"], files[stem + ".control.u32le"],
			files[stem + ".color.rgba8"])
		if err != "":
			return err
		doc.regions[loc] = r
	return ""


static func _read_lock(doc: WorldDocument, files: Dictionary, catalog: AssetCatalog) -> String:
	var decoded := WorldAssetLock.decode(files[WorldConstants.ASSET_LOCK_FILE], catalog)
	if decoded[1] != "":
		return decoded[1]
	doc.assets = decoded[0]
	return ""


static func _check_hash(doc: WorldDocument, files: Dictionary, m: Dictionary, legacy: bool) -> String:
	if legacy:
		var legacy_hash := CanonicalEncoder.legacy_authored_hash(doc)
		if legacy_hash[1] != "":
			return legacy_hash[1]
		return "" if legacy_hash[0] == m.authored_content_hash \
			else "authored_content_hash does not match the loaded content"
	var unreferenced := WorldValidator.unreferenced_binding_error(doc)
	if unreferenced != "":
		return unreferenced
	var lock := doc.assets.encode_referenced(doc)
	if lock[1] != "" or lock[0] != files[WorldConstants.ASSET_LOCK_FILE]:
		return "asset_locks.json is not the canonical lock of the referenced bindings"
	if CanonicalEncoder.authored_hash(doc) != m.authored_content_hash:
		return "authored_content_hash does not match the loaded content"
	return ""


static func _read_scatter(doc: WorldDocument, data: PackedByteArray, schema: int, catalog: AssetCatalog) -> String:
	var max_instances := int(WorldLimits.for_schema(schema).max_scatter_instances)
	if schema == WorldConstants.SCHEMA_VERSION_V4:
		var parsed := ScatterLayer.decode(data, max_instances)
		if parsed[1] == "":
			doc.scatter = parsed[0]
		return parsed[1]
	var legacy := ScatterLayer.decode_legacy_v1(data, max_instances)
	if legacy[1] != "":
		return legacy[1]
	var layer: ScatterLayer = legacy[0]
	var versions: PackedInt32Array = legacy[2]
	for i in layer.binding_ids.size():
		var asset := catalog.get_asset(layer.binding_ids[i])
		if asset == null:
			return "scatter uses unknown asset '%s'" % layer.binding_ids[i]
		if asset.version != versions[i]:
			return "scatter asset '%s' v%d is incompatible with trusted v%d" % [asset.asset_id, versions[i], asset.version]
		layer.binding_ids[i] = doc.assets.bundled_binding_for(asset.asset_id)
	doc.scatter = layer
	return ""


## Errors carry no file prefix; read() adds "objects.json: ".
static func _read_objects_checked(doc: WorldDocument, data: PackedByteArray, schema: int, catalog: AssetCatalog) -> String:
	var json := JSON.new()
	if json.parse(data.get_string_from_utf8()) != OK:
		return "invalid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]
	var root: Variant = json.data
	if typeof(root) != TYPE_DICTIONARY or root.size() != 2 or not root.has("schema_version") or not root.has("objects"):
		return "root must be exactly {schema_version, objects}"
	if not WorldManifest.is_json_int(root.schema_version) or int(root.schema_version) != schema:
		return "unsupported schema_version %s" % str(root.schema_version)
	if typeof(root.objects) != TYPE_ARRAY:
		return "objects must be an array"
	var max_objects := int(WorldLimits.for_schema(schema).max_objects)
	if root.objects.size() > max_objects:
		return "%d objects exceed the limit of %d" % [root.objects.size(), max_objects]
	var prev := ""
	for d in root.objects:
		var type_err := _enum_type_error(d)
		if type_err != "":
			return type_err
		var parsed := _parse_record(doc, d, schema == WorldConstants.SCHEMA_VERSION_V4, catalog)
		if parsed[1] != "":
			return parsed[1]
		var r: ObjectRecord = parsed[0]
		if prev != "" and not (prev < r.object_id):
			return "object ids are not sorted and unique at %s" % r.object_id
		prev = r.object_id
		doc.put_object(r)
	return ""


## Returns [ObjectRecord, ""] or [null, error]. Legacy records are mapped to bundled bindings of `catalog`.
static func _parse_record(doc: WorldDocument, d: Variant, is_v4: bool, catalog: AssetCatalog) -> Array:
	var parsed: Array = ObjectRecord.from_dict(d) if is_v4 else ObjectRecord.from_legacy_dict(d)
	# A script error inside the parser returns an empty Array; never treat that as success.
	if parsed.size() < 2 or typeof(parsed[1]) != TYPE_STRING:
		return [null, "object record could not be parsed"]
	if parsed[1] != "":
		return [null, parsed[1]]
	if not (parsed[0] is ObjectRecord):
		return [null, "object record could not be parsed"]
	var r: ObjectRecord = parsed[0]
	if is_v4:
		if not doc.assets.has_binding(r.binding_id):
			return [null, "object %s references unknown binding %s" % [r.object_id, r.binding_id]]
		return [r, ""]
	var asset := catalog.get_asset(parsed[2])
	if asset == null:
		return [null, "unknown asset '%s' (object %s)" % [parsed[2], r.object_id]]
	if asset.version != parsed[3]:
		return [null, "asset '%s' v%d is incompatible with trusted v%d (object %s)" % [
			parsed[2], parsed[3], asset.version, r.object_id]]
	r.binding_id = doc.assets.bundled_binding_for(asset.asset_id)
	return [r, ""]


## ObjectRecord parsers compare these fields with String constants, which is a script
## error (not a rejection) for any other JSON type, so reject non-strings first.
static func _enum_type_error(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return ""
	for key in ["grounding", "origin"]:
		if d.has(key) and typeof(d[key]) != TYPE_STRING:
			return "%s must be a string, got %s" % [key, type_string(typeof(d[key]))]
	return ""
