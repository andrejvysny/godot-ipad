class_name ToolCommands
extends RefCounted
## One-shot document edits and lookups used by ToolController. Each edit is one EditTransaction;
## the caller commits the returned change. Expected failures come back as error strings.

const DUPLICATE_OFFSET := Vector2(3.0, 1.5)
const EMPTY_SOURCE_MESSAGE := "The scatter source is empty. Pick a set or tick assets."


## "" while the document may take one more object, else the refusal message (per-schema limit).
static func object_limit_error(doc: WorldDocument) -> String:
	var limit := doc.max_objects()
	if doc.objects.size() >= limit:
		return "Object limit reached (%d)." % limit
	return ""


## {error, id, change}. The copy is a manual object grounded on the terrain at the clamped offset
## position, with the source's height offset and grounding mode.
static func duplicate_object(ctx: ToolContext, source: ObjectRecord) -> Dictionary:
	var doc := ctx.document
	var limit := object_limit_error(doc)
	if limit != "":
		return {"error": limit, "id": "", "change": null}
	var lo := doc.layout.world_min()
	var hi := doc.layout.world_max_sample()
	var x := clampf(source.position[0] + DUPLICATE_OFFSET.x, lo.x, hi.x)
	var z := clampf(source.position[2] + DUPLICATE_OFFSET.y, lo.y, hi.y)
	var h := doc.sample_height(x, z)
	if is_nan(h):
		return {"error": "No terrain under the copy.", "id": "", "change": null}
	var asset := ctx.catalog.get_asset(source.asset_id)
	var copy := source.clone()
	copy.object_id = ObjectRecord.new_uuid_v4()
	copy.origin = WorldConstants.ORIGIN_MANUAL
	copy.scatter_operation_id = ""
	copy.set_position(x, h + source.height_offset_m, z)
	var tx := EditTransaction.new()
	tx.begin(doc, "duplicate", "Duplicate %s" % (asset.display_name if asset != null else source.asset_id))
	if not tx.capture_object(copy.object_id):
		tx.rollback()
		return {"error": "Action memory budget exceeded.", "id": "", "change": null}
	doc.put_object(copy)
	ctx.presenter.sync_object(doc, copy.object_id)
	return {"error": "", "id": copy.object_id, "change": tx.finish()}


## {error, change}.
static func delete_path(ctx: ToolContext, path_id: String) -> Dictionary:
	var tx := EditTransaction.new()
	tx.begin(ctx.document, "path", "Delete path")
	if not tx.capture_path(path_id):
		tx.rollback()
		return {"error": "Action memory budget exceeded.", "change": null}
	ctx.document.remove_path(path_id)
	return {"error": "", "change": tx.finish()}


## Resolved scatter source: {name, items[{asset_id, weight}], density, spacing, slope_min, slope_max,
## align}. Items whose asset is missing from the catalog or not scatter_allowed are dropped, so an
## unknown set or an older catalog yields fewer (possibly zero) items, never an error.
static func scatter_config(source: String, store: ScatterSetStore, mix: PackedStringArray,
		catalog: AssetCatalog) -> Dictionary:
	var raw := {"name": "", "items": [], "density": 1.0, "spacing": 1.0, "slope_min": 0.0,
			"slope_max": 90.0, "align": false}
	if source == "mix":
		raw = {"name": "Quick mix", "items": [], "density": 1.2, "spacing": 0.8, "slope_min": 0.0,
				"slope_max": 45.0, "align": true}
		for id in mix:
			(raw.items as Array).append({"asset_id": id, "weight": 1.0})
	elif source.begins_with("set:"):
		var found := store.get_set(source.trim_prefix("set:"))
		if not found.is_empty():
			raw = found
	var items: Array[Dictionary] = []
	for item: Dictionary in raw.items:
		var asset := catalog.get_asset(str(item.asset_id))
		if asset != null and asset.scatter_allowed:
			items.append({"asset_id": item.asset_id, "weight": item.weight})
	raw.items = items
	return raw


static func error_message(err: String) -> String:
	match err:
		BrushKernels.ERROR_BUDGET:
			return "Stroke cancelled: action memory budget exceeded."
		SculptStroke.ERROR_STALL:
			return "Stroke cancelled: frame stall over 250 ms."
	return "Operation cancelled: %s." % err
