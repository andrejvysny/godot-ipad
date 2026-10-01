class_name Regrounder
extends RefCounted
## TE-11: FOLLOW_TERRAIN objects inside a changed terrain rect follow the ground, captured into
## the operation's own transaction. Shared by sculpt strokes and path drawing.


## Returns "" or BrushKernels.ERROR_BUDGET (the caller must then roll back).
static func followers(ctx: ToolContext, tx: EditTransaction, rect: Rect2) -> String:
	var doc := ctx.document
	for id in doc.sorted_object_ids():
		var rec := doc.get_object(id)
		if rec.grounding != WorldConstants.GROUNDING_FOLLOW \
				or not rect.has_point(Vector2(rec.position[0], rec.position[2])):
			continue
		var h := doc.sample_height(rec.position[0], rec.position[2])
		var new_y := h + rec.height_offset_m
		if not is_finite(new_y) or new_y == rec.position[1]:
			continue
		if not tx.capture_object(id):
			return BrushKernels.ERROR_BUDGET
		var moved := rec.clone()
		moved.set_position(rec.position[0], new_y, rec.position[2])
		doc.put_object(moved)
		ctx.presenter.sync_object(doc, id)
	return ""
