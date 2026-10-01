class_name BrushOperation
extends RefCounted
## One paint / sculpt / path contact (spec §12, §13). Owns the EditTransaction. The stroke starts
## lazily on the first valid terrain hit; an invalid hit pauses it so no interval is ever bridged
## (TE-09). A non-empty `error` means the controller must cancel; the transaction is then rolled
## back by cancel(). Sculpt also re-grounds FOLLOW_TERRAIN objects in the same transaction (TE-11).

const TOOL_PAINT := "paint"
const TOOL_SCULPT := "sculpt"
const TOOL_PATH := "path"
const RING_GRASS := Color(0.35, 0.9, 0.3)
const RING_DIRT := Color(0.85, 0.6, 0.3)
const RING_RAISE := Color(0.95, 0.95, 0.4)
const RING_LOWER := Color(0.4, 0.8, 0.95)

var error: String = ""

var _ctx: ToolContext
var _ring: BrushRing
var _tool_id: String
var _settings: Dictionary
var _brush: Dictionary
var _tx := EditTransaction.new()
var _paint: PaintStroke
var _sculpt: SculptStroke
var _id := ObjectRecord.new_uuid_v4()
var _started := false
var _paused := false
var _done := false
var _radius := 1.0
var _color := RING_DIRT


func _init(ctx: ToolContext, ring: BrushRing, tool_id: String, settings: Dictionary) -> void:
	_ctx = ctx
	_ring = ring
	_tool_id = tool_id
	_settings = settings.duplicate(true)
	_brush = ctx.defaults.get("brush", {})


## The transaction's id once begun, so diagnostics match the committed WorldChange.
func operation_id() -> String:
	return _tx.operation_id if _tx.operation_id != "" else _id


func begin(sample: PointerSample, hit: TerrainHit) -> void:
	_tx.begin(_ctx.document, _tool_id, _label(), _settings)
	if hit.ok:
		_apply_sample(sample, hit, false)


func move(sample: PointerSample, hit: TerrainHit) -> void:
	if error != "":
		return
	if hit.ok:
		_apply_sample(sample, hit, false)
	else:
		_pause_at(sample.timestamp_s)


func resume(sample: PointerSample, hit: TerrainHit) -> void:
	if error != "" or not hit.ok:
		return
	_apply_sample(sample, hit, true)


func pause(sample: PointerSample) -> void:
	if error == "":
		_pause_at(sample.timestamp_s)


## Returns the committed change, or null when nothing changed or `error` was set.
func end(sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if error != "":
		return null
	if not over_ui and hit.ok:
		_apply_sample(sample, hit, false)
		if error != "":
			return null
	if _started:
		_begin_timing()
		var res: Dictionary = _paint.finish(sample.timestamp_s) if _paint != null \
				else _sculpt.finish(sample.timestamp_s)
		_end_timing()
		_take_result(res)
		if error != "":
			return null
	_ring.hide_ring()
	_done = true
	return _tx.finish()


func cancel() -> void:
	if _done:
		return
	_done = true
	var touched: Dictionary
	if _started:
		touched = _paint.cancel() if _paint != null else _sculpt.cancel()
	else:
		touched = _tx.rollback()
	_ctx.mark_touched(touched)
	_ring.hide_ring()


func advance(now: float) -> void:
	if _sculpt == null or error != "" or _done:
		return
	_begin_timing()
	var res := _sculpt.advance_to(now)
	_end_timing()
	_take_result(res)


func _apply_sample(sample: PointerSample, hit: TerrainHit, force_resume: bool) -> void:
	var pos := Vector2(hit.position.x, hit.position.z)
	var pf := 1.0
	if _tool_id != TOOL_PATH:
		pf = BrushMath.pressure_factor(sample.pressure_valid, sample.pressure,
				bool(_settings.get("pressure_enabled", true)), float(_brush.get("pressure_min_factor", 0.2)))
	var t := sample.timestamp_s
	_begin_timing()
	var res := BrushKernels.empty_result()
	if not _started:
		res = _start(t, pos, pf)
	elif _paused or force_resume:
		_paused = false
		res = _resume_stroke(t, pos, pf)
	else:
		res = _add_sample(t, pos, pf)
	_end_timing()
	_take_result(res)
	if error == "":
		_ring.show_at(_ctx.document, hit.position, _radius, _color)


func _start(t: float, pos: Vector2, pf: float) -> Dictionary:
	_started = true
	var res := BrushKernels.empty_result()
	if _tool_id == TOOL_SCULPT:
		var sculpt_settings := _sculpt_settings()
		_radius = float(sculpt_settings.radius)
		_color = RING_RAISE if float(sculpt_settings.direction) > 0.0 else RING_LOWER
		_sculpt = SculptStroke.new()
		_sculpt.begin(_ctx.document, _tx, sculpt_settings, t, pos, pf)
		res.error = _sculpt.error
		return res
	var paint_settings := _paint_settings()
	_radius = float(paint_settings.radius)
	_color = RING_DIRT if float(paint_settings.target_blend) >= 0.5 else RING_GRASS
	_paint = PaintStroke.new()
	return _paint.begin(_ctx.document, _tx, paint_settings, pos, pf)


func _resume_stroke(t: float, pos: Vector2, pf: float) -> Dictionary:
	if _paint != null:
		return _paint.resume(t, pos, pf)
	_sculpt.resume(t, pos, pf)
	var res := BrushKernels.empty_result()
	res.error = _sculpt.error
	return res


func _add_sample(t: float, pos: Vector2, pf: float) -> Dictionary:
	if _paint != null:
		return _paint.add_sample(t, pos, pf)
	_sculpt.add_sample(t, pos, pf)
	var res := BrushKernels.empty_result()
	res.error = _sculpt.error
	return res


func _pause_at(t: float) -> void:
	if not _started or _paused:
		return
	_paused = true
	if _paint != null:
		_paint.pause(t)
	else:
		_sculpt.pause(t)
	_ring.hide_ring()


func _take_result(res: Dictionary) -> void:
	if res.error != "":
		error = res.error
		return
	_ctx.mark_result(res)
	if _tool_id == TOOL_SCULPT and not (res.dirty_heights as Array).is_empty():
		_reground_followers(res.rect)


## TE-11: FOLLOW_TERRAIN objects under changed samples follow the ground inside this transaction.
func _reground_followers(rect: Rect2) -> void:
	var doc := _ctx.document
	for id in doc.sorted_object_ids():
		var rec := doc.get_object(id)
		if rec.grounding != WorldConstants.GROUNDING_FOLLOW \
				or not rect.has_point(Vector2(rec.position[0], rec.position[2])):
			continue
		var h := doc.sample_height(rec.position[0], rec.position[2])
		var new_y := h + rec.height_offset_m
		if not is_finite(new_y) or new_y == rec.position[1]:
			continue
		if not _tx.capture_object(id):
			error = BrushKernels.ERROR_BUDGET
			return
		var moved := rec.clone()
		moved.set_position(rec.position[0], new_y, rec.position[2])
		doc.put_object(moved)
		_ctx.presenter.sync_object(doc, id)


func _paint_settings() -> Dictionary:
	if _tool_id == TOOL_PATH:
		return PaintStroke.path_settings(float(_settings.get("width", 3.0)))
	return {"radius": float(_settings.get("radius", 4.0)), "strength": float(_settings.get("strength", 0.8)),
			"target_blend": 1.0 if str(_settings.get("material", "dirt")) == "dirt" else 0.0,
			"pressure_enabled": bool(_settings.get("pressure_enabled", true)),
			"falloff_kind": PaintStroke.FALLOFF_BRUSH}


func _sculpt_settings() -> Dictionary:
	return {"radius": float(_settings.get("radius", 6.0)),
			"direction": 1.0 if str(_settings.get("direction", "raise")) == "raise" else -1.0,
			"speed_m_per_s": float(_brush.get("sculpt_speed_m_per_s", 2.0)),
			"strength": float(_settings.get("strength", 0.8)),
			"pressure_enabled": bool(_settings.get("pressure_enabled", true)),
			"fixed_step_s": float(_brush.get("fixed_step_s", 1.0 / 60.0)),
			"stall_cancel_s": float(_brush.get("stall_cancel_s", 0.25)),
			"input_latency_s": float(_brush.get("input_latency_s", 0.05))}


func _label() -> String:
	match _tool_id:
		TOOL_SCULPT:
			return "Raise terrain" if str(_settings.get("direction", "raise")) == "raise" else "Lower terrain"
		TOOL_PATH:
			return "Path"
	return "Paint dirt" if str(_settings.get("material", "dirt")) == "dirt" else "Paint grass"


func _begin_timing() -> void:
	if _ctx.stats != null:
		_ctx.stats.begin_sample("brush")


func _end_timing() -> void:
	if _ctx.stats != null:
		_ctx.stats.end_sample("brush")
