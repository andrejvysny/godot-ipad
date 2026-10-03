@tool
extends EditorPlugin
# Test-only driver of the minimal consumer's editor side (E2E-13/14/15): starts the real preview child, publishes the
# pairing details to a control directory, then performs freeze / review / Apply steps when the iPad process signals.
const Coordinator := preload("res://addons/assetstudio/project/as_mutation_coordinator.gd")

var ctl := ""
var launcher: PreviewLauncher
var controller: ApplyController
var failed_steps := 0
var last_review: ApplyReview
var last_results: Array[Dictionary] = []
var last_failures: Array[String] = []

func _enter_tree() -> void:
	ctl = OS.get_environment("APPLY_CTL")
	if ctl != "":
		_run.call_deferred()

func _log(step: String, ok: bool, detail: String = "") -> void:
	print("DRV %s %s %s" % [step, "PASS" if ok else "FAIL", detail if not ok else ""])
	if not ok:
		failed_steps += 1

func _put(name: String, data: Dictionary) -> void:
	var f := FileAccess.open(ctl.path_join(name), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _read(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(ctl.path_join(name)))

func _wait_file(name: String, timeout_ms: int = 120000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if FileAccess.file_exists(ctl.path_join(name)):
			return true
		await get_tree().create_timer(0.1).timeout
	return false

func _until(cond: Callable, timeout_ms: int = 60000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()

func _fingerprint() -> String:
	var lines := PackedStringArray()
	_walk(ProjectSettings.globalize_path("res://"), "", lines)
	lines.sort()
	return "\n".join(lines).sha256_text()

func _walk(root: String, rel: String, lines: PackedStringArray) -> void:
	var dir := root.path_join(rel)
	for n in DirAccess.get_files_at(dir):
		var p := dir.path_join(n)
		lines.append("%s|%d|%s" % [rel.path_join(n), FileAccess.get_file_as_bytes(p).size(), FileAccess.get_sha256(p)])
	for n in DirAccess.get_directories_at(dir):
		if rel == "" and (n == ".godot" or n == ".world_painter"):
			continue
		_walk(root, rel.path_join(n), lines)

func _status() -> Dictionary:
	return launcher.broker.last_status()

func _freeze_and_review(tag: String) -> ApplyReview:
	last_review = null
	var before := last_failures.size()
	var err := controller.request_freeze()
	if err != "":
		_log(tag + " freeze request", false, err)
		return null
	await _until(func() -> bool: return last_review != null or last_failures.size() > before, 60000)
	_log(tag + " review built", last_review != null, str(last_failures))
	return last_review

func _run() -> void:
	await get_tree().create_timer(1.0).timeout
	launcher = PreviewLauncher.new()
	launcher.extra_args = PackedStringArray(["--headless"])
	add_child(launcher)
	var err := launcher.start(0, false)
	_log("preview child launched by the editor plugin", err == "", err)
	_log("child running", await _until(func() -> bool: return launcher.state == "running"))
	_log("child listener up", await _until(func() -> bool: return int(_status().get("listener", {}).get("port", 0)) > 0, 30000))
	controller = ApplyController.new()
	add_child(controller)
	controller.setup(launcher)
	controller.review_ready.connect(func(r: ApplyReview) -> void: last_review = r)
	controller.failed.connect(func(m: String) -> void: last_failures.append(m))
	controller.finished.connect(func(r: Dictionary) -> void: last_results.append(r))
	_put("pairing.json", {"port": int(_status().listener.port), "token": str(_status().pairing.token)})
	# ---- 1: iPad connected, world synced, assets resolved from the real server by the broker
	_log("iPad world ready signal", await _wait_file("ipad_ready1.json"))
	var ready1 := _read("ipad_ready1.json")
	_log("child replica hash equals the iPad hash", await _until(func() -> bool: return str(_status().get("authored_hash", "")) == str(ready1.hash)))
	_log("child visual ready, nothing missing", await _until(func() -> bool: return bool(_status().get("visual_ready", false)) and (_status().get("missing", []) as Array).is_empty(), 90000))
	# ---- E2E-12: tracked project content before Apply
	var fp0 := _fingerprint()
	var review := await _freeze_and_review("freeze1")
	if review == null:
		_finish()
		return
	_log("review blockers empty", review.blockers.is_empty(), str(review.blockers))
	_log("review is the committed revision, not the overlay", review.authored_hash == str(ready1.hash) and review.revision == int(ready1.revision), "%s vs %s" % [review.authored_hash.left(12), str(ready1.hash).left(12)])
	var deps: Array = review.dependencies.map(func(d: Dictionary) -> String: return "%s:%s/%s" % [str(d.name), str(d.change), str(d.state)])
	print("DRV_INFO dependencies ", deps)
	_log("project content unchanged by preview + freeze + review (E2E-12)", _fingerprint() == fp0)
	_put("driver_frozen1.json", {"revision": review.revision, "hash": review.authored_hash, "dir": review.dir_name})
	# ---- 13: later iPad edits must not leak
	_log("iPad later edits signal", await _wait_file("ipad_edited1.json"))
	var late := _read("ipad_edited1.json")
	_log("live replica moved on from the frozen revision", await _until(func() -> bool: return str(_status().get("authored_hash", "")) == str(late.hash)) and str(late.hash) != review.authored_hash)
	var frozen_doc := review.doc
	await controller.confirm(false)
	_log("apply 1 ok", last_results.size() == 1 and bool(last_results[0].ok), str(last_results))
	var binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(review.world_id)))
	_log("accepted snapshot is the reviewed (frozen) revision", str(binding.get("authored_hash", "")) == review.authored_hash)
	var scene := review.destination.path_join("generated/world.tscn")
	var summary := WorldSceneCheck.summarize(scene, get_tree())
	_log("generated world matches the frozen document, later edits absent", WorldSceneCheck.compare(summary, frozen_doc).is_empty() and summary.objects.size() == frozen_doc.objects.size() and int(late.objects) > summary.objects.size())
	var gen1 := review.dir_name
	var world_id := review.world_id
	# ---- 15: game siblings next to the generated world
	var game := ProjectSettings.globalize_path("res://").path_join("game")
	DirAccess.make_dir_recursive_absolute(game)
	var pf := FileAccess.open(game.path_join("player.gd"), FileAccess.WRITE)
	pf.store_string("extends Node3D\nfunc hello() -> int:\n\treturn 1\n")
	pf.close()
	var gscene := Node3D.new()
	gscene.name = "Game"
	var mount := WPAcceptedWorldMount.new()
	mount.name = "World"
	mount.binding = ResourceLoader.load(ApplyLayout.binding_res(world_id), "", ResourceLoader.CACHE_MODE_IGNORE) as WPAcceptedWorldBinding
	gscene.add_child(mount)
	mount.owner = gscene
	for sib: Node in [DirectionalLight3D.new(), Node3D.new()]:
		sib.name = "Light" if sib is DirectionalLight3D else "Player"
		gscene.add_child(sib)
		sib.owner = gscene
	(gscene.get_node("Player") as Node3D).set_script(load("res://game/player.gd"))
	var packed := PackedScene.new()
	packed.pack(gscene)
	gscene.free()
	_log("game scene saved", ResourceSaver.save(packed, "res://game/main.tscn") == OK)
	var hashes := {"main": FileAccess.get_sha256(game.path_join("main.tscn")), "player": FileAccess.get_sha256(game.path_join("player.gd"))}
	_put("driver_apply1_done.json", {"generation": gen1})
	_log("iPad edit 2 signal", await _wait_file("ipad_edited2.json"))
	var r2 := _read("ipad_edited2.json")
	await _until(func() -> bool: return str(_status().get("authored_hash", "")) == str(r2.hash))
	var review2 := await _freeze_and_review("freeze2")
	if review2 != null:
		_log("second review applicable over an untouched generated directory", review2.can_apply(), str(review2.blockers) + str(review2.soft_blockers))
		last_results.clear()
		await controller.confirm(false)
		_log("apply 2 ok (existing world replaced by a new complete generation)", last_results.size() == 1 and bool(last_results[0].ok), str(last_results))
		_log("game siblings (scene, script, light, player) byte-identical", FileAccess.get_sha256(game.path_join("main.tscn")) == hashes.main and FileAccess.get_sha256(game.path_join("player.gd")) == hashes.player)
		_log("binding points at generation 2", str(ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id))).get("generation_id", "")) == review2.generation_id)
		# modify generated content
		var generated := ApplyLayout.abs_of(review2.destination).path_join("generated/world.tscn")
		var gf := FileAccess.open(generated, FileAccess.READ_WRITE)
		gf.store_string("[gd_scene format=3]\n")
		gf.close()
		_put("driver_modified.json", {"ok": true})
		_log("iPad edit 3 signal", await _wait_file("ipad_edited3.json"))
		var r3 := _read("ipad_edited3.json")
		await _until(func() -> bool: return str(_status().get("authored_hash", "")) == str(r3.hash))
		var review3 := await _freeze_and_review("freeze3")
		if review3 != null:
			_log("modified generated content blocks the replacement", not review3.can_apply() and "; ".join(review3.soft_blockers).contains("generated"), str(review3.soft_blockers))
			last_results.clear()
			await controller.confirm(false)
			_log("refused without explicit discard, binding untouched", last_results.size() == 1 and not bool(last_results[0].ok) and str(ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id))).get("generation_id", "")) == review2.generation_id)
			last_results.clear()
			await controller.confirm(true)
			_log("explicit discard allows the replacement", last_results.size() == 1 and bool(last_results[0].ok), str(last_results))
			_log("game siblings still byte-identical", FileAccess.get_sha256(game.path_join("main.tscn")) == hashes.main and FileAccess.get_sha256(game.path_join("player.gd")) == hashes.player)
	# ---- 14: crash at every coordinator step on a fresh candidate
	_put("driver_crash_ready.json", {"ok": true})
	_log("iPad edit 4 signal", await _wait_file("ipad_edited4.json"))
	var r4 := _read("ipad_edited4.json")
	await _until(func() -> bool: return str(_status().get("authored_hash", "")) == str(r4.hash))
	last_review = null
	err = controller.request_freeze()
	await _until(func() -> bool: return last_review != null, 60000)
	var base := last_review
	var info := {"id": 0}
	var snapshot_dir := ""
	if base != null:
		var old_binding := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id)))
		var old_gen := str(old_binding.get("generation_id", "")).left(32)
		var lock_old := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assetstudio.lock.json"))
		var crashes := 0
		var done := false
		var step := 1
		var ok_all := true
		var source_path := base.source_override_abs
		while step < 60 and not done:
			var rv: ApplyReview = base if step == 1 else null
			if rv == null:
				last_review = null
				controller.request_freeze()
				await _until(func() -> bool: return last_review != null, 60000)
				rv = last_review
			Coordinator.fail_after_step = step
			var tx := ApplyTransaction.new(ApplyContext.for_project(get_tree()))
			var result: Dictionary = await tx.apply(rv, false)
			Coordinator.fail_after_step = -1
			done = bool(result.ok)
			if not done:
				crashes += 1
				ok_all = ok_all and str(result.get("code", "")) == "simulated_crash"
			var rec := ApplyTransaction.recover()
			ok_all = ok_all and bool(rec.ok)
			var b := ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id)))
			var active := str(b.get("generation_id", "")).left(32)
			var scene_res := ApplyLayout.generation_res(world_id, active).path_join("generated/world.tscn")
			var complete := FileAccess.file_exists(ApplyLayout.abs_of(scene_res))
			var known := active == old_gen or active == rv.dir_name
			ok_all = ok_all and complete and known
			if active == old_gen:
				ok_all = ok_all and FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assetstudio.lock.json")) == lock_old
			step += 1
			if step > 4 and not done and crashes > 0 and step > 40:
				break
		_log("crash at every coordinator step leaves the old or the new complete generation (%d crash points, finished=%s)" % [crashes, str(done)], ok_all and done and crashes >= 10)
	print("DRV_INFO failed_steps=", failed_steps)
	_finish()

func _finish() -> void:
	_put("driver_done.json", {"failed": failed_steps})
	await get_tree().create_timer(0.5).timeout
	launcher.stop()
	print("DRV_%s" % ("OK" if failed_steps == 0 else "FAILED"))
	get_tree().quit(0 if failed_steps == 0 else 1)
