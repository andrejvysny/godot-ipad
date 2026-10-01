class_name PaintStroke
extends RefCounted
## Coverage-based material paint stroke (spec §12.3). Painting is time-independent:
## each new piece between consecutive samples of a segment is painted immediately, begin and
## resume paint a dab, and paused gaps are never bridged. The caller owns the EditTransaction:
## it finishes it on success, or cancels the stroke (which rolls it back) on any result error
## ("budget", "invalid_input").
##
## Settings: radius, target_blend (0 grass / 1 dirt), strength, pressure_enabled, optional v2 keys
## of _configure_state().

var settings: Dictionary = {}
var error: String = ""

var _state: BrushKernels.PaintStrokeState
var _last_pos := Vector2.ZERO
var _last_pf := 1.0
var _open := false
var _finished := false


func begin(doc: WorldDocument, tx: EditTransaction, p_settings: Dictionary, pos: Vector2, pf: float) -> Dictionary:
	settings = p_settings.duplicate(true)
	_state = BrushKernels.PaintStrokeState.new(doc, tx, float(settings.get("target_blend", 1.0)))
	_configure_state()
	return resume(0.0, pos, pf)


## Optional v2 settings (docs/editor-v2.md §3, §4): op (paint | erase | spray | erase_spray | tint |
## untint), layer 0-3, tint preset 0-2, shape, alpha_mode, seed (spray). Without them the stroke is a
## legacy target_blend paint (1 = layer 1 dirt, 0 = layer 0 grass).
func _configure_state() -> void:
	var op := str(settings.get("op", "paint"))
	_state.op = op if op in BrushKernels.PaintStrokeState.OPS else "paint"
	_state.layer = clampi(int(settings.get("layer", _state.layer)), 0, 3)
	_state.tint_rgb = TintCodec.preset_rgb(int(settings.get("tint", 0)))
	_state.shape = str(settings.get("shape", "soft"))
	_state.alpha_mode = str(settings.get("alpha_mode", "circle"))
	_state.seed = float(settings.get("seed", 0.0))


func add_sample(t: float, pos: Vector2, pf: float) -> Dictionary:
	if not _open:
		return resume(t, pos, pf)
	var p := _pf(pf)
	var res := _paint(_last_pos, pos, _last_pf, p)
	_last_pos = pos
	_last_pf = p
	return res


func pause(_t: float) -> void:
	_open = false


## Starts a new segment with a dab at `pos`.
func resume(_t: float, pos: Vector2, pf: float) -> Dictionary:
	_open = true
	_last_pos = pos
	_last_pf = _pf(pf)
	return _paint(pos, pos, _last_pf, _last_pf)


## Every piece is already applied; releases the working buffers.
func finish(_t: float) -> Dictionary:
	var res := BrushKernels.empty_result()
	res.error = error
	_release()
	return res


## Rolls back every captured value and drops the working buffers.
func cancel() -> Dictionary:
	var tx := _state.tx
	_release()
	return tx.rollback()


func _paint(a: Vector2, b: Vector2, pf_a: float, pf_b: float) -> Dictionary:
	if error != "" or _finished:
		var skipped := BrushKernels.empty_result()
		skipped.error = error if error != "" else "finished"
		return skipped
	var res := BrushKernels.paint_segment(_state, a, b, float(settings.get("radius", 4.0)),
			float(settings.get("strength", 1.0)), pf_a, pf_b)
	error = res.error
	return res


func _release() -> void:
	_finished = true
	_open = false
	_state.clear()


## Disabled or non-finite pressure is full strength (as BrushMath.pressure_factor), never NaN.
func _pf(pf: float) -> float:
	return pf if bool(settings.get("pressure_enabled", true)) and is_finite(pf) else 1.0
