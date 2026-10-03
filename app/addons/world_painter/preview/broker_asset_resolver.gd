class_name BrokerAssetResolver
extends Node
## The preview child's stand-in for the AssetStudio resolver (ADR 0016 P3): same `prepare()` contract, but the bytes
## come from the editor's broker. The reply is never trusted: the manifest text must hash to the lock's pinned
## manifest_sha256, and every file the manifest lists must lie inside the AssetStudio blob cache root and match its
## manifest sha256 and size. Only then is the result handed to AssetStudioProvider, which loads the GLB.

const Result := preload("res://addons/assetstudio/core/as_errors.gd")
const Manifest := preload("res://addons/assetstudio/core/as_delivery_manifest.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const Descriptor := preload("res://addons/assetstudio/core/as_asset_descriptor.gd")
const REPRESENTATION := "portable_glb_v1"

var client: PreviewBrokerClient
## Absolute path of the blob cache root (`.../blobs`) the editor may serve from.
var blob_root := ""
## `() -> WorldAssetLock` of the displayed document: the child sends the binding row, never the iPad's own data.
var lock_getter := Callable()


## ASAssetResolver.prepare contract: returns an ASResult (value {descriptor, manifest, files, delivery_id, source}).
func prepare(ref: RefCounted, representation: String = REPRESENTATION, _token: RefCounted = null,
		pin_delivery_id: String = "") -> RefCounted:
	var binding := _binding_for(ref, pin_delivery_id) if representation == REPRESENTATION else null
	if binding == null:
		return Result.fail("invalid_request", "no AssetStudio binding of the open world matches this request")
	var reply: Dictionary = await client.request_assets(binding.to_dict(true))
	return verify(binding, reply, blob_root)


func _binding_for(ref: RefCounted, pin_delivery_id: String) -> AssetBinding:
	var lock: WorldAssetLock = lock_getter.call() if lock_getter.is_valid() else null
	if lock == null:
		return null
	for id in lock.ids():
		var b := lock.get_binding(id)
		if b != null and not b.is_bundled() and b.asset_ref == ref.call("to_dict") \
				and str(b.deliveries.get(REPRESENTATION, {}).get("delivery_id", "")) == pin_delivery_id:
			return b
	return null


## The ASResult for an editor reply, or the first reason it cannot be trusted. Static: unit-testable.
static func verify(binding: AssetBinding, reply: Dictionary, root: String) -> RefCounted:
	if str(reply.get("state", "")) != "ready":
		return Result.fail("temporarily_unavailable", str(reply.get("error", "the editor could not provide the asset")).left(300))
	var pin: Dictionary = binding.deliveries[REPRESENTATION]
	var manifest_text: Variant = reply.get("manifest")
	if typeof(manifest_text) != TYPE_STRING:
		return Result.fail("invalid_response", "the reply carries no manifest")
	var manifest_bytes := (manifest_text as String).to_utf8_buffer()
	if Canonical.sha256_hex(manifest_bytes) != str(pin.manifest_sha256):
		return Result.fail("integrity_mismatch", "the manifest differs from the locked manifest")
	var manifest: RefCounted = Manifest.parse_bytes(manifest_bytes)
	if not manifest.ok:
		return manifest
	var descriptor: RefCounted = Descriptor.parse_bytes(binding.descriptor_json.to_utf8_buffer())
	if not descriptor.ok or str(descriptor.value.raw_sha256) != binding.descriptor_sha256:
		return Result.fail("integrity_mismatch", "the locked descriptor is not self-consistent")
	var files := _verified_files(manifest.value.data, reply.get("files"), root)
	if typeof(files) == TYPE_STRING:
		return Result.fail("integrity_mismatch", files)
	return Result.success({"descriptor": descriptor.value, "manifest": manifest.value, "files": files,
		"delivery_id": manifest.value.data["delivery_id"], "source": "broker"})


## {manifest path: verified absolute path}, or an error String.
static func _verified_files(data: Dictionary, offered: Variant, root: String) -> Variant:
	if typeof(offered) != TYPE_DICTIONARY or root == "":
		return "the reply offers no files"
	var prefix := root.simplify_path().trim_suffix("/") + "/"
	var out := {}
	for f: Dictionary in data["files"]:
		var path: Variant = (offered as Dictionary).get(f["path"])
		if typeof(path) != TYPE_STRING:
			return "file %s is missing from the reply" % str(f["path"]).left(80)
		var clean := (path as String).simplify_path()
		if not clean.begins_with(prefix) or clean.contains("/../"):
			return "file %s lies outside the asset cache" % str(f["path"]).left(80)
		var file := FileAccess.open(clean, FileAccess.READ)
		if file == null or file.get_length() != int(f["size"]):
			return "file %s does not match the manifest size" % str(f["path"]).left(80)
		file.close()
		if FileAccess.get_sha256(clean) != str(f["sha256"]):
			return "file %s does not match the manifest hash" % str(f["path"]).left(80)
		out[f["path"]] = clean
	return out
