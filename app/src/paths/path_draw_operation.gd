class_name PathDrawOperation
extends RefCounted
## One Pencil contact of the Path tool that does not start on a handle (docs/editor-v2.md §7).
## Terrain hits >= 0.25 m apart form the raw stroke, shown as a live draped ribbon. On lift:
## a tap (the contact never left the tap radius) selects the nearest path or clears the path
## selection; a stroke under 2 points or 1 m does nothing; otherwise it becomes a spline path
## (control points every 4 m) and the terrain is flattened along the raw stroke, with followers
## regrounded, in one transaction "Draw path". Nothing in the document changes before lift.
## A non-empty `error` means the controller must cancel; end() has then already rolled back.

const TOOL_ID := "path"
const MIN_POINT_GAP_M := 0.25
const MIN_LENGTH_M := 1.0
const CONTROL_SPACING_M := 4.0
const DAB_STRENGTH := 0.9
const SELECT_MARGIN_M := 0.5

var error := ""

var _ctx: ToolContext
var _preview: PathPreview
var _width: float
var _raw := PackedVector2Array()
var _tx := EditTransaction.new()
var _id := ObjectRecord.new_uuid_v4()
var _start_vp := Vector2.ZERO
var _threshold := 0.0
var _max_move := 0.0
var _tap: Variant = null
var _created := ""
var _done := false


func _init(ctx: ToolContext, preview: PathPreview, width: float) -> void:
	_ctx = ctx
	_preview = preview
	_width = width
	_threshold = float(ctx.default("input", "tap_move_threshold_pt", 8.0)) * float(ctx.units_per_point.call())


func operation_id() -> String:
	return _tx.operation_id if _tx.operation_id != "" else _id


func stroke_state() -> String:
	return "Drawing path"


## Id of the path created by end(), "" otherwise.
func created_id() -> String:
	return _created


## String id ("" clears) when the contact was a tap that changes the path selection, else null.
func tap_selection() -> Variant:
	return _tap


func raw_points() -> PackedVector2Array:
	return _raw.duplicate()


func begin(sample: PointerSample, hit: TerrainHit) -> void:
	_start_vp = sample.position_viewport
	_add_point(hit)


func move(sample: PointerSample, hit: TerrainHit) -> void:
	_max_move = maxf(_max_move, sample.position_viewport.distance_to(_start_vp))
	_add_point(hit)


func resume(sample: PointerSample, hit: TerrainHit) -> void:
	move(sample, hit)


## An invalid hit adds no point; the stroke continues from the next valid one.
func pause(_sample: PointerSample) -> void:
	pass


func advance(_now: float) -> void:
	pass


func end(sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if not over_ui:
		_max_move = maxf(_max_move, sample.position_viewport.distance_to(_start_vp))
		_add_point(hit)
	_done = true
	_preview.hide_stroke()
	if not over_ui:
		if _max_move <= _threshold:
			_tap = _nearest_path(hit) if hit.ok else null
			return null
	if _raw.size() < 2 or PathSpline.length(_raw) < MIN_LENGTH_M:
		return null
	return _commit()


func cancel() -> void:
	_done = true
	_preview.hide_stroke()


func _add_point(hit: TerrainHit) -> void:
	if not hit.ok:
		return
	var p := Vector2(hit.position.x, hit.position.z)
	if not _raw.is_empty() and _raw[_raw.size() - 1].distance_to(p) < MIN_POINT_GAP_M:
		return
	_raw.append(p)
	_preview.show_stroke(_ctx.document, _raw, _width)


## Path whose curve is nearest to the hit, within its half width + SELECT_MARGIN_M; "" when none.
func _nearest_path(hit: TerrainHit) -> String:
	var p := Vector2(hit.position.x, hit.position.z)
	var best := ""
	var best_over := 0.0
	for id in _ctx.document.sorted_path_ids():
		var rec := _ctx.document.get_path_record(id)
		var over := float(PathSpline.closest(rec.points, p).distance) - (rec.width_m * 0.5 + SELECT_MARGIN_M)
		if over <= 0.0 and (best == "" or over < best_over):
			best = id
			best_over = over
	return best


func _commit() -> WorldChange:
	var doc := _ctx.document
	if doc.paths.size() >= WorldConstants.MAX_PATHS:
		_ctx.report("Path limit reached (%d)." % WorldConstants.MAX_PATHS)
		return null
	var rec := PathRecord.new()
	rec.path_id = ObjectRecord.new_uuid_v4()
	rec.width_m = _width
	var spacing := maxf(CONTROL_SPACING_M, PathSpline.length(_raw) / float(WorldConstants.PATH_POINTS_MAX - 1))
	rec.points = PathSpline.resample_stroke(_raw, spacing)
	_tx.begin(doc, TOOL_ID, "Draw path", {"tool": TOOL_ID, "width": _width})
	var rect := _flatten()
	if error == "" and rect.has_area():
		error = Regrounder.followers(_ctx, _tx, rect.grow(WorldConstants.SAMPLE_SPACING))
	if error == "" and not _tx.capture_path(rec.path_id):
		error = BrushKernels.ERROR_BUDGET
	if error != "":
		_ctx.mark_touched(_tx.rollback())
		return null
	doc.put_path(rec)
	_ctx.notify_path([rec.path_id])
	_created = rec.path_id
	return _tx.finish()


## Soft-circle flatten dab at every second raw point toward the surface height there when the dab
## is applied. Returns the union of the changed sample extents.
func _flatten() -> Rect2:
	var radius := 0.75 * _width + 0.5
	var union := Rect2()
	var have := false
	for i in range(0, _raw.size(), 2):
		var target := _ctx.document.sample_height(_raw[i].x, _raw[i].y)
		if is_nan(target):
			continue
		var piece := SculptKernels.Piece.new("flatten", _raw[i], _raw[i], radius, "soft", "circle", 0.0, _ctx.document.layout)
		piece.gain = DAB_STRENGTH
		piece.target = target
		var res := SculptKernels.sculpt_piece(_ctx.document, _tx, piece, {})
		if res.error != "":
			error = res.error
			break
		_ctx.mark_result(res)
		var rect: Rect2 = res.rect
		if rect.has_area():
			union = rect if not have else union.merge(rect)
			have = true
	return union
