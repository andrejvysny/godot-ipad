class_name SelfTestV2
extends RefCounted
## Editor v2 steps of the self-test (docs/editor-v2.md): tint, flatten with a picked height, the
## meadow scatter set (stroke, fill lasso, erase, exact undo) and the auto-paint rule toggle.
## Input stays SYNTHETIC (SelfTestDriver); results are reported through the owner's `check`.

var _session: EditorSession
var _d: SelfTestDriver
var _check: Callable  # (id, title, cond, details)
var _shot: Callable  # (name) -> coroutine


func _init(session: EditorSession, driver: SelfTestDriver, check: Callable, shot: Callable) -> void:
	_session = session
	_d = driver
	_check = check
	_shot = shot


## S12: tint stroke touches colour maps only; flatten pulls a stroke toward a picked height.
func s12_tint_flatten() -> void:
	var tools := _session.tools
	tools.set_tool("tint")
	tools.set_setting("paint", "tint", 1)
	tools.set_setting("paint", "radius", 5.0)
	var heights := _d.snapshot("heights")
	var control := _d.snapshot("control")
	var color := _d.snapshot("color")
	var tint := await _d.stroke(_d.seg(_d.ground(40, 2), _d.ground(62, 2)))
	_check.call("S12", "tint stroke changed colour maps only", tint.committed
			and not _d.changed_regions(color, _d.snapshot("color")).is_empty()
			and _d.changed_regions(control, _d.snapshot("control")).is_empty()
			and _d.changed_regions(heights, _d.snapshot("heights")).is_empty(),
			{"attempts": tint.attempts, "over_ui": tint.over_ui})
	await _flatten_toward_pick()
	await _d.frames(3)
	await _shot.call("tint-flatten")


func _flatten_toward_pick() -> void:
	var tools := _session.tools
	tools.set_tool("flatten")
	tools.set_setting("sculpt", "radius", 6.0)
	tools.set_setting("sculpt", "strength", 1.0)
	var pick_point := _d.ground(60, 36)
	var error := tools.begin_height_pick()
	await _d.tap(_d.to_screen(pick_point))
	var target := float(tools.settings("flatten").target)
	var line: Array[Vector3] = _d.seg(_d.ground(40, -40), _d.ground(64, -40))
	var gap_before := _mean_gap(line, target)
	var stroke := await _d.stroke(line)
	var gap_after := _mean_gap(line, target)
	_check.call("S12", "flatten pulls the stroke toward the picked height",
			error == "" and not is_nan(target) and absf(target - pick_point.y) < 0.5 and stroke.committed
			and gap_after < gap_before,
			{"target": target, "gap_before": gap_before, "gap_after": gap_after, "attempts": stroke.attempts})


func _mean_gap(line: Array[Vector3], target: float) -> float:
	var sum := 0.0
	var n := 24
	for i in n + 1:
		var p := line[0].lerp(line[1], float(i) / float(n))
		sum += absf(_session.document.sample_height(p.x, p.z) - target)
	return sum / float(n + 1)


## S13: scatter stroke, fill lasso and erase each add one history action; undo restores exact bytes.
func s13_scatter() -> void:
	var tools := _session.tools
	var doc := _session.document
	tools.set_setting("scatter", "source", "set:meadow")
	tools.set_setting("place", "radius", 6.0)
	var bytes0 := doc.scatter.encode()
	var n0 := doc.scatter.count()
	var h0 := _session.history.size()
	tools.set_tool("scatter")
	var scatter := await _d.stroke(_d.seg(_d.ground(36, -28), _d.ground(60, -28)))
	var bytes1 := doc.scatter.encode()
	var n1 := doc.scatter.count()
	_check.call("S13", "meadow scatter stroke added instances as one history action",
			scatter.committed and n1 > n0 and _session.history.size() == h0 + 1,
			{"before": n0, "after": n1, "entries": _session.history.size() - h0, "attempts": scatter.attempts})
	await _d.frames(4)
	await _shot.call("scatter")
	tools.set_tool("fill")
	var loop: Array[Vector3] = [_d.ground(44, 10), _d.ground(64, 10), _d.ground(64, 26), _d.ground(44, 26), _d.ground(44, 11)]
	var fill := await _d.stroke(loop)
	var bytes2 := doc.scatter.encode()
	var n2 := doc.scatter.count()
	_check.call("S13", "fill lasso added instances as one history action",
			fill.committed and n2 > n1 and _session.history.size() == h0 + 2,
			{"before": n1, "after": n2, "attempts": fill.attempts})
	tools.set_tool("erase")
	tools.set_setting("place", "radius", 8.0)
	var erase := await _d.stroke(_d.seg(_d.ground(36, -28), _d.ground(60, -28)))
	var n3 := doc.scatter.count()
	_check.call("S13", "erase stroke removed some instances as one history action",
			erase.committed and n3 < n2 and n3 > 0 and _session.history.size() == h0 + 3,
			{"before": n2, "after": n3, "attempts": erase.attempts})
	tools.set_tool("select")
	_undo_checks(bytes0, bytes1, bytes2, doc)


func _undo_checks(bytes0: PackedByteArray, bytes1: PackedByteArray, bytes2: PackedByteArray, doc: WorldDocument) -> void:
	var after_erase := doc.scatter.encode()
	_session.undo()
	var undo_erase := doc.scatter.encode() == bytes2
	_session.undo()
	var undo_fill := doc.scatter.encode() == bytes1
	_session.undo()
	var undo_scatter := doc.scatter.encode() == bytes0
	_check.call("S13", "undo restores the exact scatter.encode() bytes of each earlier state",
			undo_erase and undo_fill and undo_scatter,
			{"erase": undo_erase, "fill": undo_fill, "scatter": undo_scatter})
	for i in 3:
		_session.redo()
	_check.call("S13", "redo reapplies the scatter edits exactly", doc.scatter.encode() == after_erase, {})


## S14: rule toggle is one history action that changes the hash; undo restores it; highlight shot.
func s14_rules() -> void:
	var rules := _session.document.rules
	var hash0 := _session.authored_hash()
	var h0 := _session.history.size()
	var was := rules.rock_enabled
	var error := _session.tools.rule_edits().toggle("rock")
	_check.call("S14", "rock rule toggle changes the authored hash as one history action",
			error == "" and rules.rock_enabled != was and _session.authored_hash() != hash0
			and _session.history.size() == h0 + 1, {"error": error})
	_session.undo()
	_check.call("S14", "undo restores the rule and the authored hash",
			_session.document.rules.rock_enabled == was and _session.authored_hash() == hash0, {})
	_session.redo()
	_session.undo()
	_session.terrain.set_rule_highlight(true)
	await _d.frames(6)
	await _shot.call("rules-highlight")
	_session.terrain.set_rule_highlight(false)
