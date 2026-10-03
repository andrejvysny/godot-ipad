class_name RemoteBinding
extends RefCounted
## Builds the AssetBinding of one exact AssetStudio version (ADR 0014 D3-D6) from the server's version and
## resolve answers: frozen descriptor text and sha, the portable GLB delivery pinned from resolve, default policy =
## the descriptor's ranges, scatter off. Nothing here touches a world; the caller stages the binding. Never
## follows "latest": the ref names the version and every answer must echo it.

const Schema := preload("res://addons/assetstudio/core/as_schema.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const REPRESENTATION := "portable_glb_v1"


## Coroutine. {"ok": bool, "error": String, "binding": AssetBinding}. `client` is an ASLibraryClient (or a test
## double with version() and resolve()).
static func build(client: Object, ref: Dictionary) -> Dictionary:
	var bad := AssetBinding.AssetRef.validate(ref)
	if bad != "":
		return _fail(bad)
	var version: RefCounted = await client.call("version", ref.library_id, ref.asset_id, ref.version_id)
	if not version.get("ok"):
		return _fail(str(version.call("describe")))
	var echoed: Variant = (version.get("value") as Dictionary).get("asset_ref")
	if echoed != null and echoed != ref:
		return _fail("integrity_mismatch: the server answered for a different version")
	var resolved: RefCounted = await client.call("resolve", ref.library_id, [ref], {"representations": [REPRESENTATION]})
	if not resolved.get("ok"):
		return _fail(str(resolved.call("describe")))
	return from_entry(ref, ((resolved.get("value") as Dictionary).get("entries") as Array))


## The binding of the single resolve `entries` row for `ref`: {"ok", "error", "binding"}.
static func from_entry(ref: Dictionary, entries: Array) -> Dictionary:
	if entries.size() != 1 or not (entries[0] is Dictionary):
		return _fail("invalid_response: resolve must return exactly one entry")
	var e: Dictionary = entries[0]
	if e.get("asset_ref") != ref:
		return _fail("integrity_mismatch: resolve answered for a different version")
	var state := _entry_error(e)
	if state != "":
		return _fail(state)
	var text: Variant = e.get("descriptor_json")
	var sha: Variant = e.get("descriptor_sha256")
	if not (text is String) or not (sha is String) or Canonical.sha256_hex((text as String).to_utf8_buffer()) != sha:
		return _fail("integrity_mismatch: descriptor bytes do not match their sha256")
	var pin := _portable_pin(e.get("deliveries"))
	if pin.is_empty():
		return _fail("unsupported_representation: the version has no portable GLB delivery")
	if e.get("dependencies") is Array and not (e.dependencies as Array).is_empty():
		return _fail("unsupported_dependency: assets with dependencies cannot be placed on this device yet")
	return _assemble(ref, text, sha, pin)


static func _entry_error(e: Dictionary) -> String:
	if e.get("state") != "ready":
		var err: Variant = e.get("error")
		var code := str((err as Dictionary).get("code", "")) if err is Dictionary else ""
		return "%s: the version is %s" % [code if code != "" else "version_unavailable", str(e.get("state"))]
	var reps: Variant = e.get("representations")
	if reps is Dictionary:
		var rep: Variant = (reps as Dictionary).get(REPRESENTATION)
		if not (rep is Dictionary) or (rep as Dictionary).get("state") != "ready":
			return "unsupported_representation: the version is not available as a portable GLB"
	return ""


## Lowest delivery_id of the portable GLB deliveries, as a binding pin; {} when there is none.
static func _portable_pin(deliveries: Variant) -> Dictionary:
	var best: Dictionary = {}
	if not (deliveries is Array):
		return best
	for d: Variant in deliveries:
		if d is Dictionary and d.get("representation") == REPRESENTATION \
				and (best.is_empty() or str(d.get("delivery_id")) < str(best.delivery_id)):
			best = d
	if best.is_empty():
		return best
	var pin := {}
	for key: String in AssetBinding.PIN_KEYS:
		pin[key] = best.get(key)
	return pin if AssetBinding.pin_error(pin, "delivery") == "" else {}


static func _assemble(ref: Dictionary, text: String, sha: String, pin: Dictionary) -> Dictionary:
	var parsed: RefCounted = AssetBinding.AssetDescriptor.parse_bytes(text.to_utf8_buffer())
	if not parsed.get("ok"):
		return _fail(str(parsed.call("describe")))
	var d: Dictionary = (parsed.get("value") as RefCounted).get("data")
	var b := AssetBinding.new()
	b.provider = AssetBinding.PROVIDER_ASSETSTUDIO
	b.asset_ref = ref.duplicate(true)
	b.asset_key = Canonical.asset_key(ref.server_id, ref.library_id, ref.asset_id, ref.version_id)
	b.descriptor_json = text
	b.descriptor_sha256 = sha
	b.deliveries = {AssetBinding.REQUIRED_DELIVERY: pin}
	b.set_policy(false, d.scale_range[0], d.scale_range[1], d.height_offset_range_m[0], d.height_offset_range_m[1])
	b.dependencies = {b.asset_key: {"asset_ref": ref.duplicate(true), "descriptor_sha256": sha,
			"deliveries": {AssetBinding.REQUIRED_DELIVERY: pin.duplicate()}, "requires": []}}
	b.finalize()
	var round_trip := AssetBinding.from_dict(b.to_dict())
	if str(round_trip[1]) != "":
		return _fail("invalid_response: %s" % round_trip[1])
	return {"ok": true, "error": "", "binding": b}


## Copy of `b` with scatter allowed: only for a prepared binding whose structural scatter budget passed
## ({"ok", "error", "binding"}; the new binding has its own id).
static func with_scatter(lock: WorldAssetLock, b: AssetBinding) -> Dictionary:
	if not lock.is_prepared(b.binding_id):
		return _fail("Scatter needs the asset to be downloaded first.")
	if not lock.scatter_budget_ok(b.binding_id):
		return _fail("The asset is over the scatter budget (triangles, materials or texture size).")
	var copy := AssetBinding.new()
	copy.provider = b.provider
	copy.asset_ref = b.asset_ref.duplicate(true)
	copy.asset_key = b.asset_key
	copy.descriptor_json = b.descriptor_json
	copy.descriptor_sha256 = b.descriptor_sha256
	copy.deliveries = b.deliveries.duplicate(true)
	copy.dependencies = b.dependencies.duplicate(true)
	copy.set_policy(true, b.scale_range[0], b.scale_range[1], b.height_offset_range_m[0], b.height_offset_range_m[1])
	copy.finalize()
	return {"ok": true, "error": "", "binding": copy}


static func _fail(error: String) -> Dictionary:
	return {"ok": false, "error": error, "binding": null}
