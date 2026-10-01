class_name StubRenderRegistry
extends RenderAssetRegistry
## A registry that reports chosen assets as NOT_READY (no derivatives) and defers the rest to a real one.

var _inner: RenderAssetRegistry
var _hidden: Dictionary = {}


static func hiding(catalog: AssetCatalog, asset_ids: Array) -> StubRenderRegistry:
	var r := StubRenderRegistry.new()
	r._inner = RenderAssetRegistry.load_from("res://assets/render_assets/index.json", catalog)
	for id: Variant in asset_ids:
		r._hidden[str(id)] = true
	return r


func is_ready(asset_id: String) -> bool:
	return not _hidden.has(asset_id) and _inner.is_ready(asset_id)


func descriptor(asset_id: String) -> RenderAssetDescriptor:
	return null if _hidden.has(asset_id) else _inner.descriptor(asset_id)


func status(asset_id: String) -> Dictionary:
	if _hidden.has(asset_id):
		return {"state": "NOT_READY", "reason": "no_derivative", "detail": "hidden by the test"}
	return _inner.status(asset_id)
