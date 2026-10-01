class_name ToolController
extends ToolModel
## Routes input-router tool actions to one operation at a time, owns selection and single-action
## object edits on top of the ToolModel. Operations never touch history: every committed
## WorldChange goes through ToolContext.commit. Expected failures return error strings or
## ToolContext.diagnostic messages; nothing here calls push_error. Spec: docs/editor-v2.md §2.

signal selection_changed(id: String)
signal path_selection_changed(id: String)
signal operation_started(tool_id: String)
signal operation_finished(change: WorldChange)
signal operation_cancelled(reason: String)

const OP_PLACE := "place"  # operation kind of an armed placement or Library drop
## Tools with a working operation; every other tool reports "arrives in a later build".
const IMPLEMENTED: Array[String] = ["raise", "paint", "path", "select"]
const NO_SELECTION := "Select an object first."
const NO_PATH_SELECTION := "Select a path first."
const LATER_PAINT_MESSAGE := "Rock and sand painting arrive in a later build."

var _ring: BrushRing
var _op: RefCounted
var _op_tool := ""
var _drop := false  # _op is a Library drop, not a router-owned contact
var _ignore_contact := false
var _selected := ""
var _selected_path := ""
var _last_hit := TerrainHit.new()
var _edit_tx: EditTransaction
var _edit_kind := ""
var _edit_id := ""


func setup(ctx: ToolContext) -> void:
	_setup_model(ctx)
	if _ring == null:
		_ring = BrushRing.new()
		add_child(_ring)


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
	match _op_tool:
		"paint", "spray", "tint":
			return "Painting"
		"raise", "flatten", "noise":
			return "Sculpting"
		"scatter":
			return "Scattering"
		"erase":
			return "Erasing"
		"fill":
			return "Filling"
		TOOL_PATH:
			return "Drawing path"
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
		return PlaceOperation.new(_ctx, asset, _snap)
	var tool_id := active_tool()
	if tool_id not in IMPLEMENTED:
		_ctx.report("%s arrives in a later build." % TOOL_LABELS[tool_id])
		return null
	match tool_id:
		TOOL_SELECT:
			return SelectOperation.new(_ctx, _snap, _selected)
		TOOL_PATH:
			return BrushOperation.new(_ctx, _ring, "path", {"width": _values.values("path").width})
		TOOL_RAISE:
			return BrushOperation.new(_ctx, _ring, "sculpt", _brush_settings("sculpt"))
	if _inverted or int(_values.values("paint").layer) > 1:
		_ctx.report(LATER_PAINT_MESSAGE)
		return null
	return BrushOperation.new(_ctx, _ring, "paint", _brush_settings("paint"))


## Settings in the shape BrushOperation reads (legacy keys: material, direction).
func _brush_settings(ns: String) -> Dictionary:
	var s := _values.values(ns)
	s["pressure_enabled"] = _values.values("brush").pressure_enabled
	if ns == "sculpt":
		s["direction"] = "lower" if _inverted else "raise"
	else:
		s["material"] = "dirt" if int(s.layer) == 1 else "grass"
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


# --- Selection ---------------------------------------------------------------------------

func selected_id() -> String:
	return _selected


func select(id: String) -> void:
	var target := id if _ctx.document.get_object(id) != null else ""
	_ctx.presenter.set_selected(target)
	if target == _selected:
		return
	_selected = target
	selection_changed.emit(target)


func selected_record() -> ObjectRecord:
	return _ctx.document.get_object(_selected) if _selected != "" else null


func validate_selection() -> void:
	if _selected != "" and _ctx.document.get_object(_selected) == null:
		select("")
	if _selected_path != "" and _ctx.document.get_path_record(_selected_path) == null:
		select_path("")


func selected_path_id() -> String:
	return _selected_path


func select_path(id: String) -> void:
	var target := id if _ctx.document.get_path_record(id) != null else ""
	if target == _selected_path:
		return
	_selected_path = target
	path_selection_changed.emit(target)


func delete_selected_path() -> String:
	if _selected_path == "":
		return NO_PATH_SELECTION
	if has_active_operation():
		return BUSY
	var res := ToolCommands.delete_path(_ctx, _selected_path)
	if res.error != "":
		return res.error
	select_path("")
	_commit(res.change)
	return ""


# --- Object edits ------------------------------------------------------------------------

func has_object_edit() -> bool:
	return _edit_tx != null


## kind: yaw | scale | height. One continuous drag is one history action.
func begin_object_edit(kind: String) -> String:
	var verb: String = {"yaw": "Rotate", "scale": "Scale", "height": "Height"}.get(kind, "")
	if verb == "":
		return "Unknown edit '%s'." % kind
	var err := _begin_tx("object_edit", verb + " %s")
	if err != "":
		return err
	_edit_kind = kind
	return ""


func update_object_edit(value: float) -> String:
	if _edit_tx == null:
		return "No object edit in progress."
	var rec := _ctx.document.get_object(_edit_id)
	if rec == null:
		return NO_SELECTION
	var asset := _ctx.catalog.get_asset(rec.asset_id)
	if asset == null or not is_finite(value):
		return "Value must be a finite number."
	var edited := rec.clone()
	var err := ""
	match _edit_kind:
		"yaw":
			ObjectEdits.apply_yaw(edited, value, float(_ctx.default("placement", "yaw_snap_deg", 15.0)) if _snap else 0.0)
		"scale":
			err = ObjectEdits.apply_scale(edited, value, asset)
		"height":
			err = ObjectEdits.apply_height_offset(edited, value, asset)
	if err == "":
		_store_edit(edited)
	return err


func end_object_edit() -> void:
	if _edit_tx == null:
		return
	var tx := _edit_tx
	_edit_tx = null
	_commit(tx.finish())


func cancel_object_edit() -> void:
	if _edit_tx == null:
		return
	var tx := _edit_tx
	_edit_tx = null
	_ctx.mark_touched(tx.rollback())
	operation_cancelled.emit("object_edit")


func nudge(kind: String, delta: float) -> String:
	var err := begin_object_edit(kind)
	if err != "":
		return err
	var rec := selected_record()
	var current := rad_to_deg(rec.get_yaw()) if kind == "yaw" \
			else rec.uniform_scale if kind == "scale" else rec.height_offset_m
	err = update_object_edit(current + delta)
	if err != "":
		cancel_object_edit()
		return err
	end_object_edit()
	return ""


func set_grounding(mode: String) -> String:
	var err := _begin_tx("grounding", "Ground %s")
	if err != "":
		return err
	var edited := selected_record().clone()
	err = ObjectEdits.apply_grounding(edited, mode, _ctx.document)
	if err != "":
		_ctx.mark_touched(_edit_tx.rollback())
		_edit_tx = null
		return err
	_store_edit(edited)
	end_object_edit()
	return ""


## Copy offset +3 m X, +1.5 m Z, grounded on the terrain; the copy becomes the selection.
func duplicate_selected() -> String:
	if _selected == "":
		return NO_SELECTION
	if has_active_operation():
		return BUSY
	var res := ToolCommands.duplicate_object(_ctx, selected_record())
	if res.error != "":
		return res.error
	_commit(res.change)
	select(res.id)
	return ""


func delete_selected() -> String:
	var err := _begin_tx("delete", "Delete %s")
	if err != "":
		return err
	_ctx.document.remove_object(_edit_id)
	_ctx.presenter.sync_object(_ctx.document, _edit_id)
	select("")
	end_object_edit()
	return ""


## Opens `_edit_tx` on the selected object; `label_format` takes the asset display name.
func _begin_tx(tool_id: String, label_format: String) -> String:
	if _selected == "":
		return NO_SELECTION
	if has_active_operation():
		return BUSY
	var rec := selected_record()
	var asset := _ctx.catalog.get_asset(rec.asset_id)
	var tx := EditTransaction.new()
	tx.begin(_ctx.document, tool_id, label_format % (asset.display_name if asset != null else rec.asset_id))
	if not tx.capture_object(_selected):
		tx.rollback()
		return "Action memory budget exceeded."
	_edit_tx = tx
	_edit_id = _selected
	return ""


func _store_edit(edited: ObjectRecord) -> void:
	_ctx.document.put_object(edited)
	_ctx.presenter.sync_object(_ctx.document, _edit_id)


func _commit(change: WorldChange) -> void:
	if change == null:
		return
	_ctx.commit.call(change)
	operation_finished.emit(change)
