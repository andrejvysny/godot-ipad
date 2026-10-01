class_name ToolController
extends Node
## Routes input-router tool actions to one operation at a time, owns tool settings, selection and
## single-action object edits. Operations never touch history: every committed WorldChange goes
## through ToolContext.commit. Expected failures return error strings or ToolContext.diagnostic
## messages; nothing here calls push_error.

signal tool_changed(tool_id: String)
signal selection_changed(id: String)
signal settings_changed(tool_id: String)
signal operation_started(tool_id: String)
signal operation_finished(change: WorldChange)
signal operation_cancelled(reason: String)

const TOOL_SELECT := "select"
const TOOL_PLACE := "place"
const TOOL_PAINT := "paint"
const TOOL_SCULPT := "sculpt"
const TOOL_PATH := "path"
const TOOLS: Array[String] = [TOOL_SELECT, TOOL_PLACE, TOOL_PAINT, TOOL_SCULPT, TOOL_PATH]
const STRENGTH_MIN := 0.05
const STRENGTH_MAX := 1.0
const BUSY := "Another operation is in progress."
const NO_SELECTION := "Select an object first."

var editing_enabled := true

var _ctx: ToolContext
var _settings: Dictionary = {}
var _active_tool := TOOL_SELECT
var _snap := true
var _ring: BrushRing
var _op: RefCounted
var _op_tool := ""
var _drop := false  # _op is a Library drop, not a router-owned contact
var _ignore_contact := false
var _selected := ""
var _last_hit := TerrainHit.new()
var _edit_tx: EditTransaction
var _edit_kind := ""
var _edit_id := ""


func setup(ctx: ToolContext) -> void:
	_ctx = ctx
	var strength := float(ctx.default("brush", "strength_default", 0.8))
	_settings = {
		TOOL_PAINT: {"radius": float(ctx.default("brush", "paint_radius_default_m", 4.0)),
				"strength": strength, "material": "dirt", "pressure_enabled": true},
		TOOL_SCULPT: {"radius": float(ctx.default("brush", "sculpt_radius_default_m", 6.0)),
				"strength": float(ctx.default("brush", "sculpt_strength_default", 1.0)), "direction": "raise", "pressure_enabled": true},
		TOOL_PATH: {"width": float(ctx.default("brush", "path_width_default_m", 3.0))},
		TOOL_PLACE: {"asset_id": ""},
		TOOL_SELECT: {},
	}
	_snap = true
	_active_tool = TOOL_SELECT
	if _ring == null:
		_ring = BrushRing.new()
		add_child(_ring)


func set_document(doc: WorldDocument) -> String:
	if has_active_operation():
		return BUSY
	_ctx.document = doc
	select("")
	return ""


func active_tool() -> String:
	return _active_tool


func set_active_tool(id: String) -> String:
	if id not in TOOLS:
		return "Unknown tool '%s'." % id
	if has_active_operation():
		return BUSY
	_ctx.presenter.hide_ghost()
	if id != _active_tool:
		_active_tool = id
		tool_changed.emit(id)
	return ""


func settings(tool_id: String) -> Dictionary:
	return (_settings.get(tool_id, {}) as Dictionary).duplicate(true)


func set_setting(tool_id: String, key: String, value: Variant) -> String:
	if not _settings.has(tool_id) or not (_settings[tool_id] as Dictionary).has(key):
		return "Unknown setting '%s.%s'." % [tool_id, key]
	var checked := _validate_setting(tool_id, key, value)
	if checked.error != "":
		return checked.error
	(_settings[tool_id] as Dictionary)[key] = checked.value
	settings_changed.emit(tool_id)
	return ""


func snap_enabled() -> bool:
	return _snap


func set_snap_enabled(on: bool) -> void:
	if on != _snap:
		_snap = on
		settings_changed.emit(TOOL_SELECT)


func last_hit() -> TerrainHit:
	return _last_hit


# --- Pointer operations ------------------------------------------------------------------

func handle_tool_action(action: Dictionary) -> void:
	var kind: String = action.get("type", "")
	if kind == "tool_cancel":
		_ignore_contact = false
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
		TOOL_PAINT:
			return "Painting"
		TOOL_SCULPT:
			return "Sculpting"
		TOOL_PATH:
			return "Drawing path"
		TOOL_PLACE:
			return "Placing"
	return "Moving" if _op.is_moving() else "Idle"


## Rolls back whatever is active; for non-input cancellation (backgrounding, document swap).
func cancel_active(reason: String) -> void:
	if _op != null:
		_cancel_op(reason)
	if _edit_tx != null:
		cancel_object_edit()


func _on_begin(sample: PointerSample) -> void:
	if has_active_operation():
		return
	_ignore_contact = false
	_last_hit = _ctx.hit_for(sample)
	var op := _make_operation()
	if op == null:
		_ignore_contact = true
		return
	_op = op
	_op_tool = _active_tool
	operation_started.emit(_active_tool)
	_op.begin(sample, _last_hit)
	_check_error()


func _make_operation() -> RefCounted:
	match _active_tool:
		TOOL_SELECT:
			return SelectOperation.new(_ctx, _snap, _selected)
		TOOL_PLACE:
			var asset := _ctx.catalog.get_asset(str(_settings[TOOL_PLACE].asset_id))
			if asset == null:
				_ctx.report("Choose an asset in the Library first.")
				return null
			return PlaceOperation.new(_ctx, asset, _snap)
	return BrushOperation.new(_ctx, _ring, _active_tool, settings(_active_tool))


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
		_ctx.report(_error_message(op.error))
		operation_cancelled.emit("tool_error")
		return
	_commit(change)
	if tool_id == TOOL_PLACE and op.created_id() != "":
		select(op.created_id())
		set_active_tool(TOOL_SELECT)
	elif tool_id == TOOL_SELECT and op.tap_selection() != null:
		select(str(op.tap_selection()))


func _check_error() -> void:
	if _op == null or _op.error == "":
		return
	_ctx.report(_error_message(_op.error))
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
	var err := set_setting(TOOL_PLACE, "asset_id", asset_id)
	if err != "":
		return err
	_op = PlaceOperation.new(_ctx, _ctx.catalog.get_asset(asset_id), _snap)
	_op_tool = TOOL_PLACE
	_drop = true
	operation_started.emit(TOOL_PLACE)
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


static func _error_message(err: String) -> String:
	match err:
		BrushKernels.ERROR_BUDGET:
			return "Stroke cancelled: action memory budget exceeded."
		SculptStroke.ERROR_STALL:
			return "Stroke cancelled: frame stall over 250 ms."
	return "Operation cancelled: %s." % err


# --- Settings validation -----------------------------------------------------------------

func _validate_setting(tool_id: String, key: String, value: Variant) -> Dictionary:
	var bad := {"error": "Invalid value for %s.%s." % [tool_id, key], "value": null}
	match key:
		"radius", "width", "strength":
			if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
				return bad
			var v := float(value)
			if not is_finite(v):
				return bad
			return {"error": "", "value": _clamp_numeric(tool_id, key, v)}
		"material":
			return {"error": "", "value": value} if value in ["grass", "dirt"] else bad
		"direction":
			return {"error": "", "value": value} if value in ["raise", "lower"] else bad
		"pressure_enabled":
			return {"error": "", "value": value} if typeof(value) == TYPE_BOOL else bad
		"asset_id":
			if typeof(value) == TYPE_STRING and _ctx.catalog.get_asset(value) != null:
				return {"error": "", "value": value}
			return {"error": "Unknown asset '%s'." % str(value), "value": null}
	return bad


func _clamp_numeric(tool_id: String, key: String, v: float) -> float:
	if key == "strength":
		return clampf(v, STRENGTH_MIN, STRENGTH_MAX)
	var prefix := "path_width" if key == "width" else tool_id + "_radius"
	return clampf(v, float(_ctx.default("brush", prefix + "_min_m", 1.0)),
			float(_ctx.default("brush", prefix + "_max_m", 16.0)))


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
