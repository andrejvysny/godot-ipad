class_name WorldCodec
extends RefCounted
## Generation directory reader/writer (docs/world-format.md §2-§6). Writing is split into a
## main-thread snapshot (plain values only) and write_snapshot(), which the storage worker
## runs without ever touching a WorldDocument. Reading always builds a NEW document.

const FORMAT := "world-painter-poc"
const MANIFEST_FILE := "manifest.json"
const OBJECTS_FILE := "objects.json"
const TERRAIN3D_VERSION := "1.0.2-stable@0077405b"
const MANIFEST_KEYS := ["format", "schema_version", "world_id", "document_revision", "created_with",
	"catalog", "terrain", "payload_files", "authored_content_hash"]
const CREATED_WITH_KEYS := ["godot", "terrain3d", "world_painter"]
const CATALOG_KEYS := ["id", "version", "sha256"]
const TERRAIN_KEYS := ["sample_spacing_m", "region_samples", "region_locations", "height_encoding",
	"control_encoding", "control_schema", "color_encoding", "material_slots", "rules"]
const TERRAIN_KEYS_V3 := ["sample_spacing_m", "region_samples", "region_locations", "height_encoding",
	"control_encoding", "control_schema", "color_encoding", "material_slots", "rules", "layout"]
const PAYLOAD_KEYS := ["path", "bytes", "sha256"]
const MAX_JSON_INT := 9007199254740992.0  # 2^53: larger JSON numbers are not exact integers


## The payload paths (3 + 3 per region), sorted byte-wise (the order payload_files must use).
## A null layout means the legacy 2x2 layout (15 paths).
static func payload_paths(layout: WorldLayout = null) -> PackedStringArray:
	var out := PackedStringArray([OBJECTS_FILE, WorldConstants.SCATTER_FILE, WorldConstants.PATHS_FILE])
	var locs := layout.region_locations() if layout != null else WorldConstants.REGION_LOCATIONS
	for loc in locs:
		var stem := WorldConstants.region_file_stem(loc)
		out.append(stem + ".height.f32le")
		out.append(stem + ".control.u32le")
		out.append(stem + ".color.rgba8")
	out.sort()
	return out


## Largest allowed byte length of a payload file under the schema's limits (WorldLimits).
static func payload_limit(path: String, schema: int = WorldConstants.SCHEMA_VERSION) -> int:
	if is_region_path(path):
		return WorldConstants.REGION_MAP_BYTES
	var limits := WorldLimits.for_schema(schema)
	match path:
		OBJECTS_FILE:
			return int(limits.get("max_objects_bytes", 0))
		WorldConstants.SCATTER_FILE:
			return int(limits.get("max_scatter_bytes", 0))
		WorldConstants.PATHS_FILE:
			return int(limits.get("max_paths_bytes", 0))
	return 0


static func is_region_path(path: String) -> bool:
	return path.begins_with("regions/")


## Main thread only (reads Engine/ProjectSettings).
static func default_created_with() -> Dictionary:
	var v := Engine.get_version_info()
	return {
		"godot": "%d.%d.%d.%s.%s.%s" % [v.major, v.minor, v.patch, v.status, v.build, String(v.hash).left(9)],
		"terrain3d": TERRAIN3D_VERSION,
		"world_painter": str(ProjectSettings.get_setting("application/config/version", "unknown")),
	}


static func objects_json_bytes(doc: WorldDocument) -> PackedByteArray:
	var records: Array = []
	for id in doc.sorted_object_ids():
		records.append(doc.get_object(id).to_dict())
	var data := {"schema_version": doc.layout.schema_version(), "objects": records}
	return JSON.stringify(data, "  ", true, true).to_utf8_buffer()


## Copies everything a checkpoint needs into plain values (no references into `doc`).
static func snapshot(doc: WorldDocument, created_with: Dictionary) -> Dictionary:
	var files := {
		OBJECTS_FILE: objects_json_bytes(doc),
		WorldConstants.SCATTER_FILE: doc.scatter.encode(),
		WorldConstants.PATHS_FILE: PathRecord.encode_all(doc.paths),
	}
	for loc in doc.layout.region_locations():
		var r := doc.get_region(loc)
		var stem := WorldConstants.region_file_stem(loc)
		files[stem + ".height.f32le"] = r.height_bytes() if r != null else PackedByteArray()
		files[stem + ".control.u32le"] = r.control_bytes() if r != null else PackedByteArray()
		files[stem + ".color.rgba8"] = r.color_bytes() if r != null else PackedByteArray()
	return {
		"world_id": doc.world_id,
		"document_revision": doc.document_revision,
		"layout_min": doc.layout.min_region,
		"layout_count": doc.layout.region_count,
		"created_with": created_with.duplicate(true),
		"catalog": {"id": doc.catalog_id, "version": doc.catalog_version, "sha256": doc.catalog_sha256},
		"rules": doc.rules.to_dict(),
		"files": files,
		"authored_content_hash": CanonicalEncoder.authored_hash(doc),
	}


static func write_generation(dir: String, doc: WorldDocument, created_with: Dictionary) -> String:
	if not WorldConstants.host_is_little_endian():
		return "host is not little-endian; world files cannot be written"
	return write_snapshot(dir, snapshot(doc, created_with))


## Payloads first, manifest last. `fail_on_file` is fault injection for tests (IO-04).
static func write_snapshot(dir: String, snap: Dictionary, fail_on_file: String = "") -> String:
	var layout := WorldLayout.create(snap.layout_min, snap.layout_count)
	if layout == null:
		return "snapshot has an invalid layout"
	var schema := layout.schema_version()
	var err := StorageFs.make_dir(dir.path_join("regions"))
	if err != "":
		return err
	var entries: Array = []
	for path in payload_paths(layout):
		var data: PackedByteArray = snap.files.get(path, PackedByteArray())
		if is_region_path(path) and data.size() != WorldConstants.REGION_MAP_BYTES:
			return "region payload %s has %d bytes, expected %d" % [path, data.size(), WorldConstants.REGION_MAP_BYTES]
		if data.size() > payload_limit(path, schema):
			return "payload %s has %d bytes, limit %d" % [path, data.size(), payload_limit(path, schema)]
		if path == fail_on_file:
			return "write to '%s' failed (injected fault)" % dir.path_join(path)
		err = StorageFs.write_bytes(dir.path_join(path), data)
		if err != "":
			return err
		entries.append({"path": path, "bytes": data.size(), "sha256": CanonicalEncoder.sha256_hex(data)})
	if fail_on_file == MANIFEST_FILE:
		return "write to '%s' failed (injected fault)" % dir.path_join(MANIFEST_FILE)
	var manifest := build_manifest(snap, entries)
	return StorageFs.write_bytes(dir.path_join(MANIFEST_FILE), JSON.stringify(manifest, "  ", true, true).to_utf8_buffer())


static func build_manifest(snap: Dictionary, payload_entries: Array) -> Dictionary:
	var layout := WorldLayout.new(snap.layout_min, snap.layout_count)
	var locs: Array = []
	for loc in layout.region_locations():
		locs.append([loc.x, loc.y])
	var terrain := {
		"sample_spacing_m": WorldConstants.SAMPLE_SPACING,
		"region_samples": WorldConstants.REGION_SAMPLES,
		"region_locations": locs,
		"height_encoding": WorldConstants.HEIGHT_ENCODING,
		"control_encoding": WorldConstants.CONTROL_ENCODING,
		"control_schema": WorldConstants.CONTROL_SCHEMA,
		"color_encoding": WorldConstants.COLOR_ENCODING,
		"material_slots": WorldConstants.MATERIAL_SLOTS.duplicate(),
		"rules": snap.rules,
	}
	if not layout.is_legacy():
		terrain["layout"] = layout.to_manifest()
	return {
		"format": FORMAT,
		"schema_version": layout.schema_version(),
		"world_id": snap.world_id,
		"document_revision": snap.document_revision,
		"created_with": snap.created_with,
		"catalog": snap.catalog,
		"terrain": terrain,
		"payload_files": payload_entries,
		"authored_content_hash": snap.authored_content_hash,
	}


## Strict manifest + payload verification without a catalog (used by the worker after a
## write and by pruning). Returns {manifest, files: {path: bytes}, error}.
static func load_verified(dir: String) -> Dictionary:
	var out := {"manifest": {}, "files": {}, "error": ""}
	var read := StorageFs.read_bytes(dir.path_join(MANIFEST_FILE), int(WorldLimits.zip_envelope().max_manifest_bytes))
	if read[1] != "":
		out.error = "manifest: " + read[1]
		return out
	var parsed := WorldManifest.parse(read[0])
	if parsed[1] != "":
		out.error = "manifest: " + parsed[1]
		return out
	var manifest: Dictionary = parsed[0]
	var schema := int(manifest.schema_version)
	for entry in manifest.payload_files:
		var payload := StorageFs.read_bytes(dir.path_join(entry.path), payload_limit(entry.path, schema))
		if payload[1] != "":
			out.error = "payload %s: %s" % [entry.path, payload[1]]
			return out
		var data: PackedByteArray = payload[0]
		if data.size() != int(entry.bytes):
			out.error = "payload %s has %d bytes, manifest says %d" % [entry.path, data.size(), int(entry.bytes)]
			return out
		if CanonicalEncoder.sha256_hex(data) != entry.sha256:
			out.error = "payload %s sha256 does not match the manifest" % entry.path
			return out
		out.files[entry.path] = data
	out.manifest = manifest
	return out


## Returns [WorldDocument, ""] or [null, error]. Never touches any existing document.
static func read_generation(dir: String, catalog: AssetCatalog) -> Array:
	if not WorldConstants.host_is_little_endian():
		return [null, "host is not little-endian; world files cannot be read"]
	if catalog == null:
		return [null, "no trusted catalog loaded"]
	var verified := load_verified(dir)
	if verified.error != "":
		return [null, verified.error]
	var m: Dictionary = verified.manifest
	if m.catalog.id != catalog.catalog_id or int(m.catalog.version) != catalog.catalog_version \
			or m.catalog.sha256 != catalog.sha256:
		return [null, "incompatible catalog '%s' v%d sha256 %s (trusted catalog is '%s' v%d sha256 %s)" % [
			m.catalog.id, int(m.catalog.version), m.catalog.sha256,
			catalog.catalog_id, catalog.catalog_version, catalog.sha256]]
	var doc := WorldDocument.new()
	doc.schema_version = int(m.schema_version)
	doc.layout = WorldManifest.layout_of(m)
	doc.world_id = m.world_id
	doc.document_revision = int(m.document_revision)
	doc.catalog_id = m.catalog.id
	doc.catalog_version = int(m.catalog.version)
	doc.catalog_sha256 = m.catalog.sha256
	doc.rules = (TerrainRules.from_dict(m.terrain.rules))[0]
	var err := _read_layers(doc, verified.files)
	if err != "":
		return [null, err]
	if CanonicalEncoder.authored_hash(doc) != m.authored_content_hash:
		return [null, "authored_content_hash does not match the loaded content"]
	var errors := WorldValidator.validate(doc, catalog)
	if not errors.is_empty():
		return [null, "; ".join(errors)]
	return [doc, ""]


static func _read_layers(doc: WorldDocument, files: Dictionary) -> String:
	for loc in doc.layout.region_locations():
		var stem := WorldConstants.region_file_stem(loc)
		var r := RegionBuffers.new(loc)
		var err := r.set_from_bytes(files[stem + ".height.f32le"], files[stem + ".control.u32le"],
			files[stem + ".color.rgba8"])
		if err != "":
			return err
		doc.regions[loc] = r
	var obj_err := _read_objects(doc, files[OBJECTS_FILE])
	if obj_err != "":
		return "objects.json: " + obj_err
	var limits := WorldLimits.for_schema(doc.schema_version)
	var scatter := ScatterLayer.decode(files[WorldConstants.SCATTER_FILE], int(limits.max_scatter_instances))
	if scatter[1] != "":
		return scatter[1]
	doc.scatter = scatter[0]
	var paths := PathRecord.decode_all(files[WorldConstants.PATHS_FILE])
	if paths[1] != "":
		return paths[1]
	doc.paths = paths[0]
	return ""


static func _read_objects(doc: WorldDocument, data: PackedByteArray) -> String:
	var json := JSON.new()
	if json.parse(data.get_string_from_utf8()) != OK:
		return "invalid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]
	var root: Variant = json.data
	if typeof(root) != TYPE_DICTIONARY or root.size() != 2 or not root.has("schema_version") or not root.has("objects"):
		return "root must be exactly {schema_version, objects}"
	if not WorldManifest.is_json_int(root.schema_version) or int(root.schema_version) != doc.schema_version:
		return "unsupported schema_version %s" % str(root.schema_version)
	if typeof(root.objects) != TYPE_ARRAY:
		return "objects must be an array"
	var max_objects := int(WorldLimits.for_schema(doc.schema_version).max_objects)
	if root.objects.size() > max_objects:
		return "%d objects exceed the limit of %d" % [root.objects.size(), max_objects]
	var prev := ""
	for d in root.objects:
		var type_err := _enum_type_error(d)
		if type_err != "":
			return type_err
		var parsed := ObjectRecord.from_dict(d)
		# A script error inside from_dict returns an empty Array; never treat that as success.
		if parsed.size() != 2 or typeof(parsed[1]) != TYPE_STRING:
			return "object record could not be parsed"
		if parsed[1] != "":
			return parsed[1]
		if not (parsed[0] is ObjectRecord):
			return "object record could not be parsed"
		var r: ObjectRecord = parsed[0]
		if prev != "" and not (prev < r.object_id):
			return "object ids are not sorted and unique at %s" % r.object_id
		prev = r.object_id
		doc.put_object(r)
	return ""


## ObjectRecord.from_dict compares these fields with String constants, which is a script
## error (not a rejection) for any other JSON type, so reject non-strings first.
static func _enum_type_error(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return ""
	for key in ["grounding", "origin"]:
		if d.has(key) and typeof(d[key]) != TYPE_STRING:
			return "%s must be a string, got %s" % [key, type_string(typeof(d[key]))]
	return ""
