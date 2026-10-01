class_name WorldPackage
extends RefCounted
## .worldpoc export/import (spec §17.1, §17.5; docs/world-format.md §7). A package holds
## exactly one generation. Import inspects the central directory first, extracts only into a
## fresh temporary directory, validates it as a generation, and always deletes that directory.

const IMPORT_TMP_ROOT := "user://import_tmp"


## Packs `generation_dir` into `out_path` (written beside it as *.partial, then renamed), then
## re-imports the package to prove it. With a catalog the proof is a full import; without
## one it is inspection + extraction + manifest/payload hash verification. The proof extracts
## under `tmp_root`.
static func export_package(generation_dir: String, out_path: String, catalog: AssetCatalog = null,
		tmp_root: String = IMPORT_TMP_ROOT) -> String:
	var verified := WorldCodec.load_verified(generation_dir)
	if verified.error != "":
		return "cannot export invalid generation: " + verified.error
	var err := StorageFs.make_dir(out_path.get_base_dir())
	if err != "":
		return err
	var partial := out_path + GenerationStore.PARTIAL_SUFFIX
	err = _pack(generation_dir, partial)
	if err == "":
		err = _verify_package(partial, catalog, tmp_root)
	if err == "" and FileAccess.file_exists(out_path) and DirAccess.remove_absolute(out_path) != OK:
		err = "cannot replace existing '%s'" % out_path
	if err == "" and DirAccess.rename_absolute(partial, out_path) != OK:
		err = "cannot rename package to '%s'" % out_path
	if err != "":
		DirAccess.remove_absolute(partial)
	return err


static func _pack(generation_dir: String, zip_path: String) -> String:
	var names := PackedStringArray([WorldCodec.MANIFEST_FILE])
	names.append_array(WorldCodec.payload_paths())  # objects.json, then regions sorted
	var zp := ZIPPacker.new()
	if zp.open(zip_path) != OK:
		return "cannot create package '%s'" % zip_path
	var err := ""
	for name in names:
		var read := StorageFs.read_bytes(generation_dir.path_join(name))
		if read[1] != "":
			err = read[1]
			break
		if zp.start_file(name) != OK or zp.write_file(read[0]) != OK or zp.close_file() != OK:
			err = "cannot write '%s' into package" % name
			break
	if zp.close() != OK and err == "":
		err = "cannot finalize package '%s'" % zip_path
	return err


static func _verify_package(zip_path: String, catalog: AssetCatalog, tmp_root: String) -> String:
	if catalog != null:
		return import_package(zip_path, catalog, tmp_root)[1]
	var ex := _extract(zip_path, tmp_root)
	var err: String = ex.error
	if err == "":
		err = WorldCodec.load_verified(ex.dir).error
	if ex.dir != "":
		StorageFs.remove_tree(ex.dir)
	return err


## Returns [WorldDocument, ""] or [null, error]. The caller's active document is never touched.
## `tmp_root` is where the fresh extraction directory is created (and always removed).
static func import_package(zip_path: String, catalog: AssetCatalog, tmp_root: String = IMPORT_TMP_ROOT) -> Array:
	var ex := _extract(zip_path, tmp_root)
	var result: Array = [null, ex.error]
	if ex.error == "":
		result = WorldCodec.read_generation(ex.dir, catalog)
	if ex.dir != "":
		var rm_err := StorageFs.remove_tree(ex.dir)
		if rm_err != "" and result[1] == "":
			result = [null, "cannot remove import directory: " + rm_err]
	if result[1] != "":
		result[1] = "package rejected: " + result[1]
	return result


## Inspects, then extracts into a new directory. Returns {dir, error}; `dir` is set whenever
## a directory was created, so the caller can always remove it.
static func _extract(zip_path: String, tmp_root: String) -> Dictionary:
	var info := ZipInspector.inspect(zip_path)
	if not info.ok:
		return {"dir": "", "error": info.error}
	var dir := tmp_root.path_join(StorageFs.random_hex(12))
	if DirAccess.dir_exists_absolute(dir):
		return {"dir": "", "error": "temporary import directory collision"}
	var err := StorageFs.make_dir(dir.path_join("regions"))
	if err != "":
		return {"dir": dir, "error": err}
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return {"dir": dir, "error": "cannot open package"}
	for e in info.entries:
		if e.is_dir:
			continue
		var data := zr.read_file(e.name)
		if data.size() != int(e.uncompressed):
			err = "entry '%s' decompressed to %d bytes, central directory says %d" % [e.name, data.size(), int(e.uncompressed)]
			break
		err = StorageFs.write_bytes(dir.path_join(e.name), data)
		if err != "":
			break
	zr.close()
	return {"dir": dir, "error": err}
