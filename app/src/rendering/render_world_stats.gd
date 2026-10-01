class_name RenderWorldStats
extends RefCounted
## Read-only counters and notices of ObjectRenderWorld (spec §7.5, §19). Triangle figures are estimates
## (instances x prepared triangles of the drawn representation), separate from measured renderer primitives.


## `base` carries the world's own counters (full_uploads/partial_uploads of retired batches, batch_builds,
## pending_builds, world_epoch) and pooled_nodes; `promoted` is {"asset", "rep"} or {} without a promoted node.
static func collect(cells: Dictionary, res: RenderWorldResources, base: Dictionary, promoted: Dictionary) -> Dictionary:
	var out := {"cells": cells.size(), "batches": 0, "instances": 0, "promoted": 0, "placeholders": 0,
		"estimated_triangles": 0, "nodes": int(base.pooled_nodes)}
	out.merge(base)
	for cell: RenderCell in cells.values():
		for key: String in cell.batches:
			var batch: InstanceBatch = cell.batches[key]
			var parts := key.rsplit("|", true, 1)
			out.batches += 1
			out.nodes += 1
			out.instances += batch.count
			out.estimated_triangles += batch.count * res.triangles(parts[0], parts[1])
			out.full_uploads += batch.full_uploads
			out.partial_uploads += batch.partial_uploads
			if parts[1] == RenderWorldResources.PLACEHOLDER:
				out.placeholders += batch.count
	if not promoted.is_empty():
		out.promoted = 1
		out.instances += 1
		out.estimated_triangles += res.triangles(promoted.asset, promoted.rep)
		if promoted.rep == RenderWorldResources.PLACEHOLDER:
			out.placeholders += 1
	return out


## One message per world (PREF-15) naming the NOT_READY assets drawn as placeholders; "" when there are none.
static func placeholder_notice(cells: Dictionary, asset_cells: Dictionary, res: RenderWorldResources) -> String:
	var missing := PackedStringArray()
	var objects := 0
	for asset_id: String in asset_cells:
		if not res.is_ready(asset_id):
			missing.append(asset_id)
			for key: Vector2i in (asset_cells[asset_id] as Dictionary):
				objects += ((cells[key] as RenderCell).members[asset_id] as Dictionary).size()
	if missing.is_empty():
		return ""
	missing.sort()
	return "%d objects use placeholders: render derivatives missing for %s" % [objects, ", ".join(missing)]
