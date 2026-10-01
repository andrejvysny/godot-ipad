class_name BenchWorkloads
extends RefCounted
## Render-side edit workloads of the render bench (spec §20.3). They edit only the bench document (never the
## user's document or history) and present through the production render paths: the existing sculpt stroke
## and re-grounding kernels with terrain.mark_dirty, presenter.sync_object for object edits, and the Texture
## Preview controller. frame() runs once per frame with the time since the window started.

const SCULPT_RADIUS_M := 6.0
const SCULPT_SPEED_M_PER_S := 0.5
const SCULPT_STROKE_S := 2.0
const SCULPT_SWEEP_M := 30.0
const SCULPT_MOVE_M_PER_S := 5.0
const MOVE_SWEEP_M := 70.0
const MOVE_M_PER_S := 10.0
const PREVIEW_CYCLES := 20
const PREVIEW_LOAD_CAP_FRAMES := 600
const PREVIEW_HOLD_FRAMES := 30
const PREVIEW_RELEASE_CAP_FRAMES := 600
const CACHE_KEYS: Array[String] = ["resident_bytes", "reserved_bytes", "preview_bytes", "entries", "queued", "loading",
	"errors", "evictions", "rejected"]

var kind := ""
var preview_cycles := PREVIEW_CYCLES

var _session: EditorSession
var _doc: WorldDocument
var _focus := Vector2.ZERO
var _ctx: ToolContext
var _stroke: SculptStroke
var _tx: EditTransaction
var _stroke_start := 0.0
var _direction := 1.0
var _strokes := 0
var _stroke_errors := 0
var _seam_x := 0.0
var _move_id := ""
var _move_base: ObjectRecord
var _moves := 0
var _cycle := 0
var _phase := "enable"
var _phase_frames := 0
var _cycles: Array[Dictionary] = []
var _skipped_restricted := false
var _done := false


func _init(session: EditorSession, doc: WorldDocument, focus: Vector2) -> void:
	_session = session
	_doc = doc
	_focus = focus


## "" or why the workload cannot run on this world.
func begin(workload: String) -> String:
	kind = workload
	match workload:
		"edit_sculpt":
			_ctx = ToolContext.new()
			_ctx.document = _doc
			_ctx.terrain = _session.terrain
			_ctx.presenter = _session.presenter
			_ctx.scatter_changed = _session.layers.scatter_changed
			var span := float(WorldConstants.REGION_SAMPLES) * WorldConstants.SAMPLE_SPACING
			_seam_x = roundf(_focus.x / span) * span  # the region seam nearest to the focus area
			_start_stroke(0.0)
		"edit_move":
			return _begin_move()
		"preview_cycles":
			_session.render_state().texture_preview.bind(_session.terrain, _doc)
	return ""


func is_done() -> bool:
	return _done


## True for workloads that run for the whole window; false when they end by themselves.
func is_timed() -> bool:
	return kind != "preview_cycles"


func frame(t: float) -> void:
	match kind:
		"edit_sculpt":
			_sculpt_frame(t)
		"edit_move":
			_move_frame(t)
		"preview_cycles":
			_preview_frame()


## An aborted run: drops the in-flight stroke and the selection (the bench document is discarded anyway).
func abandon() -> void:
	_stroke = null
	_session.presenter.set_selected("")


## Report fields of the workload; also leaves the session state the workload touched (selection, preview).
func finish(t: float) -> Dictionary:
	var out := {"workload": kind}
	match kind:
		"edit_sculpt":
			_finish_stroke(t)
			out.merge({"strokes": _strokes, "stroke_errors": _stroke_errors, "seam_x_m": _seam_x,
				"terrain_latency": _session.terrain.presentation_latency()})
		"edit_move":
			_session.presenter.set_selected("")
			out.merge({"object_id": _move_id, "moves": _moves, "sweep_m": MOVE_SWEEP_M,
				"terrain_latency": _session.terrain.presentation_latency()})
		"preview_cycles":
			_session.render_state().disable_texture_preview("bench_end")
			out.merge({"cycles_requested": preview_cycles, "cycles_done": _cycle, "cycles": _cycles,
				"skipped_restricted": _skipped_restricted, "completed": _done})
	return out


# --- edit_sculpt ---------------------------------------------------------------------------

func _sculpt_pos(t: float) -> Vector2:
	var period := 2.0 * SCULPT_SWEEP_M / SCULPT_MOVE_M_PER_S
	var phase := fposmod(t, period) / period
	var tri := 1.0 - absf(2.0 * phase - 1.0)  # 0 -> 1 -> 0
	return Vector2(_seam_x - SCULPT_SWEEP_M * 0.5 + tri * SCULPT_SWEEP_M, _focus.y)


func _start_stroke(t: float) -> void:
	var settings := {"radius": SCULPT_RADIUS_M, "kind": "raise", "direction": _direction,
		"speed_m_per_s": SCULPT_SPEED_M_PER_S, "strength": 1.0, "pressure_enabled": false,
		"fixed_step_s": 1.0 / 60.0, "stall_cancel_s": 0.25, "input_latency_s": 0.05, "shape": "soft",
		"alpha_mode": "circle"}
	_tx = EditTransaction.new()
	_tx.begin(_doc, "sculpt", "Bench sculpt", settings)
	_stroke = SculptStroke.new()
	_stroke.begin(_doc, _tx, settings, t, _sculpt_pos(t), 1.0)
	_stroke_start = t
	_strokes += 1


func _sculpt_frame(t: float) -> void:
	_stroke.add_sample(t, _sculpt_pos(t), 1.0)
	var res := _stroke.advance_to(t)
	if res.error == "":
		_present_sculpt(res)
	else:
		_stroke_errors += 1
		_ctx.mark_touched(_stroke.cancel())
		_start_stroke(t)
		return
	if t - _stroke_start >= SCULPT_STROKE_S:
		_finish_stroke(t)
		_direction = -_direction
		_start_stroke(t)


func _finish_stroke(t: float) -> void:
	if _stroke == null:
		return
	var res := _stroke.finish(t)
	if res.error == "":
		_present_sculpt(res)
	_stroke = null


func _present_sculpt(res: Dictionary) -> void:
	_ctx.mark_result(res)
	if not (res.dirty_heights as Array).is_empty():
		Regrounder.followers(_ctx, _tx, res.rect)


# --- edit_move -----------------------------------------------------------------------------

func _begin_move() -> String:
	var best := ""
	var best_d := INF
	for id in _doc.sorted_object_ids():
		var rec := _doc.get_object(id)
		var d := Vector2(rec.position[0], rec.position[2]).distance_to(_focus)
		if d < best_d:
			best_d = d
			best = id
	if best == "":
		return "edit_move needs at least one object."
	_move_id = best
	_move_base = _doc.get_object(best).clone()
	_session.presenter.set_selected(best)
	return ""


func _move_frame(t: float) -> void:
	var period := 2.0 * MOVE_SWEEP_M / MOVE_M_PER_S
	var phase := fposmod(t, period) / period
	var x := _move_base.position[0] - MOVE_SWEEP_M * 0.5 + (1.0 - absf(2.0 * phase - 1.0)) * MOVE_SWEEP_M
	var z := _move_base.position[2]
	var rec := _move_base.clone()
	var y := _doc.sample_height(x, z)
	rec.set_position(x, _move_base.position[1] if is_nan(y) else y + rec.height_offset_m, z)
	_doc.put_object(rec)
	_session.presenter.sync_object(_doc, _move_id)
	_moves += 1


# --- preview_cycles ------------------------------------------------------------------------

func _cache_snapshot() -> Dictionary:
	var stats := _session.render_cache().stats()
	var out := {}
	for key in CACHE_KEYS:
		out[key] = int(stats.get(key, 0))
	return out


func _preview_frame() -> void:
	var render := _session.render_state()
	var preview := render.texture_preview
	_phase_frames += 1
	match _phase:
		"enable":
			if _cycle >= preview_cycles:
				_done = true
				return
			if render.safety.is_restricted():
				_skipped_restricted = true
				_done = true
				return
			var h := _doc.sample_height(_focus.x, _focus.y)
			var center := Vector3(_focus.x, 0.0 if is_nan(h) else h, _focus.y)
			_cycles.append({"cycle": _cycle, "before": _cache_snapshot()})
			var result := preview.enable_at(center)
			_phase = "loading"
			_phase_frames = 0
			if not bool(result.ok) and preview.state() != TexturePreviewController.ERROR:
				_cycles[_cycle]["state_reached"] = preview.state()
				_cycles[_cycle]["refused"] = str(result.message)
				_phase = "hold"
				_phase_frames = PREVIEW_HOLD_FRAMES
		"loading":
			var state := preview.state()
			if state in [TexturePreviewController.ACTIVE, TexturePreviewController.LIMITED,
					TexturePreviewController.ERROR] or _phase_frames >= PREVIEW_LOAD_CAP_FRAMES:
				_cycles[_cycle]["state_reached"] = state
				_cycles[_cycle]["load_frames"] = _phase_frames
				_cycles[_cycle]["during"] = _cache_snapshot()
				_phase = "hold"
				_phase_frames = 0
		"hold":
			if _phase_frames >= PREVIEW_HOLD_FRAMES:
				render.disable_texture_preview("bench_cycle")
				_phase = "release"
				_phase_frames = 0
		"release":
			if preview.state() == TexturePreviewController.OFF or _phase_frames >= PREVIEW_RELEASE_CAP_FRAMES:
				_cycles[_cycle]["released"] = preview.state() == TexturePreviewController.OFF
				_cycles[_cycle]["after"] = _cache_snapshot()
				_cycle += 1
				_phase = "enable"
				_phase_frames = 0
