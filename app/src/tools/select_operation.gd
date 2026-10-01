class_name SelectOperation
extends RefCounted
## Tap-to-select and drag-to-move (spec §14.4). A drag only grabs the already-selected object;
## it begins a transaction after the contact moves past the tap threshold, preserving the grab
## offset so the object never jumps to the pencil (OB-02). Explicit moves ground the object at
## `height_offset_m` above terrain for either grounding mode (spec §10.5).

var error: String = ""

var _ctx: ToolContext
var _snap: bool
var _pick_id := ""
var _grab_id := ""
var _start_vp := Vector2.ZERO
var _threshold := 0.0
var _offset := Vector2.ZERO
var _have_offset := false
var _dragging := false
var _tx := EditTransaction.new()
var _tap: Variant = null
var _id := ObjectRecord.new_uuid_v4()


func _init(ctx: ToolContext, snap: bool, selected_id: String) -> void:
	_ctx = ctx
	_snap = snap
	_grab_id = selected_id
	_threshold = float(ctx.default("input", "tap_move_threshold_pt", 8.0)) * float(ctx.units_per_point.call())


func operation_id() -> String:
	return _id


## String id (possibly "") when a selection change is requested, otherwise null.
func tap_selection() -> Variant:
	return _tap


func begin(sample: PointerSample, hit: TerrainHit) -> void:
	_start_vp = sample.position_viewport
	var cam := _ctx.camera
	var pick := _ctx.presenter.pick(cam.project_ray_origin(sample.position_viewport),
			cam.project_ray_normal(sample.position_viewport))
	_pick_id = pick.id
	if _pick_id == "" or _pick_id != _grab_id:
		_grab_id = ""
	_learn_offset(hit)


func move(sample: PointerSample, hit: TerrainHit) -> void:
	if _grab_id == "" or error != "":
		return
	if not _dragging:
		if sample.position_viewport.distance_to(_start_vp) <= _threshold:
			return
		_start_drag()
		if error != "":
			return
	_learn_offset(hit)
	_try_move(hit)


func resume(sample: PointerSample, hit: TerrainHit) -> void:
	move(sample, hit)


func pause(_sample: PointerSample) -> void:
	pass


func advance(_now: float) -> void:
	pass


func end(_sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if not _dragging:
		if not over_ui:
			_tap = _pick_id
		return null
	if over_ui or not hit.ok or not _try_move(hit):
		cancel()
		_ctx.report("Move cancelled: lift the Pencil over terrain to drop the object.")
		return null
	return _tx.finish()


func cancel() -> void:
	if _dragging:
		_dragging = false
		_ctx.mark_touched(_tx.rollback())


func _learn_offset(hit: TerrainHit) -> void:
	if _have_offset or _grab_id == "" or not hit.ok:
		return
	var rec := _ctx.document.get_object(_grab_id)
	if rec == null:
		return
	_offset = Vector2(rec.position[0] - hit.position.x, rec.position[2] - hit.position.z)
	_have_offset = true


func _start_drag() -> void:
	var rec := _ctx.document.get_object(_grab_id)
	if rec == null:
		_grab_id = ""
		return
	var asset := _ctx.catalog.get_asset(rec.asset_id)
	var label_name := asset.display_name if asset != null else rec.asset_id
	_tx.begin(_ctx.document, "move", "Move %s" % label_name)
	if not _tx.capture_object(_grab_id):
		_tx.rollback()
		error = BrushKernels.ERROR_BUDGET
		return
	_dragging = true


## Returns false when the hit cannot place the object; the object is then left where it was.
func _try_move(hit: TerrainHit) -> bool:
	if not hit.ok or not _have_offset:
		return false
	var x: float = hit.position.x + _offset.x
	var z: float = hit.position.z + _offset.y
	if _snap:
		var step := float(_ctx.default("placement", "move_snap_m", 0.5))
		x = snappedf(x, step)
		z = snappedf(z, step)
	if not _ctx.document.layout.is_inside_world(x, z):
		return false
	var doc := _ctx.document
	var h := doc.sample_height(x, z)
	var rec := doc.get_object(_grab_id)
	if is_nan(h) or rec == null:
		return false
	var moved := rec.clone()
	moved.set_position(x, h + rec.height_offset_m, z)
	doc.put_object(moved)
	_ctx.presenter.sync_object(doc, _grab_id)
	return true


func is_moving() -> bool:
	return _dragging
