class_name PathTools
extends RefCounted
## Operation factory of the Path tool (docs/editor-v2.md §7), kept out of the ToolController.

const GRAB_RADIUS_M := 1.5


## A contact beginning within GRAB_RADIUS_M (XZ) of a control point of the selected path drags that
## point; every other contact is a draw / tap-select.
static func make(ctx: ToolContext, preview: PathPreview, selected_path: String, hit: TerrainHit,
		width: float) -> RefCounted:
	var rec := ctx.document.get_path_record(selected_path) if selected_path != "" else null
	if rec != null and hit.ok:
		var index := nearest_point(rec, Vector2(hit.position.x, hit.position.z))
		if index >= 0:
			return PathHandleOperation.new(ctx, selected_path, index)
	return PathDrawOperation.new(ctx, preview, width)


## Index of the control point within GRAB_RADIUS_M of `p`, nearest first; -1 when none.
static func nearest_point(rec: PathRecord, p: Vector2) -> int:
	var best := -1
	var best_d := GRAB_RADIUS_M
	for i in rec.points.size():
		var d := rec.points[i].distance_to(p)
		if d <= best_d:
			best = i
			best_d = d
	return best
