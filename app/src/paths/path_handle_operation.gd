class_name PathHandleOperation
extends RefCounted
## Drag of one control point of the selected path (docs/editor-v2.md §7). The point follows the
## terrain hit in XZ (clamped to the world extent), the ribbon re-renders live, and the contact is
## one action "Edit path"; heights are untouched. A contact that never moves, or ends where it
## started, leaves no history. A non-empty `error` means the controller must cancel.

const TOOL_ID := "path"

var error := ""

var _ctx: ToolContext
var _path_id: String
var _index: int
var _tx := EditTransaction.new()
var _id := ObjectRecord.new_uuid_v4()
var _captured := false
var _moved := false
var _done := false


func _init(ctx: ToolContext, path_id: String, index: int) -> void:
	_ctx = ctx
	_path_id = path_id
	_index = index


func operation_id() -> String:
	return _tx.operation_id if _tx.operation_id != "" else _id


func stroke_state() -> String:
	return "Editing path"


func path_id() -> String:
	return _path_id


func begin(_sample: PointerSample, _hit: TerrainHit) -> void:
	_tx.begin(_ctx.document, TOOL_ID, "Edit path", {"tool": TOOL_ID, "point": _index})


func move(_sample: PointerSample, hit: TerrainHit) -> void:
	_drag_to(hit)


func resume(_sample: PointerSample, hit: TerrainHit) -> void:
	_drag_to(hit)


func pause(_sample: PointerSample) -> void:
	pass


func advance(_now: float) -> void:
	pass


func end(_sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if not over_ui and _moved:
		_drag_to(hit)
	_done = true
	if error != "":
		_rollback()
		return null
	return _tx.finish()


func cancel() -> void:
	if not _done:
		_done = true
		_rollback()


func _rollback() -> void:
	_ctx.mark_touched(_tx.rollback())
	_ctx.notify_path([_path_id])


func _drag_to(hit: TerrainHit) -> void:
	if not hit.ok or error != "" or _done:
		return
	var rec := _ctx.document.get_path_record(_path_id)
	if rec == null or _index >= rec.points.size():
		error = "path no longer exists"
		return
	if not _captured:
		if not _tx.capture_path(_path_id):
			error = BrushKernels.ERROR_BUDGET
			return
		_captured = true
	var edited := rec.clone()
	var lo := _ctx.document.layout.world_min()
	var hi := _ctx.document.layout.world_max_sample()
	edited.points[_index] = Vector2(clampf(hit.position.x, lo.x, hi.x), clampf(hit.position.z, lo.y, hi.y))
	_moved = true
	_ctx.document.put_path(edited)
	_ctx.notify_path([_path_id])
