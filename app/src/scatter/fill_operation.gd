class_name FillOperation
extends RefCounted
## Fill / Clear lasso (docs/editor-v2.md §6). While the Pencil is down the terrain hits form a
## polygon in XZ (points at least 0.25 m apart, closed implicitly); nothing in the document
## changes until lift. On lift with at least 3 points: fill scatters the source inside the loop,
## inverted (clear) removes the scatter instances inside it. One EditTransaction, none for an
## empty result. settings: erase (bool: clear), avoid, config, optional seed (tests).

const MIN_POINT_GAP_M := 0.25
const MIN_POINTS := 3
const MAX_TRIES := 6000
const AREA_TRIES_FACTOR := 0.6
const TOOL_ID := "fill"

var error := ""

var _ctx: ToolContext
var _lasso: LassoPreview
var _settings: Dictionary
var _clear: bool
var _points := PackedVector2Array()
var _tx := EditTransaction.new()
var _id := ObjectRecord.new_uuid_v4()
var _done := false


func _init(ctx: ToolContext, lasso: LassoPreview, settings: Dictionary) -> void:
	_ctx = ctx
	_lasso = lasso
	_settings = settings
	_clear = bool(settings.get("erase", false))


func operation_id() -> String:
	return _tx.operation_id if _tx.operation_id != "" else _id


func stroke_state() -> String:
	return "Filling"


func points() -> PackedVector2Array:
	return _points.duplicate()


func begin(_sample: PointerSample, hit: TerrainHit) -> void:
	_add_point(hit)


func move(_sample: PointerSample, hit: TerrainHit) -> void:
	_add_point(hit)


func resume(_sample: PointerSample, hit: TerrainHit) -> void:
	_add_point(hit)


## A paused contact (invalid hit) adds no point; the loop simply continues from the next one.
func pause(_sample: PointerSample) -> void:
	pass


func advance(_now: float) -> void:
	pass


func end(_sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if not over_ui:
		_add_point(hit)
	_done = true
	_lasso.hide_loop()
	if _points.size() < MIN_POINTS:
		return null
	_tx.begin(_ctx.document, TOOL_ID, "Fill", {"tool": TOOL_ID, "erase": _clear})
	var count := _clear_inside() if _clear else _fill_inside()
	if error != "":
		_ctx.mark_touched(_tx.rollback())
		return null
	_tx.label = "Clear area (%d)" % count if _clear else \
			"Fill %s (%d)" % [str((_settings.get("config", {}) as Dictionary).get("name", "")), count]
	var change := _tx.finish()
	if change != null:
		_ctx.notify_scatter(_bounds())
	return change


func cancel() -> void:
	if _done:
		return
	_done = true
	_lasso.hide_loop()


func _add_point(hit: TerrainHit) -> void:
	if not hit.ok:
		return
	var p := Vector2(hit.position.x, hit.position.z)
	if not _points.is_empty() and _points[_points.size() - 1].distance_to(p) < MIN_POINT_GAP_M:
		return
	_points.append(p)
	_lasso.show_loop(_ctx.document, _points, ScatterOperation.COLOR_DANGER if _clear else ScatterOperation.COLOR_ACCENT)


func _bounds() -> Rect2:
	var rect := Rect2(_points[0], Vector2.ZERO)
	for p in _points:
		rect = rect.expand(p)
	return rect


## Number of instances added.
func _fill_inside() -> int:
	var config: Dictionary = _settings.get("config", {})
	var seed_value := int(_settings.get("seed", _id.hash()))
	var placer := ScatterPlacer.new(_ctx.document, _ctx.catalog, config, bool(_settings.get("avoid", true)), seed_value)
	if not placer.has_source() or not _tx.capture_scatter():
		error = BrushKernels.ERROR_BUDGET if placer.has_source() else error
		return 0
	var box := _bounds()
	var rng := placer.rng()
	var tries := fill_tries(float(config.get("density", 1.0)), box.get_area())
	for _i in tries:
		var x := box.position.x + rng.randf() * box.size.x
		var z := box.position.y + rng.randf() * box.size.y
		if Geometry2D.is_point_in_polygon(Vector2(x, z), _points):
			placer.try_add(x, z)
		if placer.limit_reached:
			break
	if placer.limit_reached:
		_ctx.report(placer.limit_message())
	return placer.added


## Number of instances removed.
func _clear_inside() -> int:
	var layer := _ctx.document.scatter
	var box := _bounds()
	var drop := PackedInt32Array()
	for i in layer.count():
		var p := Vector2(layer.x[i], layer.z[i])
		if box.has_point(p) and Geometry2D.is_point_in_polygon(p, _points):
			drop.append(i)
	if drop.is_empty():
		return 0
	if not _tx.capture_scatter():
		error = BrushKernels.ERROR_BUDGET
		return 0
	layer.remove_indices(drop)
	return drop.size()


## Spec §6: min(6000, round(density * bbox_area * 0.6)).
static func fill_tries(density: float, bbox_area: float) -> int:
	return mini(MAX_TRIES, roundi(density * bbox_area * AREA_TRIES_FACTOR))
