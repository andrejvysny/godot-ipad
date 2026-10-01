class_name WorldLoader
extends RefCounted
## Read-only world loading for consumers (spec §17.6). Every path goes through the same strict
## validation as the editor; a failure never yields a partial document (IO-07).


## Returns [WorldDocument, ""] or [null, error]. `path` is a .worldpoc or a generation directory.
static func load_world(path: String, catalog: AssetCatalog, tmp_root: String = WorldPackage.IMPORT_TMP_ROOT) -> Array:
	if path.get_extension().to_lower() == "worldpoc" and FileAccess.file_exists(path):
		return WorldPackage.import_package(path, catalog, tmp_root)
	if DirAccess.dir_exists_absolute(path):
		return WorldCodec.read_generation(path, catalog)
	return [null, "World path not found: " + path]


## Machine-readable summary; hashes are over the exact in-memory region bytes (IO-01).
static func report(doc: WorldDocument, catalog: AssetCatalog) -> Dictionary:
	var regions := {}
	for loc in doc.sorted_region_locations():
		var rb := doc.get_region(loc)
		regions["%d,%d" % [loc.x, loc.y]] = {
			"height_sha256": CanonicalEncoder.sha256_hex(rb.height_bytes()),
			"control_sha256": CanonicalEncoder.sha256_hex(rb.control_bytes()),
		}
	var ids: Array = Array(doc.sorted_object_ids())
	ids.sort()
	return {
		"world_id": doc.world_id,
		"document_revision": doc.document_revision,
		"authored_hash": CanonicalEncoder.authored_hash(doc),
		"catalog": {"id": catalog.catalog_id, "version": catalog.catalog_version, "sha256": catalog.sha256},
		"object_count": ids.size(),
		"scatter_instance_count": doc.scatter.count(),
		"path_count": doc.paths.size(),
		"object_ids": ids,
		"regions": regions,
		"grounding_mismatches": WorldValidator.grounding_report(doc, catalog).size(),
	}
