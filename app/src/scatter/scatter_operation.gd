class_name ScatterOperation
extends RefCounted
## One Pencil contact of the Scatter or Erase brush (docs/editor-v2.md §6): dabs every 0.5 r along
## the stroke, one EditTransaction for the whole contact. Scatter adds instances through the
## ScatterPlacer; erase (tool "erase", or scatter inverted) removes scatter instances only and
## never touches manual objects. An invalid terrain hit pauses the stroke so no gap is bridged.
## A non-empty `error` means the controller must cancel; cancel() rolls the layer back.
##
## settings: radius, strength (flow), shape, alpha_mode, pressure_enabled, avoid, config
## (ToolCommands.scatter_config), erase (bool), optional seed (tests).

const TOOL_SCATTER := "scatter"
const TOOL_ERASE := "erase"
const COLOR_ACCENT := Color("f2bf33")
const COLOR_DANGER := Color("ff9a88")
const DAB_SPACING_FACTOR := 0.5
const DISC_TRIES_FACTOR := 0.05
const ERASE_FACTOR := 0.7
const WORLD_RECT := Rect2(-128.0, -128.0, 256.0, 256.0)

var error := ""

var _ctx: ToolContext
var _ring: BrushRing
var _tool_id: String
var _erase: bool
var _settings: Dictionary
var _brush: Dictionary
var _tx := EditTransaction.new()
var _probe := StrokeProbe.new()
var _placer: ScatterPlacer
var _id := ObjectRecord.new_uuid_v4()
var _radius := 7.0
var _flow := 0.7
var _density := 1.0
var _shape := "soft"
var _alpha_mode := "circle"
var _pressure_enabled := true
var _started := false
var _paused := false
var _done := false
var _captured := false
var _limit_reported := false
var _last := Vector2.ZERO
var _last_pf := 1.0
var _since := 0.0
var _angle := 0.0
var _removed := 0
var _dab_count := 0


func _init(ctx: ToolContext, ring: BrushRing, tool_id: String, settings: Dictionary) -> void:
	_ctx = ctx
	_ring = ring
	_tool_id = tool_id
	_settings = settings
	_erase = tool_id == TOOL_ERASE or bool(settings.get("erase", false))
	_brush = ctx.defaults.get("brush", {})
	_radius = float(settings.get("radius", 7.0))
	_flow = float(settings.get("strength", 0.7))
	_shape = str(settings.get("shape", "soft"))
	_alpha_mode = str(settings.get("alpha_mode", "circle"))
	_pressure_enabled = bool(settings.get("pressure_enabled", true))
	_density = float((settings.get("config", {}) as Dictionary).get("density", 1.0))


func operation_id() -> String:
	return _tx.operation_id if _tx.operation_id != "" else _id


func stroke_state() -> String:
	return "Erasing" if _erase else "Scattering"


func dab_count() -> int:
	return _dab_count


func begin(sample: PointerSample, hit: TerrainHit) -> void:
	var config: Dictionary = {} if _erase else _settings.get("config", {})
	_tx.begin(_ctx.document, _tool_id, _label(), {"tool": _tool_id, "erase": _erase})
	var seed_value := int(_settings.get("seed", operation_id().hash()))
	_placer = ScatterPlacer.new(_ctx.document, _ctx.catalog, config,
			bool(_settings.get("avoid", true)) and not _erase, seed_value)
	_probe.begin(_tool_id, sample.timestamp_s)
	if hit.ok:
		_apply_sample(sample, hit, false)


func move(sample: PointerSample, hit: TerrainHit) -> void:
	if error != "":
		return
	if hit.ok:
		_apply_sample(sample, hit, false)
	else:
		pause(sample)


func resume(sample: PointerSample, hit: TerrainHit) -> void:
	if error == "" and hit.ok:
		_apply_sample(sample, hit, true)


func pause(_sample: PointerSample) -> void:
	_paused = true
	_ring.hide_ring()


func advance(_now: float) -> void:
	pass


## Returns the committed change, or null when nothing changed or `error` was set.
func end(sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if error == "" and not over_ui and hit.ok:
		_apply_sample(sample, hit, false)
	if error != "":
		_record("cancelled")
		return null
	_ring.hide_ring()
	_done = true
	_tx.label = _label(_removed if _erase else _placer.added)
	var change := _tx.finish()
	_record("committed" if change != null else "no_change", change)
	return change


func cancel() -> void:
	if _done:
		return
	_done = true
	_record("cancelled")
	_ctx.mark_touched(_tx.rollback())
	_ring.hide_ring()


func _record(result: String, change: WorldChange = null) -> void:
	_ctx.last_stroke = _probe.finish(result, change, 0, error)


func _label(count: int = 0) -> String:
	if _erase:
		return "Erase scatter (%d)" % count
	return "Scatter %s (%d)" % [str((_settings.get("config", {}) as Dictionary).get("name", "")), count]


func _apply_sample(sample: PointerSample, hit: TerrainHit, force_resume: bool) -> void:
	var pos := Vector2(hit.position.x, hit.position.z)
	var pf := BrushMath.pressure_factor(sample.pressure_valid, sample.pressure, _pressure_enabled,
			float(_brush.get("pressure_min_factor", 0.2)), float(_brush.get("pressure_gamma", 1.0)))
	_probe.add_sample(sample.pressure_valid, sample.pressure, pf, sample.timestamp_s)
	if not _started or _paused or force_resume:
		_started = true
		_paused = false
		_dab(pos, pf)
		_since = 0.0
	else:
		_walk(pos, pf)
	_last = pos
	_last_pf = pf
	if error == "":
		_ring.show_at(_ctx.document, hit.position, _radius, COLOR_DANGER if _erase else COLOR_ACCENT)


## Dabs along the segment _last -> pos, one every DAB_SPACING_FACTOR * radius of stroke length.
func _walk(pos: Vector2, pf: float) -> void:
	var seg := pos - _last
	var length := seg.length()
	if length < 1e-6:
		return
	if length > 1e-3:
		_angle = atan2(seg.y, seg.x)
	var spacing := _radius * DAB_SPACING_FACTOR
	var d := spacing - _since
	while d <= length and error == "":
		var t := d / length
		_dab(_last + seg * t, lerpf(_last_pf, pf, t))
		d += spacing
	_since = length - (d - spacing)


func _dab(pos: Vector2, pf: float) -> void:
	_dab_count += 1
	var changed := _erase_dab(pos) if _erase else _scatter_dab(pos, pf)
	if changed:
		_ctx.notify_scatter(Rect2(pos - Vector2(_radius, _radius), Vector2(_radius, _radius) * 2.0))
	if _placer.limit_reached and not _limit_reported:
		_limit_reported = true
		_ctx.report(ScatterPlacer.LIMIT_MESSAGE)


func _scatter_dab(pos: Vector2, pf: float) -> bool:
	if not _ensure_captured():
		return false
	var before := _placer.added
	var tries := ScatterOperation.dab_tries(_density, _radius, _flow, pf)
	var rng := _placer.rng()
	for _i in tries:
		if _placer.limit_reached:
			break
		var a := rng.randf() * TAU
		var r := _radius * sqrt(rng.randf())
		var x := pos.x + cos(a) * r
		var z := pos.y + sin(a) * r
		var w := BrushAlpha.weight(_shape, _alpha_mode, x, z, pos, _radius, _angle)
		if rng.randf() < w:
			_placer.try_add(x, z)
	return _placer.added != before


func _erase_dab(pos: Vector2) -> bool:
	var layer := _ctx.document.scatter
	var index := _placer.index()
	var rng := _placer.rng()
	var drop := PackedInt32Array()
	for i in index.indices_in_disc(pos.x, pos.y, _radius):
		var w := BrushAlpha.weight(_shape, _alpha_mode, layer.x[i], layer.z[i], pos, _radius, _angle)
		if rng.randf() < erase_probability(w, _flow):
			drop.append(i)
	if drop.is_empty() or not _ensure_captured():
		return false
	index.remove_indices(drop)
	_removed += drop.size()
	return true


func _ensure_captured() -> bool:
	if _captured:
		return true
	_captured = _tx.capture_scatter()
	if not _captured:
		error = BrushKernels.ERROR_BUDGET
	return _captured


## Spec §6: max(1, round(density * pi r^2 * 0.05 * flow * pf)).
static func dab_tries(density: float, radius: float, flow: float, pf: float) -> int:
	return maxi(1, roundi(density * PI * radius * radius * DISC_TRIES_FACTOR * flow * pf))


static func erase_probability(alpha: float, flow: float) -> float:
	return clampf(alpha * flow * ERASE_FACTOR, 0.0, 1.0)
