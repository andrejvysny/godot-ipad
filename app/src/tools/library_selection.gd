class_name LibrarySelection
extends RefCounted
## A Library choice as the tool layer sees it: {provider: "bundled", asset_id} or {provider: "assetstudio",
## binding}. A plain String is a bundled asset id (older callers). resolve() judges it against the open world:
## unknown, not downloaded and not render-ready selections are refused with the text the UI shows.

const BUNDLED := "bundled"
const ASSETSTUDIO := "assetstudio"


static func bundled(asset_id: String) -> Dictionary:
	return {"provider": BUNDLED, "asset_id": asset_id}


static func remote(binding_id: String) -> Dictionary:
	return {"provider": ASSETSTUDIO, "binding": binding_id}


## {} when `sel` is neither a String nor a well-formed selection.
static func normalize(sel: Variant) -> Dictionary:
	if sel is String:
		return bundled(sel)
	if not (sel is Dictionary):
		return {}
	var d: Dictionary = sel
	if d.get("provider") == BUNDLED and d.get("asset_id") is String:
		return bundled(d.asset_id)
	if d.get("provider") == ASSETSTUDIO and d.get("binding") is String:
		return remote(d.binding)
	return {}


## {"error", "unknown", "selection", "id", "asset", "binding_id"}. `id` is what ToolModel.armed_asset() reports
## (the catalog id, or the binding id); `binding_id` is "" for bundled assets (PlaceOperation derives it).
static func resolve(ctx: ToolContext, sel: Variant) -> Dictionary:
	var s := normalize(sel)
	var out := {"error": "", "unknown": false, "selection": s, "id": "", "asset": null, "binding_id": ""}
	if s.is_empty():
		return _fail(out, "Unknown asset.", true)
	if s.provider == BUNDLED:
		var asset := ctx.catalog.get_asset(s.asset_id)
		if asset == null:
			return _fail(out, "Unknown asset '%s'." % s.asset_id, true)
		out.asset = asset
		out.id = s.asset_id
		return _fail(out, ctx.not_ready_error(asset), false)
	return _resolve_remote(ctx, s, out)


static func _resolve_remote(ctx: ToolContext, s: Dictionary, out: Dictionary) -> Dictionary:
	var lock := ctx.document.assets
	var binding := lock.get_binding(s.binding)
	if binding == null or binding.is_bundled():
		return _fail(out, "Unknown asset binding '%s'." % s.binding, true)
	var asset := lock.definition(s.binding)
	var label := ctx.name_of(s.binding, asset.display_name if asset != null else s.binding)
	if asset == null or not lock.is_prepared(s.binding):
		return _fail(out, "%s is not downloaded yet." % label, false)
	out.asset = asset
	out.id = s.binding
	out.binding_id = s.binding
	return _fail(out, ctx.not_ready_error(asset), false)


static func _fail(out: Dictionary, error: String, unknown: bool) -> Dictionary:
	out.error = error
	out.unknown = unknown
	return out
