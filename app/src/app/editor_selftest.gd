class_name EditorSelfTest
extends Node
## Scripted end-to-end run of the spec §21.1 demonstration sequence through the real input path
## (ScriptedInputProvider -> InputSystem -> router -> tools -> history -> storage -> export).
## All input is SYNTHETIC: results never count as iPad or Pencil evidence (CLAUDE.md evidence rules).
## Each check is one report entry {id, title, result, details}; a failed step does not stop later
## steps unless they depend on it.

signal finished(report: Dictionary)

const EVIDENCE_CLASS := "SYNTHETIC — not device evidence"
const OUTPUT_DIR := "user://selftest"
const LODGE := "built.lodge.cabin_a"
const BOULDER := "nature.rock.boulder_a"
const SPRUCE := "nature.tree.spruce_a"
const MAX_ATTEMPTS := 3
const STEP_DEPENDENCIES := {"S02": "S01", "S03": "S01", "S04": "S03", "S05": "S01", "S06": "S03",
	"S07": "S01", "S08": "S03", "S09": "S01", "S10": "S01", "S11": "S01"}

var output_dir := OUTPUT_DIR
var report: Dictionary = {}

var _session: EditorSession
var _provider: ScriptedInputProvider
var _steps: Array[Dictionary] = []
var _failed_steps: Dictionary = {}
var _shots: Array[Dictionary] = []
var _d: SelfTestDriver
var _boulder_id := ""
var _lodge_id := ""
var _spruce_id := ""
var _export_path := ""
var _cancel_reasons: Array[String] = []


func start(session: EditorSession) -> void:
	_session = session
	_provider = session.input.active_provider() as ScriptedInputProvider
	if _provider == null:
		_check("S00", "scripted provider is active", false, {"provider": session.input.active_provider().provider_name()})
		_finish()
		return
	_d = SelfTestDriver.new()
	_d.session = session
	_d.provider = _provider
	add_child(_d)
	session.tools.operation_cancelled.connect(func(reason: String) -> void: _cancel_reasons.append(reason))
	_run()


func _run() -> void:
	_prepare_output()
	await _d.frames(5)
	await _step("S01", _s01_open)
	await _step("S02", _s02_camera)
	await _step("S03", _s03_place)
	await _step("S04", _s04_rock_edits)
	await _step("S05", _s05_sculpt)
	await _step("S06", _s06_follow_terrain)
	await _step("S07", _s07_paint)
	await _step("S08", _s08_undo_redo)
	await _step("S09", _s09_interrupted)
	await _step("S10", _s10_reopen)
	await _step("S11", _s11_export)
	await _final_shot()
	_finish()


func _step(id: String, body: Callable) -> void:
	var dependency: String = STEP_DEPENDENCIES.get(id, "")
	if dependency != "" and _failed_steps.has(dependency):
		_check(id, "step skipped", false, {"reason": "skipped: dependency failed (%s)" % dependency})
		return
	await body.call()
	await _d.settle_storage()


# --- S01 ----------------------------------------------------------------------------------

func _s01_open() -> void:
	var old_world := _session.document.world_id
	var error := _session.open_fixture("gentle_hills")
	await _d.settle_storage()
	var doc := _session.document
	_check("S01", "Gentle Hills opened as a new working copy", error == "" and doc.world_id != old_world,
			{"error": error, "world_id": doc.world_id})
	_check("S01", "revision 0, no objects, empty history", doc.document_revision == 0
			and doc.objects.is_empty() and _session.history.size() == 0,
			{"revision": doc.document_revision, "objects": doc.objects.size()})
	await _d.frames(3)
	await _shot("opened")


# --- S02 ----------------------------------------------------------------------------------

func _s02_camera() -> void:
	var c := get_viewport().get_visible_rect().size * 0.5
	var unit := maxf(1.0, _session.input.mapper.viewport_units_per_point())  # gesture sizes scale with the mapping
	var hash_before := _session.authored_hash()
	var gestures := {
		"CA-01 one-finger orbit": [[c], [c + Vector2(160, 40) * unit]],
		"CA-02 two-finger pan": [[c - Vector2(40, 0), c + Vector2(40, 0)],
				[c - Vector2(40, 0) + Vector2(90, 50) * unit, c + Vector2(40, 0) + Vector2(90, 50) * unit]],
		"CA-03 two-finger pinch": [[c - Vector2(30, 0), c + Vector2(30, 0)],
				[c - Vector2(120, 0), c + Vector2(120, 0)]],
	}
	for title: String in gestures:
		var camera_before := _session.rig.get_camera().global_transform
		var attempts := 0
		var moved := false
		while not moved and attempts < MAX_ATTEMPTS:  # a window-focus cancel may eat a gesture
			attempts += 1
			await _d.fingers(gestures[title][0], gestures[title][1], 8)
			await _d.frames(3)
			moved = not _session.rig.get_camera().global_transform.is_equal_approx(camera_before)
		_check("S02", title + ": camera transform changed", moved, {"attempts": attempts})
	_check("S02", "camera gestures left the authored hash unchanged", _session.authored_hash() == hash_before, {})
	_check("S02", "router back to IDLE with no open contacts", _session.input.router.state_name() == "IDLE"
			and _session.input.router.contacts().is_empty(), {"state": _session.input.router.state_name()})
	_session.reset_camera()
	await _d.frames(3)


# --- S03 ----------------------------------------------------------------------------------

func _s03_place() -> void:
	var targets := [[LODGE, Vector2(20, 20)], [BOULDER, Vector2(12, 26)], [SPRUCE, Vector2(26, 12)]]
	var ids: Array[String] = []
	for entry: Array in targets:
		var asset_id: String = entry[0]
		var target: Vector2 = entry[1]
		var known := _session.document.objects.keys()
		var error := _session.tools.arm_asset(asset_id)
		var path := _d.seg(_d.ground(target.x - 6.0, target.y), _d.ground(target.x, target.y))
		var created := ""
		var attempts := 0
		while created == "" and attempts < MAX_ATTEMPTS:  # a window-focus cancel may eat a drag
			attempts += 1
			await _d.drag(path, PointerSample.Source.MOUSE_DEV, _d.next_contact(), 4)
			await _d.frames(4)
			for id: String in _session.document.objects:
				if not known.has(id):
					created = id
		var rec := _session.document.get_object(created)
		var near := rec != null and Vector2(rec.position[0], rec.position[2]).distance_to(target) <= 1.0
		_check("S03", "%s placed near (%d, %d) and selected" % [asset_id, target.x, target.y],
				error == "" and near and _session.tools.selected_id() == created
				and _session.tools.active_tool() == "select", {"error": error, "id": created, "attempts": attempts})
		ids.append(created)
	_lodge_id = ids[0]
	_boulder_id = ids[1]
	_spruce_id = ids[2]
	_check("S03", "3 objects in the document", _session.document.objects.size() == 3,
			{"count": _session.document.objects.size()})
	_check_boulder_anchor()
	await _shot("placed")


func _check_boulder_anchor() -> void:
	var rec := _session.document.get_object(_boulder_id)
	var node := _session.presenter.node_for(_boulder_id)
	if rec == null or node == null:
		_check("S03", "OB-01 boulder anchor maps to record position", false, {"record": rec != null})
		return
	var anchor := node.global_transform * _session.catalog.get_asset(BOULDER).anchor_local
	_check("S03", "OB-01 boulder anchor maps to record position",
			anchor.distance_to(rec.get_position_v3()) < 0.01, {"error_m": anchor.distance_to(rec.get_position_v3())})


# --- S04 ----------------------------------------------------------------------------------

func _s04_rock_edits() -> void:
	var tools := _session.tools
	var bounds := _session.presenter.world_bounds(_boulder_id)
	var grab := _d.to_screen(bounds.position + bounds.size * Vector3(0.75, 0.5, 0.75))
	await _d.tap(grab)
	_check("S04", "boulder selected by tapping it", tools.selected_id() == _boulder_id, {})
	var before := _session.document.get_object(_boulder_id).clone()
	var history_before := _session.history.size()
	var id := _d.next_contact()
	var h0 := _d.hit_at(grab)
	_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.BEGIN, grab)
	await _d.frames(2)
	var step := maxf(20.0, _session.input.mapper.points_to_viewport(8.0) * 1.6)  # beyond the tap threshold
	var direction := Vector2(-1.0, -0.3).normalized()
	var first := grab + direction * step
	_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.MOVE, first)
	await _d.frames(2)
	var moved := _session.document.get_object(_boulder_id)
	var delta := _d.hit_at(first) - h0
	var expected := Vector2(before.position[0], before.position[2]) + Vector2(delta.x, delta.z)
	var actual := Vector2(moved.position[0], moved.position[2])
	_check("S04", "OB-02 first drag frame moves by the hit delta, no jump",
			actual.distance_to(expected) <= 0.75 and actual.distance_to(Vector2(before.position[0], before.position[2])) <= Vector2(delta.x, delta.z).length() + 0.75,
			{"moved_m": actual.distance_to(Vector2(before.position[0], before.position[2])), "hit_delta_m": Vector2(delta.x, delta.z).length()})
	for i in 3:
		_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.MOVE, first + direction * step * 0.3 * float(i + 1))
		await _d.frames(2)
	_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.END, first + direction * step * 0.9)
	await _d.frames(3)
	var drag_entries := _session.history.size() - history_before
	var edit_errors := tools.nudge("yaw", 15.0) + tools.nudge("yaw", 15.0)
	edit_errors += tools.begin_object_edit("scale") + tools.update_object_edit(1.2) + tools.update_object_edit(1.4)
	tools.end_object_edit()
	edit_errors += tools.nudge("height", 0.2)
	await _d.frames(2)
	var rec := _session.document.get_object(_boulder_id)
	_check("S04", "drag is one history action", drag_entries == 1, {"entries": drag_entries})
	_check("S04", "yaw +30 (two nudges), scale and height edits: 4 history entries",
			edit_errors == "" and _session.history.size() - history_before - drag_entries == 4
			and absf(rad_to_deg(rec.get_yaw()) - 30.0) < 0.01 and rec.uniform_scale != before.uniform_scale
			and absf(rec.height_offset_m - 0.2) < 0.001,
			{"errors": edit_errors, "yaw_deg": rad_to_deg(rec.get_yaw()), "scale": rec.uniform_scale,
			"height_offset": rec.height_offset_m})


# --- S05 / S06 ----------------------------------------------------------------------------

func _s05_sculpt() -> void:
	_session.tools.set_setting("sculpt", "radius", 8.0)
	_session.tools.set_setting("sculpt", "strength", 1.0)
	_session.tools.set_tool("raise")
	_session.tools.set_inverted(false)
	var before := _d.snapshot("heights")
	var raise := await _d.stroke(_d.seg(_d.ground(-16, -40), _d.ground(16, -40)))
	_session.tools.set_inverted(true)
	var lower := await _d.stroke(_d.seg(_d.ground(48, 36), _d.ground(72, 36)))
	var regions := _d.changed_regions(before, _d.snapshot("heights"))
	_check("S05", "raise stroke across x=0 and lower stroke changed heights in >= 2 regions",
			raise.committed and lower.committed and regions.size() >= 2,
			{"regions": regions.size(), "raise_attempts": raise.attempts, "lower_attempts": lower.attempts,
			"over_ui": raise.over_ui or lower.over_ui})


func _s06_follow_terrain() -> void:
	var doc := _session.document
	var spruce := doc.get_object(_spruce_id).clone()
	var lodge := doc.get_object(_lodge_id).clone()
	var hash_before := _session.authored_hash()
	_session.tools.set_inverted(false)
	var path := _d.seg(_d.ground(spruce.position[0], spruce.position[2]), _d.ground(lodge.position[0], lodge.position[2]))
	var stroke := await _d.stroke(path)
	var spruce_now := doc.get_object(_spruce_id)
	_check("S06", "TE-11 spruce rises with the terrain, lodge y unchanged",
			stroke.committed and spruce_now.position[1] > spruce.position[1] + 0.05
			and doc.get_object(_lodge_id).equals(lodge),
			{"spruce_dy": spruce_now.position[1] - spruce.position[1], "attempts": stroke.attempts})
	await _shot("sculpted")
	var hash_after := _session.authored_hash()
	_session.undo()
	_check("S06", "one undo restores terrain and both objects exactly",
			_session.authored_hash() == hash_before and doc.get_object(_spruce_id).equals(spruce)
			and doc.get_object(_lodge_id).equals(lodge), {})
	_session.redo()
	_check("S06", "redo reapplies the stroke exactly", _session.authored_hash() == hash_after, {})


# --- S07 ----------------------------------------------------------------------------------

func _s07_paint() -> void:
	var tools := _session.tools
	tools.set_setting("paint", "layer", 1)
	tools.set_setting("paint", "radius", 5.0)
	tools.set_tool("paint")
	var before := _d.snapshot("control")
	var paint := await _d.stroke(_d.seg(_d.ground(40, -8), _d.ground(62, -8)))
	var after_paint := _d.snapshot("control")
	_check("S07", "dirt paint stroke changed control maps",
			paint.committed and not _d.changed_regions(before, after_paint).is_empty(), {"attempts": paint.attempts, "over_ui": paint.over_ui})
	tools.set_tool("path")
	tools.set_setting("path", "width", 3.0)
	var records := _object_records()
	var path := await _d.stroke(_d.seg(_d.ground(8, 20), _d.ground(34, 20)))
	_check("S07", "path stroke changed control maps", path.committed
			and not _d.changed_regions(after_paint, _d.snapshot("control")).is_empty(), {"attempts": path.attempts})
	_check("S07", "PA-00 path left every object record unchanged", _records_equal(records, _object_records()), {})
	tools.set_tool("select")
	await _d.frames(3)
	await _shot("painted")


# --- S08 ----------------------------------------------------------------------------------

func _s08_undo_redo() -> void:
	var final_hash := _session.authored_hash()
	var ids := _sorted_ids()
	var entries := _session.history.size()
	_session.undo()
	_session.undo()
	_check("S08", "undo of path and paint changes the hash", _session.authored_hash() != final_hash, {})
	_session.redo()
	_session.redo()
	_check("S08", "redo of paint and path restores the exact hash", _session.authored_hash() == final_hash, {})
	var undone := 0
	while _session.history.can_undo():
		_session.undo()
		undone += 1
	_check("S08", "undoing every action removes all placements", _session.document.objects.is_empty()
			and undone == entries, {"undone": undone, "entries": entries})
	var redone := 0
	while _session.history.can_redo():
		_session.redo()
		redone += 1
	_check("S08", "redo restores the same object ids and the exact hash",
			_sorted_ids() == ids and _session.authored_hash() == final_hash, {"redone": redone})


# --- S09 / S10 / S11 ----------------------------------------------------------------------

func _s09_interrupted() -> void:
	_session.tools.set_tool("raise")
	_session.tools.set_inverted(false)
	var hash_before := _session.authored_hash()
	var entries := _session.history.size()
	var attempts := 0
	var reason := ""
	while attempts < MAX_ATTEMPTS and reason != "native_cancel":
		attempts += 1
		_cancel_reasons.clear()
		var id := _d.next_contact()
		var from := _d.to_screen(_d.ground(40, -40))
		_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.BEGIN, from)
		for step in 6:
			await _d.until(Time.get_ticks_usec() + 60000)
			_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.MOVE, from + Vector2(8, 0) * float(step + 1))
		_provider.push(PointerSample.Source.MOUSE_DEV, id, PointerSample.Phase.CANCEL, from, false, 0.0, "native_cancel")
		await _d.frames(3)
		reason = _cancel_reasons[0] if not _cancel_reasons.is_empty() else ""
	_session.tools.set_tool("select")
	_check("S09", "IN-09 native cancel rolled the stroke back: hash equal, no history entry",
			reason == "native_cancel" and _session.authored_hash() == hash_before
			and _session.history.size() == entries and not _session.tools.has_active_operation(),
			{"cancel_reason": reason, "attempts": attempts})
	_check("S09", "TE-12 router back to IDLE after cancel", _session.input.router.state_name() == "IDLE", {})


func _s10_reopen() -> void:
	await _d.settle_storage()
	var doc := _session.document
	var saved := _session.storage.checkpoint_now(doc)
	var recovered := _session.storage.recover_latest_valid(doc.world_id, _session.catalog)
	var same := recovered.doc != null and CanonicalEncoder.authored_hash(recovered.doc) == _session.authored_hash()
	_check("S10", "checkpoint is durable and recovery reproduces the authored hash",
			bool(saved.durable) and same, {"durable": saved.durable, "error": str(saved.error) + str(recovered.error)})


func _s11_export() -> void:
	var result := _session.export_world()
	_export_path = str(result.path)
	var loaded := WorldLoader.load_world(_export_path, _session.catalog) if _export_path != "" else [null, "no export"]
	var doc: WorldDocument = loaded[0]
	var same := doc != null and CanonicalEncoder.authored_hash(doc) == _session.authored_hash() \
			and doc.sorted_object_ids() == _session.document.sorted_object_ids()
	_check("S11", "export exists and reloads with the same authored hash and object ids",
			_export_path != "" and FileAccess.file_exists(_export_path) and same,
			{"export_error": str(result.error), "load_error": str(loaded[1]), "path": _export_path})


func _object_records() -> Dictionary:
	var out := {}
	for id: String in _session.document.objects:
		out[id] = _session.document.get_object(id).clone()
	return out


func _records_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for id: String in a:
		if not b.has(id) or not (a[id] as ObjectRecord).equals(b[id]):
			return false
	return true


func _sorted_ids() -> PackedStringArray:
	var ids := _session.document.sorted_object_ids()
	ids.sort()
	return ids


# --- Evidence output ----------------------------------------------------------------------

func _check(id: String, title: String, cond: bool, details: Dictionary) -> void:
	_steps.append({"id": id, "title": title, "result": "PASS" if cond else "FAIL", "details": details})
	if not cond:
		_failed_steps[id] = true
	print("  [%s] %s %s" % ["PASS" if cond else "FAIL", id, title])


func _prepare_output() -> void:
	DirAccess.make_dir_recursive_absolute(output_dir)
	for file in DirAccess.get_files_at(output_dir):
		DirAccess.remove_absolute(output_dir.path_join(file))


## Screenshots need a real renderer; headless runs record the skip instead.
func _shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		_shots.append({"name": shot_name, "file": "", "note": "skipped (headless)"})
		return
	await RenderingServer.frame_post_draw
	var file := "%02d-%s.png" % [_shots.size() + 1, shot_name]
	var error := get_viewport().get_texture().get_image().save_png(output_dir.path_join(file))
	_shots.append({"name": shot_name, "file": file, "note": "ok" if error == OK else "save failed (%d)" % error})


func _final_shot() -> void:
	var overlay: Control = null
	if _session.ui != null and _session.ui.has_method("diagnostics_overlay"):
		overlay = _session.ui.call("diagnostics_overlay") as Control
	if overlay == null:
		_shots.append({"name": "diagnostics", "file": "", "note": "skipped (no diagnostics overlay on session.ui)"})
		return
	overlay.visible = true
	if overlay.has_method("refresh"):
		overlay.call("refresh", true)
	await _d.frames(5)
	await _shot("diagnostics")


func _finish() -> void:
	var pass_all := not _steps.is_empty()
	for entry in _steps:
		pass_all = pass_all and entry.result == "PASS"
	report = {"evidence_class": EVIDENCE_CLASS, "platform": OS.get_name(), "model": OS.get_model_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"provider": _session.input.active_provider().provider_name() if _session != null else "",
		"user_data_dir": OS.get_user_data_dir(), "world_id": _session.document.world_id,
		"final_authored_hash": _session.authored_hash(), "export_path": _export_path,
		"screenshots": _shots, "steps": _steps, "result": "PASS" if pass_all else "FAIL"}
	var path := output_dir.path_join("report.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("EDITOR_SELFTEST %s %s" % [report.result, ProjectSettings.globalize_path(path)])
	finished.emit(report)
	if OS.get_cmdline_user_args().has("--selftest-quit"):
		get_tree().quit(0 if pass_all else 1)
