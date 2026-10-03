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
const MANIFEST_KEYS_V4 := ["format", "schema_version", "world_id", "document_revision", "created_with",
	"asset_lock", "terrain", "payload_files", "authored_content_hash"]
const CATALOG_KEYS := ["id", "version", "sha256"]
const TERRAIN_KEYS := ["sample_spacing_m", "region_samples", "region_locations", "height_encoding",
	"control_encoding", "control_schema", "color_encoding", "material_slots", "rules"]
const TERRAIN_KEYS_V3 := ["sample_spacing_m", "region_samples", "region_locations", "height_encoding",
	"control_encoding", "control_schema", "color_encoding", "material_slots", "rules", "layout"]
const PAYLOAD_KEYS := ["path", "bytes", "sha256"]
const MAX_JSON_INT := 9007199254740992.0  # 2^53: larger JSON numbers are not exact integers


## The payload paths (3 + 3 per region, plus asset_locks.json from schema 4), sorted byte-wise (the order
## payload_files must use).
static func payload_paths(layout: WorldLayout, schema: int = WorldConstants.SCHEMA_VERSION_V4) -> PackedStringArray:
	var out := PackedStringArray([OBJECTS_FILE, WorldConstants.SCATTER_FILE, WorldConstants.PATHS_FILE])
	if schema == WorldConstants.SCHEMA_VERSION_V4:
		out.append(WorldConstants.ASSET_LOCK_FILE)
	for loc in layout.region_locations():
		var stem := WorldConstants.region_file_stem(loc)
		out.append(stem + ".height.f32le")
		out.append(stem + ".control.u32le")
		out.append(stem + ".color.rgba8")
	out.sort()
	return out


## Largest allowed byte length of a payload file under the schema's limits (WorldLimits).
static func payload_limit(path: String, schema: int = WorldConstants.SCHEMA_VERSION_V4) -> int:
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
		WorldConstants.ASSET_LOCK_FILE:
			return int(limits.get("max_lock_bytes", 0))
	return 0


static func is_region_path(path: String) -> bool:
	return path.begins_with("regions/")


## Main thread only (reads Engine/ProjectSettings).
static func default_created_with() -> Dictionary:
	var v := Engine.get_version_info()
	# Godot's own default for application/config/version is "" (never missing), and the manifest forbids an empty value.
	var app_version := str(ProjectSettings.get_setting("application/config/version", ""))
	return {
		"godot": "%d.%d.%d.%s.%s.%s" % [v.major, v.minor, v.patch, v.status, v.build, String(v.hash).left(9)],
		"terrain3d": TERRAIN3D_VERSION,
		"world_painter": app_version if app_version != "" else "unknown",
	}


static func objects_json_bytes(doc: WorldDocument) -> PackedByteArray:
	var records: Array = []
	for id in doc.sorted_object_ids():
		records.append(doc.get_object(id).to_dict())
	var data := {"schema_version": WorldConstants.SCHEMA_VERSION_V4, "objects": records}
	return JSON.stringify(data, "  ", true, true).to_utf8_buffer()


## objects.json from per-object entry chunks (ObjectChunkCache.json_chunk), byte-identical to
## objects_json_bytes() of the same objects.
static func assemble_objects_json(schema: int, json_chunks: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array("{\n  \"objects\": [".to_utf8_buffer())
	if json_chunks.is_empty():
		out.append_array("],\n".to_utf8_buffer())
	else:
		var separator := ",\n".to_utf8_buffer()
		out.append_array("\n".to_utf8_buffer())
		for i in json_chunks.size():
			if i > 0:
				out.append_array(separator)
			out.append_array(json_chunks[i])
		out.append_array("\n  ],\n".to_utf8_buffer())
	out.append_array(("  \"schema_version\": %d\n}" % schema).to_utf8_buffer())
	return out


## Copies everything a checkpoint needs into plain values (no references into `doc`). Without a
## `cache` the snapshot is complete. With one, the object entries and the authored hash are left
## to finalize_snapshot() (storage worker), so the main thread only re-encodes changed objects.
## Returns {"error": ...} when the document's asset lock cannot be encoded.
static func snapshot(doc: WorldDocument, created_with: Dictionary, cache: ObjectChunkCache = null) -> Dictionary:
	var chunks: Dictionary = cache.chunks(doc) if cache != null else {}
	var lock := doc.assets.encode_referenced(doc, cache.binding_ids() if cache != null else null)
	if lock[1] != "":
		return {"error": lock[1]}
	var files := {
		WorldConstants.ASSET_LOCK_FILE: lock[0],
		WorldConstants.SCATTER_FILE: doc.scatter.encode(),
		WorldConstants.PATHS_FILE: PathRecord.encode_all(doc.paths),
	}
	for loc in doc.layout.region_locations():
		var r := doc.get_region(loc)
		var stem := WorldConstants.region_file_stem(loc)
		files[stem + ".height.f32le"] = r.height_bytes() if r != null else PackedByteArray()
		files[stem + ".control.u32le"] = r.control_bytes() if r != null else PackedByteArray()
		files[stem + ".color.rgba8"] = r.color_bytes() if r != null else PackedByteArray()
	var snap := {
		"world_id": doc.world_id,
		"document_revision": doc.document_revision,
		"source_schema": doc.source_schema,
		"layout_min": doc.layout.min_region,
		"layout_count": doc.layout.region_count,
		"created_with": created_with.duplicate(true),
		"rules": doc.rules.to_dict(),
		"files": files,
	}
	if cache == null:
		files[OBJECTS_FILE] = objects_json_bytes(doc)
		snap["authored_content_hash"] = CanonicalEncoder.authored_hash(doc)
	else:
		snap["object_chunks"] = chunks
	return snap


## Completes a cache-built snapshot from its plain values: objects.json, payload digests and the
## authored hash. Runs on the storage worker (or any thread); a complete snapshot is left alone.
static func finalize_snapshot(snap: Dictionary) -> void:
	if not snap.has("object_chunks"):
		return
	var chunks: Dictionary = snap.object_chunks
	var layout := WorldLayout.new(snap.layout_min, snap.layout_count)
	var files: Dictionary = snap.files
	files[OBJECTS_FILE] = assemble_objects_json(WorldConstants.SCHEMA_VERSION_V4, chunks.json)
	var digests := {}
	for path: String in files:
		digests[path] = CanonicalEncoder.sha256(files[path])
	var rules: TerrainRules = TerrainRules.from_dict(snap.rules)[0]
	snap["authored_content_hash"] = CanonicalEncoder.authored_hash_of_parts(layout, rules, digests, chunks.canon)
	snap["digests"] = digests
	snap.erase("object_chunks")


static func write_generation(dir: String, doc: WorldDocument, created_with: Dictionary) -> String:
	if not WorldConstants.host_is_little_endian():
		return "host is not little-endian; world files cannot be written"
	var snap := snapshot(doc, created_with)
	if snap.has("error"):
		return snap.error
	return write_snapshot(dir, snap)


## Payloads first, manifest last. `fail_on_file` is fault injection for tests (IO-04).
static func write_snapshot(dir: String, snap: Dictionary, fail_on_file: String = "") -> String:
	finalize_snapshot(snap)
	var layout := WorldLayout.create(snap.layout_min, snap.layout_count)
	if layout == null:
		return "snapshot has an invalid layout"
	var schema := WorldConstants.SCHEMA_VERSION_V4
	var err := StorageFs.make_dir(dir.path_join("regions"))
	if err != "":
		return err
	var entries: Array = []
	for path in payload_paths(layout, schema):
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
		var digest: PackedByteArray = snap.get("digests", {}).get(path, PackedByteArray())
		entries.append({"path": path, "bytes": data.size(),
			"sha256": digest.hex_encode() if not digest.is_empty() else CanonicalEncoder.sha256_hex(data)})
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
	terrain["layout"] = layout.to_manifest()
	var lock_sha := ""
	for e: Dictionary in payload_entries:
		if e.path == WorldConstants.ASSET_LOCK_FILE:
			lock_sha = e.sha256
	return {
		"format": FORMAT,
		"schema_version": WorldConstants.SCHEMA_VERSION_V4,
		"world_id": snap.world_id,
		"document_revision": snap.document_revision,
		"created_with": snap.created_with,
		"asset_lock": {"path": WorldConstants.ASSET_LOCK_FILE, "sha256": lock_sha},
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


## Returns [WorldDocument, ""] or [null, error]. Never touches any existing document. Schema 2/3
## generations are converted in memory to bundled bindings (WorldReader); the file is never rewritten.
static func read_generation(dir: String, catalog: AssetCatalog) -> Array:
	if not WorldConstants.host_is_little_endian():
		return [null, "host is not little-endian; world files cannot be read"]
	if catalog == null:
		return [null, "no trusted catalog loaded"]
	var verified := load_verified(dir)
	if verified.error != "":
		return [null, verified.error]
	return WorldReader.read(verified, catalog)
