class_name ToolController
extends ToolObjects
## Routes input-router tool actions to one operation at a time, on top of ToolObjects (selection,
## object edits) and ToolModel. Operations never touch history: every committed
## WorldChange goes through ToolContext.commit. Expected failures return error strings or
## ToolContext.diagnostic messages; nothing here calls push_error. Spec: docs/editor-v2.md §2.

signal operation_started(tool_id: String)

const OP_PLACE := "place"  # operation kind of an armed placement or Library drop
## Tools with a working operation; every other tool reports "arrives in a later build".
const IMPLEMENTED: Array[String] = ["raise", "flatten", "noise", "paint", "spray", "tint", "pick", "path",
		"select", "scatter", "erase", "fill"]

var _ring: BrushRing
var _lasso: LassoPreview
var _path_preview: PathPreview
var _op: RefCounted
var _op_tool := ""
var _drop := false  # _op is a Library drop, not a router-owned contact
var _ignore_contact := false
var _last_hit := TerrainHit.new()


func setup(ctx: ToolContext) -> void:
	_setup_model(ctx)
	if _ring == null:
		_ring = BrushRing.new()
		add_child(_ring)
	if _lasso == null:
		_lasso = LassoPreview.new()
		add_child(_lasso)
	if _path_preview == null:
		_path_preview = PathPreview.new()
		add_child(_path_preview)


func set_document(doc: WorldDocument) -> String:
	if has_active_operation():
		return BUSY
	_ctx.document = doc
	select("")
	select_path("")
	return ""


func last_hit() -> TerrainHit:
	return _last_hit


## Turns the yaw of the placement in progress (armed contact or Library drop).
func rotate_ghost(delta_deg: float) -> String:
	if not (_op is PlaceOperation) or not is_finite(delta_deg):
		return "No placement in progress."
	(_op as PlaceOperation).rotate_yaw(delta_deg)
	return ""


## State of the open PlaceOperation for the ghost label (PlaceOperation.preview()).
func place_preview() -> Dictionary:
	return (_op as PlaceOperation).preview() if _op is PlaceOperation else PlaceOperation.empty_preview()


# --- Pointer operations ------------------------------------------------------------------

func handle_tool_action(action: Dictionary) -> void:
	var kind: String = action.get("type", "")
	if kind == "tool_cancel":
		_ignore_contact = false
		_pick_contact = false
		if _op != null:
			_cancel_op(str(action.get("reason", "")))
		return
	if not editing_enabled or _drop:
		return
	var sample: PointerSample = action.get("sample")
	match kind:
		"tool_begin":
			_on_begin(sample)
		"tool_move", "tool_resume":
			_on_move(kind == "tool_resume", sample)
		"tool_pause":
			if _op != null:
				_op.pause(sample)
				_check_error()
		"tool_end":
			_on_end(sample, bool(action.get("over_ui", false)))


func advance(now: float) -> void:
	if _op != null:
		_op.advance(now)
		_check_error()


func has_active_operation() -> bool:
	return _op != null or _edit_tx != null


func active_operation_id() -> String:
	if _op != null:
		return _op.operation_id()
	return _edit_tx.operation_id if _edit_tx != null else ""


func stroke_state() -> String:
	if _edit_tx != null:
		return "Editing object"
	if _op == null:
		return "Idle"
	if _op.has_method("stroke_state"):
		return _op.call("stroke_state")
	match _op_tool:
		"paint", "spray", "tint":
			return "Painting"
		"raise", "flatten", "noise":
			return "Sculpting"
		OP_PLACE:
			return "Placing"
	return "Moving" if _op.is_moving() else "Idle"


## Rolls back whatever is active; for non-input cancellation (backgrounding, document swap).
func cancel_active(reason: String) -> void:
	if _op != null:
		_cancel_op(reason)
	if _edit_tx != null:
		cancel_object_edit()
	rule_edits().cancel_scrub()


func _on_begin(sample: PointerSample) -> void:
	if has_active_operation() or _pick_contact:
		return
	_ignore_contact = false
	_last_hit = _ctx.hit_for(sample)
	if _picking:
		_pick_contact = true
		return
	var op := _make_operation()
	if op == null:
		_ignore_contact = true
		return
	_op = op
	_op_tool = OP_PLACE if _armed != "" else active_tool()
	operation_started.emit(_op_tool)
	_op.begin(sample, _last_hit)
	_check_error()


## Null (after reporting why) when the contact starts nothing.
func _make_operation() -> RefCounted:
	if _armed != "":
		var asset := _ctx.catalog.get_asset(_armed)
		if asset == null:
			disarm()
			_ctx.report("Choose an asset in the Library first.")
			return null
		var not_ready := _ctx.not_ready_error(asset)
		if not_ready != "":
			disarm()
			_ctx.report(not_ready)
			return null
		return PlaceOperation.new(_ctx, asset, _snap)
	var tool_id := active_tool()
	if tool_id not in IMPLEMENTED:
		_ctx.report("%s arrives in a later build." % TOOL_LABELS[tool_id])
		return null
	if ScatterTools.handles(tool_id):
		return ScatterTools.make(_ctx, _ring, _lasso, tool_id, self)
	match tool_id:
		TOOL_SELECT:
			return SelectOperation.new(_ctx, _snap, _selected)
		TOOL_PATH:
			return PathTools.make(_ctx, _path_preview, _selected_path, _last_hit, float(_values.values("path").width))
		"raise", "flatten", "noise":
			return BrushOperation.new(_ctx, _ring, "sculpt", _brush_settings("sculpt", tool_id))
		"paint", "spray", "tint":
			return BrushOperation.new(_ctx, _ring, "paint", _brush_settings("paint", tool_id))
		"pick":
			return PickOperation.new(_ctx)
	return null


## Mode namespace plus the shared brush alpha, the invert state and the flatten target, in the
## shape BrushOperation reads.
func _brush_settings(ns: String, tool_id: String) -> Dictionary:
	var s := _values.values(ns)
	var brush := _values.values("brush")
	s["tool"] = tool_id
	s["inverted"] = _inverted
	s["pressure_enabled"] = brush.pressure_enabled
	s["shape"] = brush.shape
	s["alpha_mode"] = brush.alpha_mode
	s["target"] = _values.values("flatten").target
	return s


func _on_move(is_resume: bool, sample: PointerSample) -> void:
	if _op == null:
		return
	_last_hit = _ctx.hit_for(sample)
	if is_resume:
		_op.resume(sample, _last_hit)
	else:
		_op.move(sample, _last_hit)
	_check_error()


func _on_end(sample: PointerSample, over_ui: bool) -> void:
	_ignore_contact = false
	if _pick_contact:
		_pick_contact = false
		_finish_height_pick(sample, over_ui)
		return
	if _op == null:
		return
	_last_hit = _ctx.hit_for(sample)
	_finish(sample, over_ui)


## Ends the open operation at _last_hit; shared by router-owned contacts and Library drops.
func _finish(sample: PointerSample, over_ui: bool) -> void:
	var op := _op
	var tool_id := _op_tool
	var change: WorldChange = op.end(sample, _last_hit, over_ui)
	_op = null
	_drop = false
	if op.error != "":
		op.cancel()
		_ctx.report(ToolCommands.error_message(op.error))
		operation_cancelled.emit("tool_error")
		return
	_commit(change)
	if tool_id == OP_PLACE and op.created_id() != "":
		select(op.created_id())
		disarm()
		set_tool(TOOL_SELECT)
	elif tool_id == TOOL_SELECT and op.tap_selection() != null:
		select(str(op.tap_selection()))
	elif op is PathDrawOperation:
		_finish_path_draw(op as PathDrawOperation)
	elif tool_id == "pick" and (op as PickOperation).picked_layer() >= 0:
		_apply_pick((op as PickOperation).picked_layer())


## A drawn path becomes the selection; a tap selects the nearest path or clears the selection.
func _finish_path_draw(op: PathDrawOperation) -> void:
	if op.created_id() != "":
		select_path(op.created_id())
	elif op.tap_selection() != null:
		select_path(str(op.tap_selection()))


func _apply_pick(layer: int) -> void:
	_values.set_value("paint", "layer", layer)
	settings_changed.emit("paint")
	set_tool(TOOL_PAINT)
	_ctx.report("Picked %s" % TerrainRules.LAYER_NAMES[layer])


func _finish_height_pick(sample: PointerSample, over_ui: bool) -> void:
	if over_ui or not _picking:
		return
	_last_hit = _ctx.hit_for(sample)
	if not _last_hit.ok:
		_ctx.report("No terrain under the Pencil.")
		return
	_values.set_value("flatten", "target", _last_hit.position.y)
	_picking = false
	settings_changed.emit(TOOL_FLATTEN)
	_ctx.report("Target height %.1f m" % float(_values.values("flatten").target))


func _check_error() -> void:
	if _op == null or _op.error == "":
		return
	_ctx.report(ToolCommands.error_message(_op.error))
	if _ctx.request_cancel.is_valid():
		_ctx.request_cancel.call("tool_error")
	if _op != null:
		_cancel_op("tool_error")


func _cancel_op(reason: String) -> void:
	var op := _op
	_op = null
	_drop = false
	op.cancel()
	operation_cancelled.emit(reason)


# --- Library drops: a Pencil drag from a Library tile stays owned by that control (input contract
# §2), which forwards root-viewport positions here. Router tool actions except tool_cancel are ignored.

func begin_drop(asset_id: String) -> String:
	if not editing_enabled:
		return "Editing is disabled."
	if has_active_operation():
		return BUSY
	var asset := _ctx.catalog.get_asset(asset_id)
	if asset == null:
		return "Unknown asset '%s'." % asset_id
	var not_ready := _ctx.not_ready_error(asset)
	if not_ready != "":
		return not_ready
	_cancel_height_pick()
	_op = PlaceOperation.new(_ctx, asset, _snap)
	_op_tool = OP_PLACE
	_drop = true
	operation_started.emit(OP_PLACE)
	return ""


func has_drop() -> bool:
	return _drop


func update_drop(pos: Vector2, over_ui: bool) -> void:
	if not _drop:
		return
	if over_ui:
		_op.pause(null)
	else:
		_last_hit = _ctx.hit_at(pos)
		_op.move(null, _last_hit)  # PlaceOperation sets errors only in end()


## Commits at a valid terrain hit outside the interface, otherwise cancels; a no-op once closed.
func finish_drop(pos: Vector2, over_ui: bool) -> void:
	if _drop:
		_last_hit = _ctx.hit_at(pos)
		_finish(null, over_ui)
