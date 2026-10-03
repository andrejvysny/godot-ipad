@tool
extends EditorPlugin
# Acceptance driver (test-only). E2E_PHASE=A|B|C. Uses the real dock action code in a headless editor against the real server.
const Actions = preload("res://addons/assetstudio/editor/as_dock_actions.gd")
var _failed: int = 0
var _actions: Node = null

func _enter_tree() -> void:
	if OS.get_environment("E2E_PHASE") != "":
		_run.call_deferred()

func _step(name: String, ok: bool, detail: String = "") -> void:
	print("E2E %s %s %s" % [name, "PASS" if ok else "FAIL", detail if not ok else ""])
	if not ok:
		_failed += 1

func _run() -> void:
	await get_tree().create_timer(1.0).timeout
	_actions = Actions.new()
	add_child(_actions)
	_actions.setup(self)
	_actions.import_wait_s = 90.0
	var phase: String = OS.get_environment("E2E_PHASE")
	var items: Array = JSON.parse_string(OS.get_environment("E2E_ITEMS")) if OS.get_environment("E2E_ITEMS") != "" else []
	if phase != "C":
		_step("connected", _actions.connection_status()["connected"], str(_actions.connection_status()))
	EditorInterface.open_scene_from_path("res://level.tscn")
	await get_tree().create_timer(1.0).timeout
	var root: Node = EditorInterface.get_edited_scene_root()
	_step("scene open", root != null)
	if root != null:
		match phase:
			"A": await _phase_a(root, items)
			"B": await _phase_b(root, items)
			"C": _phase_c(root)
	print("E2E_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(1 if _failed != 0 else 0)

func _bindings(asset_id: String) -> Array:
	_actions.reload()
	var out: Array = []
	for b: String in _actions.infos:
		if str(_actions.infos[b].get("asset_id", "")) == asset_id:
			out.append(b)
	return out

func _phase_a(root: Node, items: Array) -> void:
	var by_name: Dictionary = {}
	for it: Dictionary in items:
		var r: RefCounted = await _actions.install(it)
		_step("install %s (add, import, finalize)" % it["display_name"], r.ok, r.describe())
		var bs: Array = _bindings(it["asset_id"])
		_step("binding Ready %s" % it["display_name"], bs.size() == 1 and _actions.infos[bs[0]]["state"] == "ready", str(_actions.infos))
		if bs.size() == 1:
			by_name[it["display_name"]] = bs[0]
	var placed: Array = []
	for n: String in ["Neutral PBR Crate", "Neutral PBR Crate", "Textured Tree", "Vertex Color Foliage"]:
		if by_name.has(n):
			var node: Node = _actions.place(by_name[n])
			_step("place %s" % n, node != null and node.owner == root and node.get_child_count() > 0 and str(node.get_meta("assetstudio_binding", "")) == by_name[n])
			placed.append(node)
	var hist: UndoRedo = get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	_step("4 instances placed", root.get_child_count() == 4, str(root.get_child_count()))
	hist.undo()
	_step("undo removes last placed instance", root.get_child_count() == 3, str(root.get_child_count()))
	hist.redo()
	_step("redo restores it", root.get_child_count() == 4)
	var c: int = 0
	for n: Node in root.get_children():
		(n as Node3D).position = Vector3(c * 3.0, 0, 0)
		c += 1
	_step("save scene", EditorInterface.save_scene() == OK)
	var text: String = FileAccess.get_file_as_string("res://level.tscn")
	_step("saved scene instances 4 wrappers and embeds no asset geometry", text.count("instance=ExtResource") == 4 and not text.contains("ArrayMesh"), text.substr(0, 400))
	_step("no World Painter / Terrain3D in project", not DirAccess.dir_exists_absolute("res://addons/world_painter") and not DirAccess.dir_exists_absolute("res://addons/terrain_3d"))

func _phase_b(root: Node, items: Array) -> void:
	# scene has 4 instances: two crates (v1 binding), tree, foliage
	var crate_id: String = ""
	for it: Dictionary in items:
		if it["display_name"] == "Neutral PBR Crate":
			crate_id = it["asset_id"]
	var bs: Array = _bindings(crate_id)
	var old_b: String = bs[0]
	var old_v: String = str(_actions.infos[old_b]["version_id"])
	await _actions.check_updates()
	_step("update badge shown for crate (v2 on server)", _actions.infos[old_b]["state"] == "update_available", str(_actions.infos[old_b]))
	var crates: Array = []
	for n: Node in root.get_children():
		if str(n.get_meta("assetstudio_binding", "")) == old_b:
			crates.append(n)
	_step("scene still on v1 before approval (2 crate instances, v1 binding)", crates.size() == 2 and str(_actions.infos[old_b]["version_id"]) == old_v)
	var review: RefCounted = await _actions.review(old_b)
	_step("review available", review.ok, review.describe())
	print("E2E_INFO review diff: ", str(review.value["diff"]) if review.ok else "")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(crates[0])
	var r: RefCounted = await _actions.apply_update_instances(old_b)
	_step("update selected instance", r.ok, r.describe())
	var hist: UndoRedo = get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	var on_new: int = 0
	var on_old: int = 0
	for n: Node in root.get_children():
		var m: String = str(n.get_meta("assetstudio_binding", ""))
		if m == old_b:
			on_old += 1
		elif _bindings(crate_id).has(m):
			on_new += 1
	_step("one instance moved to v2 binding, other crate remains valid on v1", on_new == 1 and on_old == 1 and _actions.infos[old_b]["version_id"] == old_v, "new=%d old=%d" % [on_new, on_old])
	hist.undo()
	var back: int = 0
	for n: Node in root.get_children():
		if str(n.get_meta("assetstudio_binding", "")) == old_b:
			back += 1
	_step("undo reverts the update (both crates on v1)", back == 2, str(back))
	hist.redo()
	_step("save scene after update", EditorInterface.save_scene() == OK)

func _phase_c(root: Node) -> void:
	var n_ok: int = 0
	for n: Node in root.get_children():
		if n.get_child_count() > 0:
			n_ok += 1
	_step("offline: scene reopens with all 4 wrappers resolved", root.get_child_count() == 4 and n_ok == 4, "%d/%d" % [n_ok, root.get_child_count()])
	_actions.setup(self)
	print("E2E_INFO connection: ", str(_actions.connection_status()))
