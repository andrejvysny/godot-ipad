class_name ToolObjects
extends ToolModel
## Object and path selection plus single-action object edits (docs/editor-v2.md §2, §8). Split
## from ToolController, which overrides has_active_operation() and adds pointer operations.

signal selection_changed(id: String)
signal path_selection_changed(id: String)
signal operation_finished(change: WorldChange)
signal operation_cancelled(reason: String)

const NO_SELECTION := "Select an object first."
const NO_PATH_SELECTION := "Select a path first."

var _selected := ""
var _selected_path := ""
var _edit_tx: EditTransaction
var _edit_kind := ""
var _edit_id := ""


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
	var refused := _ctx.read_only_refusal()
	if refused != "":
		return refused
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
	var asset := _ctx.document.assets.definition(rec.binding_id)
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
	var refused := _ctx.read_only_refusal()
	if refused != "":
		return refused
	if has_active_operation():
		return BUSY
	var res := ToolCommands.duplicate_object(_ctx, selected_record())
	if res.error != "":
		return res.error
	_commit(res.change)
	select(res.id)
	return ""


## Update review (shared spec §7): one history action moves the records `ids` to the prepared binding. Blocked while
## an operation or object edit is open; the other objects of the old binding stay as they are.
func rebind_objects(ids: Array, binding_id: String, overrides: Dictionary = {}) -> String:
	var refused := _ctx.read_only_refusal()
	if refused != "":
		return refused
	if has_active_operation():
		return BUSY
	var res := ToolCommands.rebind_objects(_ctx, ids, binding_id, overrides)
	if res.error != "":
		return res.error
	_commit(res.change)
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
	var refused := _ctx.read_only_refusal()
	if refused != "":
		return refused
	if has_active_operation():
		return BUSY
	var rec := selected_record()
	var asset := _ctx.document.assets.definition(rec.binding_id)
	var tx := EditTransaction.new()
	tx.begin(_ctx.document, tool_id, label_format % (asset.display_name if asset != null else rec.binding_id))
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
