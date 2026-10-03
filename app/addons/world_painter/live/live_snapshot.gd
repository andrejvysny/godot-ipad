class_name LiveSnapshot
extends RefCounted
## Stable snapshot of a document as a schema-4 .worldpoc ZIP (ADR 0015 L4). freeze() runs on the main thread at a
## committed point and copies everything into plain values (map byte images, encoded files, immutable object
## records); write() runs on any thread and builds objects.json, digests, the manifest and the ZIP from those values
## alone, like the storage worker. install() validates a received archive completely (ZipInspector, hashes,
## WorldValidator) before it returns a new document.


## Returns {error} or {snap, hash}. `cache` supplies the hash and the encoded lock/scatter/paths files; it is
## brought up to date here, so the caller must have invalidated everything changed since its last hash_of().
static func freeze(doc: WorldDocument, cache: AuthoredHashCache, created_with: Dictionary) -> Dictionary:
	if not WorldConstants.host_is_little_endian():
		return {"error": "host is not little-endian; world files cannot be written"}
	var hash := cache.hash_of(doc)
	if hash == "":
		return {"error": "the document's asset lock cannot be encoded"}
	var files := {WorldConstants.ASSET_LOCK_FILE: cache.lock_bytes(), WorldConstants.SCATTER_FILE: cache.scatter_bytes(),
		WorldConstants.PATHS_FILE: cache.paths_bytes()}
	for loc in doc.layout.region_locations():
		var r := doc.get_region(loc)
		var stem := WorldConstants.region_file_stem(loc)
		files[stem + ".height.f32le"] = r.height_bytes()
		files[stem + ".control.u32le"] = r.control_bytes()
		files[stem + ".color.rgba8"] = r.color_bytes()
	var records: Array = doc.objects.values()  # records are replace-only: sharing the instances is safe
	var snap := {"world_id": doc.world_id, "document_revision": doc.document_revision, "source_schema": doc.source_schema,
		"layout_min": doc.layout.min_region, "layout_count": doc.layout.region_count,
		"created_with": created_with.duplicate(true), "rules": doc.rules.to_dict(), "files": files, "records": records}
	return {"snap": snap, "hash": hash}


## Worker side. Returns {ok, error, path, bytes, hash (authored_content_hash)}.
static func write(snap: Dictionary, out_path: String) -> Dictionary:
	var records: Array = snap.records
	records.sort_custom(func(a: ObjectRecord, b: ObjectRecord) -> bool: return a.object_id < b.object_id)
	var json: Array = []
	var canon: Array = []
	for rec: ObjectRecord in records:
		json.append(ObjectChunkCache.json_chunk(rec))
		canon.append(ObjectChunkCache.canon_chunk(rec))
	snap["object_chunks"] = {"json": json, "canon": canon}
	WorldCodec.finalize_snapshot(snap)
	var layout := WorldLayout.create(snap.layout_min, snap.layout_count)
	if layout == null:
		return _fail("snapshot has an invalid layout")
	var entries: Array = []
	var members: Array = []
	for path in WorldCodec.payload_paths(layout):
		var data: PackedByteArray = snap.files[path]
		entries.append({"path": path, "bytes": data.size(), "sha256": (snap.digests[path] as PackedByteArray).hex_encode()})
		members.append([path, data])
	var manifest := WorldCodec.build_manifest(snap, entries)
	members.push_front([WorldCodec.MANIFEST_FILE, JSON.stringify(manifest, "  ", true, true).to_utf8_buffer()])
	var err := _zip(out_path, members)
	if err != "":
		return _fail(err)
	var f := FileAccess.open(out_path, FileAccess.READ)
	return {"ok": true, "error": "", "path": out_path, "bytes": f.get_length() if f != null else 0,
		"hash": snap.authored_content_hash}


static func _zip(path: String, members: Array) -> String:
	var zp := ZIPPacker.new()
	if zp.open(path) != OK:
		return "cannot create snapshot archive '%s'" % path
	var err := ""
	for m: Array in members:
		if zp.start_file(m[0]) != OK or zp.write_file(m[1]) != OK or zp.close_file() != OK:
			err = "cannot write '%s' into the snapshot archive" % m[0]
			break
	if zp.close() != OK and err == "":
		err = "cannot finalize the snapshot archive"
	return err


## Validates and loads a received .worldpoc. Returns [WorldDocument, ""] or [null, error]. `tmp_root` is a private
## directory for the temporary extraction (removed again).
static func install(path: String, catalog: AssetCatalog, tmp_root: String) -> Array:
	return WorldPackage.import_package(path, catalog, tmp_root)


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "path": "", "bytes": 0, "hash": ""}
