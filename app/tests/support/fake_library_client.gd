class_name FakeLibraryClient
extends RefCounted
## In-memory stand-in of ASLibraryClient for the remote Library tests (browse paging, cursor resets, per-library
## failures, exact versions with descriptors, thumbnails, current pointers). Results are real ASResults.

signal released

const Result := preload("res://addons/assetstudio/core/as_errors.gd")
const LIBRARY := AssetTestKit.LIBRARY
const OTHER_LIBRARY := "prj_0000000000000002"

var server_id := AssetTestKit.SERVER
var library_rows: Array = [{"library_id": LIBRARY, "name": "Fake", "state": "available"}]
var fail_libraries := false
var items: Dictionary = {}  # library_id -> Array of listing rows
var fail_list: Dictionary = {}  # library_id -> true
var reset_next := false  # the next list call that carries a cursor answers reset_required
var gate_first_page := false  # the next first-page list call waits for `released`
var current: Dictionary = {}  # asset_id -> current version id
var versions: Dictionary = {}  # version id -> descriptor text
var thumbnails: Dictionary = {}  # version id -> bytes
var calls: Array[String] = []
var limits: Array[int] = []


static func row(index: int, name: String = "", category: String = "props") -> Dictionary:
	return {"asset_id": "ast_%016d" % index, "display_name": name if name != "" else "Asset %d" % index,
			"category_id": category, "tags": [], "current_version_id": "ver_%016d" % index,
			"display_version": "1", "metadata_revision": 1, "has_thumbnail": false}


static func png() -> PackedByteArray:
	return Image.create(8, 8, false, Image.FORMAT_RGBA8).save_png_to_buffer()


## Serves the contract descriptor `file` as exact version `version_id` of AssetTestKit.ASSET.
func add_version(version_id: String, descriptor_text: String) -> void:
	versions[version_id] = descriptor_text


func ref_of(library_id: String, asset_id: String, version_id: String) -> Dictionary:
	return {"server_id": server_id, "library_id": library_id, "asset_id": asset_id, "version_id": version_id}


func capabilities() -> RefCounted:
	calls.append("capabilities")
	return Result.success({"server_id": server_id})


func libraries() -> RefCounted:
	calls.append("libraries")
	if fail_libraries:
		return Result.fail("network_error", "server unreachable", true)
	return Result.success({"libraries": library_rows.duplicate(true)})


func list_assets(library: String, query: Dictionary = {}, cursor: String = "", limit: int = 60) -> RefCounted:
	calls.append("list:%s:%s" % [library, cursor])
	limits.append(limit)
	if gate_first_page and cursor == "":
		gate_first_page = false
		await released
	if fail_list.has(library):
		return Result.fail("temporarily_unavailable", "library unavailable", true)
	if cursor != "" and reset_next:
		reset_next = false
		return Result.success({"items": [], "next_cursor": null, "reset_required": true})
	var rows: Array = []
	for r: Dictionary in items.get(library, []):
		if str(query.get("q", "")) != "" and not str(r.display_name).to_lower().contains(str(query.q).to_lower()):
			continue
		if str(query.get("category", "")) != "" and r.category_id != query.category:
			continue
		rows.append(r.duplicate(true))
	var offset := int(cursor) if cursor != "" else 0
	var page := rows.slice(offset, offset + limit)
	var next := offset + page.size()
	return Result.success({"items": page, "next_cursor": str(next) if next < rows.size() else null})


func asset(library: String, asset_id: String) -> RefCounted:
	calls.append("asset:%s" % asset_id)
	if not current.has(asset_id):
		return Result.fail("asset_not_found", "no such asset")
	var rows: Array = []
	for v: String in versions:
		rows.append({"version_id": v, "display_version": v.right(2), "published_at": "2026-01-01T00:00:00Z"})
	return Result.success({"library_id": library, "asset_id": asset_id, "current_version_id": current[asset_id],
			"versions": rows})


func version(library: String, asset_id: String, version_id: String) -> RefCounted:
	calls.append("version:%s" % version_id)
	if not versions.has(version_id):
		return Result.fail("version_unavailable", "no such version")
	return Result.success({"asset_ref": ref_of(library, asset_id, version_id)})


func resolve(library: String, refs: Array, _target: Dictionary = {}) -> RefCounted:
	var entries: Array = []
	for ref: Dictionary in refs:
		calls.append("resolve:%s" % ref.version_id)
		if not versions.has(ref.version_id):
			entries.append({"asset_ref": ref, "state": "not_found", "error": {"code": "version_unavailable", "message": "x"}})
			continue
		var text: String = versions[ref.version_id]
		entries.append({"asset_ref": ref, "asset_key": AssetBinding.Canonical.asset_key(ref.server_id, library, ref.asset_id, ref.version_id),
				"state": "ready", "error": null, "descriptor_json": text,
				"descriptor_sha256": CanonicalEncoder.sha256_hex(text.to_utf8_buffer()),
				"deliveries": [{"delivery_id": AssetTestKit.DELIVERY, "representation": "portable_glb_v1",
						"profile_id": "portable-default", "profile_version": "1.0.0",
						"manifest_sha256": CanonicalEncoder.sha256_hex(text.to_utf8_buffer()), "total_bytes": 1, "budget": {}}],
				"dependencies": [], "representations": {"portable_glb_v1": {"state": "ready", "error": null}}})
	return Result.success({"entries": entries})


func thumbnail_bytes(_library: String, _asset_id: String, version_id: String) -> RefCounted:
	calls.append("thumb:%s" % version_id)
	if not thumbnails.has(version_id):
		return Result.fail("asset_not_found", "no thumbnail")
	return Result.success({"bytes": thumbnails[version_id]})
