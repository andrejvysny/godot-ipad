class_name SculptStroke
extends RefCounted
## Time-integrated raise/lower stroke (spec §13.1). Work is processed in fixed steps at
## t0 + k * fixed_step_s, independent of frame times; each step's valid sub-intervals from the
## timeline are applied with dt = their duration, so a stationary pencil keeps sculpting and a
## moving one spreads each step's time along its path. Paused gaps receive no work.
## The caller owns the EditTransaction: it finishes it on success, or cancels the stroke (which
## rolls it back) on any result error ("stall", "budget", "invalid_input").
##
## Input latency: samples reach the stroke some time after their timestamps. A step is processed
## only once the timeline is known up to its end, or once `now` is input_latency_s past it (a
## stationary pencil that sends no events). While delivery lags less than input_latency_s, results
## equal those of the complete recorded timeline, whatever the frame cadence, and a late pause
## (invalid hit) is never sculpted with the held position.
##
## Settings: radius, kind (raise | flatten | noise | smooth; default raise), direction (+1 raise /
## -1 lower), speed_m_per_s, strength, shape, alpha_mode (docs/editor-v2.md §3), target (flatten),
## pressure_enabled, fixed_step_s, stall_cancel_s, input_latency_s.

const ERROR_STALL := "stall"
const ERROR_INVALID := BrushKernels.ERROR_INVALID
const DEFAULT_INPUT_LATENCY_S := 0.05
## Lower bound on fixed_step_s; also bounds the steps processed per call to ~(stall + latency) / step.
const MIN_FIXED_STEP_S := 0.001

var settings: Dictionary = {}
var timeline := StrokeTimeline.new()
var error: String = ""
var steps_processed: int = 0

var _doc: WorldDocument
var _tx: EditTransaction
var _t0 := 0.0
var _step := 1.0 / 60.0
var _stall := 0.25
var _latency := DEFAULT_INPUT_LATENCY_S
var _last_processed := 0.0
var _height_rate := 0.0
var _angle := 0.0  # stamp direction of the latest segment
var _finished := false


## Invalid timing (non-finite t0, fixed_step_s below MIN_FIXED_STEP_S, negative or non-finite
## stall/latency) sets `error` to "invalid_input"; every later call then returns that error.
func begin(doc: WorldDocument, tx: EditTransaction, p_settings: Dictionary, t0: float, pos: Vector2, pf: float) -> void:
	_doc = doc
	_tx = tx
	settings = p_settings.duplicate(true)
	_step = float(settings.get("fixed_step_s", 1.0 / 60.0))
	_stall = float(settings.get("stall_cancel_s", 0.25))
	_latency = float(settings.get("input_latency_s", DEFAULT_INPUT_LATENCY_S))
	_height_rate = signf(float(settings.get("direction", 1.0))) * float(settings.get("speed_m_per_s", 2.0))
	_t0 = t0
	_last_processed = t0
	var timing_ok := is_finite(t0) and is_finite(_step) and _step >= MIN_FIXED_STEP_S \
			and is_finite(_stall) and _stall >= 0.0 and is_finite(_latency) and _latency >= 0.0
	if not timing_ok:
		error = ERROR_INVALID
		return
	timeline.add_sample(t0, pos, _pf(pf))


func add_sample(t: float, pos: Vector2, pf: float) -> void:
	timeline.add_sample(t, pos, _pf(pf))


func pause(t: float) -> void:
	timeline.pause(t)


func resume(t: float, pos: Vector2, pf: float) -> void:
	timeline.resume(t, pos, _pf(pf))


## Processes every whole step ending at or before the input horizon
## min(now, max(timeline.known_until(), now - input_latency_s)). A main-loop gap longer than
## stall_cancel_s + fixed_step_s (+ input_latency_s) returns error "stall" without applying the backlog.
func advance_to(now: float) -> Dictionary:
	var res := BrushKernels.empty_result()
	if not _check(now, res):
		return res
	_process_steps(minf(now, maxf(timeline.known_until(), now - _latency)), res)
	return res


## Processes the remaining whole steps and the final partial interval up to exactly `t_end`.
## Time already processed past `t_end` (end event older than the last frame) is not revisited.
func finish(t_end: float) -> Dictionary:
	var res := BrushKernels.empty_result()
	if not _check(t_end, res):
		return res
	timeline.pause(t_end)
	_process_steps(t_end, res)
	if res.error == "" and t_end > _last_processed:
		_process_interval(_last_processed, t_end, res)
		_last_processed = t_end
	_finished = true
	return res


## Rolls back every captured value; returns the touched sets from EditTransaction.rollback().
func cancel() -> Dictionary:
	_finished = true
	return _tx.rollback()


func _check(now: float, res: Dictionary) -> bool:
	if _finished:
		res.error = "finished"
		return false
	if error == "" and not is_finite(now):
		error = ERROR_INVALID
	# Processing trails `now` by up to input_latency_s by design; only the excess is a stall.
	if error == "" and now - _last_processed > _stall + _step + _latency:
		error = ERROR_STALL
	res.error = error
	return error == ""


func _process_steps(now: float, res: Dictionary) -> void:
	while true:
		var t_end := _t0 + float(steps_processed + 1) * _step
		if t_end > now:
			return
		_process_interval(_last_processed, t_end, res)
		if res.error != "":
			error = res.error
			return
		steps_processed += 1
		_last_processed = t_end


func _process_interval(t_a: float, t_b: float, res: Dictionary) -> void:
	var snaps := {}  # smooth reads the heights from before this step
	for piece in timeline.segments_between(t_a, t_b):
		var r := _apply_piece(piece, snaps)
		BrushKernels.merge_result(res, r)
		if res.error != "":
			error = res.error
			return


func _apply_piece(piece: Dictionary, snaps: Dictionary) -> Dictionary:
	var radius := float(settings.get("radius", 6.0))
	var strength := float(settings.get("strength", 1.0))
	var shape := str(settings.get("shape", "soft"))
	var mode := str(settings.get("alpha_mode", "circle"))
	var dt: float = piece.t_b - piece.t_a
	var pf_avg: float = 0.5 * (float(piece.pf_a) + float(piece.pf_b))
	var kind := str(settings.get("kind", "raise"))
	if kind == "raise" and BrushAlpha.is_exact_soft(shape, mode):
		return BrushKernels.sculpt_segment(_doc, _tx, piece.p_a, piece.p_b, radius, _height_rate,
				strength, pf_avg, dt)
	_angle = BrushDabs.segment_angle(piece.p_a, piece.p_b, _angle)
	var p := SculptKernels.Piece.new(kind, piece.p_a, piece.p_b, radius, shape, mode, _angle, _doc.layout)
	p.gain = (_height_rate if kind == "raise" else 1.0) * strength * pf_avg * dt
	p.target = float(settings.get("target", 0.0))
	return SculptKernels.sculpt_piece(_doc, _tx, p, snaps)


## Disabled or non-finite pressure is full strength (as BrushMath.pressure_factor), never NaN.
func _pf(pf: float) -> float:
	return pf if bool(settings.get("pressure_enabled", true)) and is_finite(pf) else 1.0
