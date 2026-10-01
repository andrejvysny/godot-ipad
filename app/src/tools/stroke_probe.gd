class_name StrokeProbe
extends RefCounted
## Per-stroke diagnostics: how strong a stroke was and whether it changed the document.
## pressure_* are NAN when no valid-pressure sample was seen ("no sample", never 0).

var _tool_id := ""
var _t0 := 0.0
var _t_last := 0.0
var _samples := 0
var _valid := 0
var _p_min := NAN
var _p_max := NAN
var _p_sum := 0.0
var _pf_sum := 0.0


func begin(tool_id: String, t: float) -> void:
	_tool_id = tool_id
	_t0 = t
	_t_last = t
	_samples = 0
	_valid = 0
	_p_min = NAN
	_p_max = NAN
	_p_sum = 0.0
	_pf_sum = 0.0


func add_sample(pressure_valid: bool, pressure: float, pf: float, t: float) -> void:
	_samples += 1
	_pf_sum += pf
	_t_last = t
	if pressure_valid and not is_nan(pressure):
		_valid += 1
		_p_sum += pressure
		_p_min = pressure if is_nan(_p_min) else minf(_p_min, pressure)
		_p_max = pressure if is_nan(_p_max) else maxf(_p_max, pressure)


## result: "committed" | "no_change" | "cancelled".
func finish(result: String, change: WorldChange, steps: int, error: String) -> Dictionary:
	var regions := {}
	if change != null:
		for loc: Vector2i in change.before_heights:
			regions[loc] = true
		for loc: Vector2i in change.before_controls:
			regions[loc] = true
	return {"tool": _tool_id, "result": result, "error": error, "duration_s": _t_last - _t0,
		"samples": _samples, "pressure_valid_samples": _valid, "pressure_min": _p_min,
		"pressure_max": _p_max, "pressure_avg": _p_sum / float(_valid) if _valid > 0 else NAN,
		"pf_avg": _pf_sum / float(_samples) if _samples > 0 else NAN, "steps": steps,
		"peak_dh_m": peak_height_delta(change), "controls_changed": changed_controls(change),
		"regions": regions.size()}


static func peak_height_delta(change: WorldChange) -> float:
	var peak := 0.0
	if change == null:
		return peak
	for loc: Vector2i in change.before_heights:
		var before: PackedFloat32Array = change.before_heights[loc]
		var after: PackedFloat32Array = change.after_heights.get(loc, before)
		for i in mini(before.size(), after.size()):
			peak = maxf(peak, absf(after[i] - before[i]))
	return peak


static func changed_controls(change: WorldChange) -> int:
	var count := 0
	if change == null:
		return count
	for loc: Vector2i in change.before_controls:
		var before: PackedInt32Array = change.before_controls[loc]
		var after: PackedInt32Array = change.after_controls.get(loc, before)
		for i in mini(before.size(), after.size()):
			if before[i] != after[i]:
				count += 1
	return count
