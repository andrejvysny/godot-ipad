extends RefCounted
## `validate --world <generation dir|.worldpoc> [--assets <res dir>]`: strict load through WorldLoader against the
## bundled catalog. Prints {ok, schema, authored_hash, errors, availability, catalog}. Exit 0 valid, 1 invalid, 2 usage.

const DEFAULT_ASSETS := "res://assets"


static func run(args: PackedStringArray) -> int:
	var opts := _parse(args)
	if opts.has("error"):
		return _emit({"ok": false, "errors": [opts.error]}, 2)
	var loaded := AssetCatalog.load_from(opts.assets)
	if loaded[1] != "":
		return _emit({"ok": false, "errors": [loaded[1]]}, 2)
	var catalog: AssetCatalog = loaded[0]
	var path: String = opts.world
	var result := WorldLoader.load_world(path, catalog)
	if result[1] != "":
		return _emit({"ok": false, "schema": _manifest_schema(path), "authored_hash": null, "errors": [result[1]],
			"availability": {}, "catalog": _catalog_info(catalog)}, 1)
	var doc: WorldDocument = result[0]
	var report := WorldLoader.report(doc, catalog)
	return _emit({"ok": true, "schema": doc.source_schema, "authored_hash": report.authored_hash, "errors": [],
		"availability": WorldValidator.availability(doc), "catalog": _catalog_info(catalog)}, 0)


static func _parse(args: PackedStringArray) -> Dictionary:
	var opts := {"assets": DEFAULT_ASSETS}
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
		if (key != "--world" and key != "--assets") or value == "":
			return {"error": "usage: validate --world <generation dir|.worldpoc> [--assets <res dir>]"}
		opts[key.trim_prefix("--")] = value
		i += 1
	if not opts.has("world"):
		return {"error": "usage: validate --world <generation dir|.worldpoc> [--assets <res dir>]"}
	return opts


## schema_version of a generation directory's manifest, or null (package, unreadable).
static func _manifest_schema(path: String) -> Variant:
	if not DirAccess.dir_exists_absolute(path):
		return null
	var read := StorageFs.read_bytes(path.path_join(WorldCodec.MANIFEST_FILE), 1 << 20)
	if read[1] != "":
		return null
	var data: Variant = JSON.parse_string((read[0] as PackedByteArray).get_string_from_utf8())
	if typeof(data) == TYPE_DICTIONARY and data.has("schema_version"):
		return int(data.schema_version)
	return null


static func _catalog_info(catalog: AssetCatalog) -> Dictionary:
	return {"id": catalog.catalog_id, "version": catalog.catalog_version, "sha256": catalog.sha256}


static func _emit(data: Dictionary, code: int) -> int:
	print(JSON.stringify(data, "", true))
	return code
