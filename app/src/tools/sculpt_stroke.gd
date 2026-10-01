class_name SculptStroke
extends RefCounted
## Time-integrated raise/lower stroke (spec §13.1). Work is processed in fixed steps at
## t0 + k * fixed_step_s, independent of frame times; each step's valid sub-intervals from the
## timeline are applied with dt = their duration, so a stationary pencil keeps sculpting and a
## moving one spreads each step's time along its path. Paused gaps receive no work.
## The caller owns the EditTransaction: it finishes it on success, or cancels the stroke (which
## rolls it back) on any result error ("budget", "invalid_input").
##
## Backlog (ADR 0012): slow frames never cancel the stroke. A backlog of at most MAX_EXACT_STEPS
## steps is processed step by step (exact). A larger backlog is applied as MERGED_INTERVALS
## grid-aligned intervals whose contiguous timeline pieces are coalesced into segments of at most
## COALESCE_RADIUS_FRACTION * radius, so the work per call stays bounded however far behind the
## stroke is. The total sculpted time is unchanged; only the sub-step distribution is coarser.
##
## Input latency: samples reach the stroke some time after their timestamps. A step is processed
## only once the timeline is known up to its end, or once `now` is input_latency_s past it (a
## stationary pencil that sends no events). While delivery lags less than input_latency_s, results
## equal those of the complete recorded timeline, whatever the frame cadence, and a late pause
## (invalid hit) is never sculpted with the held position.
##
## Settings: radius, kind (raise | flatten | noise | smooth; default raise), direction (+1 raise /
## -1 lower), speed_m_per_s, strength, shape, alpha_mode (docs/editor-v2.md §3), target (flatten),
## pressure_enabled, fixed_step_s, input_latency_s.

const ERROR_INVALID := BrushKernels.ERROR_INVALID
const DEFAULT_INPUT_LATENCY_S := 0.05
const MIN_FIXED_STEP_S := 0.001
const MAX_EXACT_STEPS := 4
const MERGED_INTERVALS := 2
const COALESCE_RADIUS_FRACTION := 0.5

var settings: Dictionary = {}
var timeline := StrokeTimeline.new()
var error: String = ""
var steps_processed: int = 0
var pieces_applied: int = 0  ## kernel calls, for bounded-work checks and diagnostics

var _doc: WorldDocument
var _tx: EditTransaction
var _t0 := 0.0
var _step := 1.0 / 60.0
var _latency := DEFAULT_INPUT_LATENCY_S
var _last_processed := 0.0
var _height_rate := 0.0
var _angle := 0.0  # stamp direction of the latest segment
var _finished := false


## Invalid timing (non-finite t0, fixed_step_s below MIN_FIXED_STEP_S, negative or non-finite
## latency) sets `error` to "invalid_input"; every later call then returns that error.
func begin(doc: WorldDocument, tx: EditTransaction, p_settings: Dictionary, t0: float, pos: Vector2, pf: float) -> void:
	_doc = doc
	_tx = tx
	settings = p_settings.duplicate(true)
	_step = float(settings.get("fixed_step_s", 1.0 / 60.0))
	_latency = float(settings.get("input_latency_s", DEFAULT_INPUT_LATENCY_S))
	_height_rate = signf(float(settings.get("direction", 1.0))) * float(settings.get("speed_m_per_s", 2.0))
	_t0 = t0
	_last_processed = t0
	var timing_ok := is_finite(t0) and is_finite(_step) and _step >= MIN_FIXED_STEP_S \
			and is_finite(_latency) and _latency >= 0.0
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
## min(now, max(timeline.known_until(), now - input_latency_s)).
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
	res.error = error
	return error == ""


func _process_steps(now: float, res: Dictionary) -> void:
	var pending := 0
	while _t0 + float(steps_processed + pending + 1) * _step <= now:
		pending += 1
	if pending == 0:
		return
	var merged := pending > MAX_EXACT_STEPS
	var chunks := MERGED_INTERVALS if merged else pending
	for c in chunks:
		var n := pending * (c + 1) / chunks - pending * c / chunks  # integer split, sums to pending
		var t_end := _t0 + float(steps_processed + n) * _step
		_process_interval(_last_processed, t_end, res, merged)
		if res.error != "":
			error = res.error
			return
		steps_processed += n
		_last_processed = t_end


func _process_interval(t_a: float, t_b: float, res: Dictionary, coalesce := false) -> void:
	var snaps := {}  # smooth reads the heights from before this step
	var pieces := timeline.segments_between(t_a, t_b)
	if coalesce:
		pieces = _coalesced(pieces, COALESCE_RADIUS_FRACTION * float(settings.get("radius", 6.0)))
	for piece in pieces:
		pieces_applied += 1
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


## Joins time-contiguous pieces (same timeline segment) into straight pieces no longer than
## `max_len`; pieces separated by a pause are never joined.
static func _coalesced(pieces: Array[Dictionary], max_len: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in pieces:
		if not out.is_empty():
			var last: Dictionary = out[out.size() - 1]
			var joined_len := (last.p_a as Vector2).distance_to(p.p_b)
			if last.t_b == p.t_a and last.p_b == p.p_a and joined_len <= max_len:
				last.t_b = p.t_b
				last.p_b = p.p_b
				last.pf_b = p.pf_b
				continue
		out.append(p.duplicate())
	return out


## Disabled or non-finite pressure is full strength (as BrushMath.pressure_factor), never NaN.
func _pf(pf: float) -> float:
	return pf if bool(settings.get("pressure_enabled", true)) and is_finite(pf) else 1.0
