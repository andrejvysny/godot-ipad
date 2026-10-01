class_name ScatterTools
extends RefCounted
## Operation factory for the Place-mode scatter tools (scatter, erase, fill), kept out of the
## ToolController. Spec: docs/editor-v2.md §2 (settings), §6 (sources, invert).

const TOOLS: Array[String] = ["scatter", "erase", "fill"]


static func handles(tool_id: String) -> bool:
	return tool_id in TOOLS


## Null (after reporting why) when the contact starts nothing. Add modes need a non-empty source;
## erase and clear never do.
static func make(ctx: ToolContext, ring: BrushRing, lasso: LassoPreview, tool_id: String,
		model: ToolModel) -> RefCounted:
	var erase := tool_id == "erase" or model.inverted()
	var config := model.scatter_config()
	if not erase and (config.items as Array).is_empty():
		ctx.report(ToolCommands.EMPTY_SOURCE_MESSAGE)
		return null
	if not erase:
		for item: Dictionary in config.items:
			var asset := ctx.catalog.get_asset(str(item.asset_id))
			var refusal := ctx.not_ready_error(asset) if asset != null else ""
			if refusal != "":
				ctx.report(refusal)
				return null
	var place := model.settings("place")
	var brush := model.settings("brush")
	var settings := {"radius": place.radius, "strength": place.strength, "shape": brush.shape,
			"alpha_mode": brush.alpha_mode, "pressure_enabled": brush.pressure_enabled,
			"avoid": bool(model.settings("scatter").avoid_objects), "config": config, "erase": erase}
	if tool_id == "fill":
		return FillOperation.new(ctx, lasso, settings)
	return ScatterOperation.new(ctx, ring, tool_id, settings)
