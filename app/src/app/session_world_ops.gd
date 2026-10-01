class_name SessionWorldOps
extends RefCounted
## World-level operations of EditorSession that need no scene state. Every function returns
## error strings instead of logging; callers post the messages.

const FIXTURES: Array[String] = ["flat", "gentle_hills", "stress_100"]


## Returns [doc, error]. The result is a new working copy: fresh world id, revision 0.
static func load_fixture(fixture: String, catalog: AssetCatalog) -> Array:
	if fixture not in FIXTURES:
		return [null, "Unknown fixture '%s'." % fixture]
	var loaded := WorldCodec.read_generation("res://fixtures/" + fixture, catalog)
	if loaded[1] != "":
		return [null, "Fixture '%s' is invalid: %s" % [fixture, loaded[1]]]
	var doc: WorldDocument = loaded[0]
	doc.world_id = ObjectRecord.new_uuid_v4()
	doc.document_revision = 0
	doc.source_label = "fixture:" + fixture
	return [doc, ""]


## Makes the active revision durable. Returns "" or an error.
static func ensure_saved(storage: WorldStorage, doc: WorldDocument) -> String:
	if storage.status_text(doc.document_revision) == "Saved revision %d" % doc.document_revision:
		return ""
	var res := storage.checkpoint_now(doc)
	if not res.durable:
		return str(res.error) if str(res.error) != "" else "checkpoint was not durable"
	return ""


## Exports the durable revision, then re-imports the package and compares authored hashes.
static func export_verified(storage: WorldStorage, doc: WorldDocument, catalog: AssetCatalog) -> Dictionary:
	var failed := {"path": "", "error": ""}
	failed.error = ensure_saved(storage, doc)
	if failed.error != "":
		failed.error = "Export needs a saved world: " + str(failed.error)
		return failed
	var exported := storage.export_latest(doc.world_id, catalog)
	if exported.error != "":
		failed.error = "Export failed: " + str(exported.error)
		return failed
	var imported := WorldPackage.import_package(exported.path, catalog, storage.import_tmp_root)
	if imported[1] != "":
		failed.error = "Export verification failed: " + str(imported[1])
		return failed
	if CanonicalEncoder.authored_hash(imported[0]) != CanonicalEncoder.authored_hash(doc):
		failed.error = "Export verification failed: package content differs from the active world."
		return failed
	return {"path": exported.path, "error": ""}


static func evidence(input: InputSystem, doc: WorldDocument, camera: Camera3D, frames: FrameStats) -> Dictionary:
	return {"device_gate": "NOT RUN", "build": WorldCodec.default_created_with(),
		"fingerprint": JSON.parse_string(FileAccess.get_file_as_string("res://config/build_fingerprint.json")),
		"provider": input.active_provider().diagnostics(), "stats": input.stats(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"camera_transform": str(camera.transform), "timing": frames.snapshot(),
		"authored_hash": CanonicalEncoder.authored_hash(doc), "revision": doc.document_revision,
		"object_count": doc.objects.size(), "trace_dropped": input.trace.dropped}


static func hit_text(hit: TerrainHit) -> String:
	if not hit.ok:
		return "no hit"
	return "%.1f, %.1f, %.1f · region (%d, %d)" % [hit.position.x, hit.position.y, hit.position.z,
		hit.region.x, hit.region.y]
