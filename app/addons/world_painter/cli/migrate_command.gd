extends RefCounted
## `migrate --world <src> --out <dest dir> [--assets <res dir>]`: schema 2/3 -> 4 (ADR 0014 D9), the same in-memory
## conversion as the app (WorldReader) written with WorldCodec. Refuses an existing dest and a schema 4 source;
## writes beside dest, re-reads and compares the hash, then renames. Prints {ok, source_schema, source_hash,
## authored_hash, out, errors}. Exit 0 ok, 1 not migratable/verification failed, 2 usage/IO.

const USAGE := "usage: migrate --world <generation dir|.worldpoc> --out <new dest dir> [--assets <res dir>]"
const PARTIAL_SUFFIX := ".partial"


static func run(args: PackedStringArray) -> int:
	var opts := _parse(args)
	if opts.has("error"):
		return _emit({"ok": false, "errors": [opts.error]}, 2)
	var out: String = opts.out
	var partial := out + PARTIAL_SUFFIX
	if DirAccess.dir_exists_absolute(out) or FileAccess.file_exists(out) or DirAccess.dir_exists_absolute(partial):
		return _emit({"ok": false, "errors": ["destination already exists: " + out]}, 2)
	var loaded := AssetCatalog.load_from(opts.assets)
	if loaded[1] != "":
		return _emit({"ok": false, "errors": [loaded[1]]}, 2)
	var catalog: AssetCatalog = loaded[0]
	var result := WorldLoader.load_world(opts.world, catalog)
	if result[1] != "":
		return _emit({"ok": false, "errors": [result[1]]}, 1)
	var doc: WorldDocument = result[0]
	if doc.source_schema >= WorldConstants.SCHEMA_VERSION_V4:
		return _emit({"ok": false, "source_schema": doc.source_schema, "errors": ["source is already schema %d" % doc.source_schema]}, 1)
	var source_hash: String = WorldLoader.report(doc, catalog).authored_hash
	var err := _write_verified(doc, catalog, partial, out)
	if err != "":
		StorageFs.remove_tree(partial)
		return _emit({"ok": false, "source_schema": doc.source_schema, "source_hash": source_hash, "errors": [err]}, 1)
	return _emit({"ok": true, "source_schema": doc.source_schema, "source_hash": source_hash,
		"authored_hash": CanonicalEncoder.authored_hash(doc), "out": out, "errors": []}, 0)


static func _write_verified(doc: WorldDocument, catalog: AssetCatalog, partial: String, out: String) -> String:
	var err := WorldCodec.write_generation(partial, doc, WorldCodec.default_created_with())
	if err != "":
		return err
	var back := WorldCodec.read_generation(partial, catalog)
	if back[1] != "":
		return "migrated world failed verification: " + back[1]
	var written: WorldDocument = back[0]
	if written.source_schema != WorldConstants.SCHEMA_VERSION_V4:
		return "migrated world is not schema 4"
	if CanonicalEncoder.authored_hash(written) != CanonicalEncoder.authored_hash(doc):
		return "migrated world authored hash differs from the converted source"
	if DirAccess.rename_absolute(partial, out) != OK:
		return "cannot rename '%s' to '%s'" % [partial, out]
	return ""


static func _parse(args: PackedStringArray) -> Dictionary:
	var opts := {"assets": "res://assets"}
	var i := 0
	while i < args.size():
		var key := args[i]
		var value := ""
		if key.contains("="):
			value = key.get_slice("=", 1)
			key = key.get_slice("=", 0)
		elif i + 1 < args.size():
			i += 1
			value = args[i]
		if not ["--world", "--out", "--assets"].has(key) or value == "":
			return {"error": USAGE}
		opts[key.trim_prefix("--")] = value
		i += 1
	if not opts.has("world") or not opts.has("out"):
		return {"error": USAGE}
	return opts


static func _emit(data: Dictionary, code: int) -> int:
	print(JSON.stringify(data, "", true))
	return code
