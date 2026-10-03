class_name LegacyWorldWriter
extends RefCounted
## Test support: writes schema 2 (legacy layout) / schema 3 generation directories from a document whose
## bindings are all bundled (the pre-ADR-0014 writer), so legacy reading and migration stay testable on any
## content, not only on the committed fixtures.


## Returns "" or an error. The result is a valid legacy generation (hashes, V2/V3 authored hash).
static func write(dir: String, doc: WorldDocument, created_with: Dictionary = {}) -> String:
	var mapped := CanonicalEncoder.legacy_mapping(doc)
	if mapped[2] != "":
		return mapped[2]
	var mapping: Dictionary = mapped[0]
	var schema := doc.layout.legacy_schema_version()
	var files := {
		WorldCodec.OBJECTS_FILE: _objects_json(doc, mapping, schema),
		WorldConstants.SCATTER_FILE: doc.scatter.encode_legacy_v1(mapping),
		WorldConstants.PATHS_FILE: PathRecord.encode_all(doc.paths),
	}
	for loc in doc.layout.region_locations():
		var r := doc.get_region(loc)
		var stem := WorldConstants.region_file_stem(loc)
		files[stem + ".height.f32le"] = r.height_bytes()
		files[stem + ".control.u32le"] = r.control_bytes()
		files[stem + ".color.rgba8"] = r.color_bytes()
	var err := StorageFs.make_dir(dir.path_join("regions"))
	var entries: Array = []
	for path in WorldCodec.payload_paths(doc.layout, schema):
		if err != "":
			return err
		err = StorageFs.write_bytes(dir.path_join(path), files[path])
		entries.append({"path": path, "bytes": (files[path] as PackedByteArray).size(),
			"sha256": CanonicalEncoder.sha256_hex(files[path])})
	if err != "":
		return err
	var manifest := _manifest(doc, mapped[1], schema, entries, created_with)
	return StorageFs.write_bytes(dir.path_join(WorldCodec.MANIFEST_FILE),
			JSON.stringify(manifest, "  ", true, true).to_utf8_buffer())


static func _objects_json(doc: WorldDocument, mapping: Dictionary, schema: int) -> PackedByteArray:
	var records: Array = []
	for id in doc.sorted_object_ids():
		var rec := doc.get_object(id)
		var d := rec.to_dict()
		d.erase("binding_id")
		d["asset_id"] = mapping[rec.binding_id][0]
		d["asset_version"] = mapping[rec.binding_id][1]
		records.append(d)
	return JSON.stringify({"schema_version": schema, "objects": records}, "  ", true, true).to_utf8_buffer()


static func _manifest(doc: WorldDocument, catalog: Dictionary, schema: int, entries: Array, created_with: Dictionary) -> Dictionary:
	var locs: Array = []
	for loc in doc.layout.region_locations():
		locs.append([loc.x, loc.y])
	var terrain := {
		"sample_spacing_m": WorldConstants.SAMPLE_SPACING, "region_samples": WorldConstants.REGION_SAMPLES,
		"region_locations": locs, "height_encoding": WorldConstants.HEIGHT_ENCODING,
		"control_encoding": WorldConstants.CONTROL_ENCODING, "control_schema": WorldConstants.CONTROL_SCHEMA,
		"color_encoding": WorldConstants.COLOR_ENCODING, "material_slots": WorldConstants.MATERIAL_SLOTS.duplicate(),
		"rules": doc.rules.to_dict(),
	}
	if schema == WorldConstants.SCHEMA_VERSION_LAYOUT:
		terrain["layout"] = doc.layout.to_manifest()
	return {
		"format": WorldCodec.FORMAT, "schema_version": schema, "world_id": doc.world_id,
		"document_revision": doc.document_revision,
		"created_with": created_with if not created_with.is_empty() else WorldCodec.default_created_with(),
		"catalog": catalog, "terrain": terrain, "payload_files": entries,
		"authored_content_hash": CanonicalEncoder.legacy_authored_hash(doc)[0],
	}
