extends RemoteUiCase
## Host acceptance of E2E-04/05/06 against a REAL AssetStudio integration listener (docs/evidence/int-v1). Skipped
## unless WP_ACC_URL is set; it never runs in the normal suite. Env: WP_ACC_URL, WP_ACC_SERVER_ID, WP_ACC_TOKEN_FILE
## (read-only token), WP_ACC_LIBRARY, WP_ACC_DIR (persistent scratch dir), WP_ACC_PHASE=online|offline,
## WP_ACC_CRATE_V1 (exact v1 version id of the published crate). Output lines "ACC <step> PASS|FAIL".

const NAMES := ["Neutral PBR Crate", "Textured Tree", "Vertex Color Foliage"]


func _enabled() -> bool:
	return OS.get_environment("WP_ACC_URL") != ""


func _acc(step: String, ok: bool) -> void:
	print("ACC %s %s" % [step, "PASS" if ok else "FAIL"])
	assert_true(ok, step)


func _real_session(root: String) -> EditorSession:
	fake = InputTests.FakeProvider.new()
	var s := EditorSession.new()
	s.storage_root = root
	s.start_fixture = "flat"
	s.provider_override = fake
	s.platform_override = "iOS"
	s.build_ui = true
	sessions.append(s)
	tree.root.add_child(s)
	await _frames(3)
	for i in 300:
		if not s.storage.is_busy():
			break
		await tree.process_frame
	return s


func _real_key() -> String:
	return RemoteLibrary.key_of(OS.get_environment("WP_ACC_SERVER_ID"), OS.get_environment("WP_ACC_LIBRARY"))


func _wait(cond: Callable, frames: int = 600) -> bool:
	for i in frames:
		if cond.call():
			return true
		await tree.process_frame
	return cond.call()


func _item(s: EditorSession, name: String) -> Dictionary:
	for it: Dictionary in s.assets().remote.items(_real_key()):
		if str(it.name) == name:
			return it
	return {}


func test_online_browse_download_drop_update_save() -> void:
	if not _enabled() or OS.get_environment("WP_ACC_PHASE") != "online":
		return
	var dir := OS.get_environment("WP_ACC_DIR")
	SessionAssets.storage_dir = dir + "/assetstudio"
	var s := await _real_session(dir + "/worlds")
	var token := FileAccess.get_file_as_string(OS.get_environment("WP_ACC_TOKEN_FILE")).strip_edges()
	var err := s.assets().connection.configure(OS.get_environment("WP_ACC_SERVER_ID"), OS.get_environment("WP_ACC_URL"), token)
	_acc("connection configured (loopback, read-only token)", err == "")
	await s.assets().reconnect()
	var remote := s.assets().remote
	_acc("libraries listed online", remote.connectivity().state == "online" and remote.libraries().size() >= 1)
	remote.select(_real_key())
	await remote.browse(_real_key())
	await _frames(5)
	var names: Array = remote.items(_real_key()).map(func(it: Dictionary) -> String: return str(it.name))
	_acc("browse lists the published assets (%s)" % str(names), NAMES.all(func(n: String) -> bool: return n in names))
	var crate := _item(s, NAMES[0])
	var tile: RemoteTile = _ui(s).library().remote_view().tile(str(crate.asset_key))
	_acc("tile starts Remote and is not draggable", tile != null and tile.readiness().state == RemotePrep.REMOTE)
	var objs := s.document.objects.size()
	await _drag(s, _center(tile), _centre_world(s))
	_acc("remote tile drag places nothing", s.document.objects.size() == objs and not s.tools.has_drop())
	await _pencil_click(s, tile.action_button())
	_acc("download from the real server reaches Ready", await _wait(func() -> bool: return tile.readiness().state == RemotePrep.READY))
	var crate_binding := str(tile.readiness().binding_id)
	var hist := s.history.size()
	await _drag(s, _center(tile), _centre_world(s))
	_acc("ready drag = one object, one history action", s.document.objects.size() == objs + 1 and s.history.size() == hist + 1)
	_acc("undo removes it, redo restores it", s.undo() == "" and s.document.objects.size() == objs and s.redo() == "" and s.document.objects.size() == objs + 1)
	await _drag(s, _center(tile), _centre_world(s), PointerSample.Phase.CANCEL)
	_acc("cancelled drag places nothing later", s.document.objects.size() == objs + 1 and not s.tools.has_drop())
	for n: String in [NAMES[1], NAMES[2]]:
		var it := _item(s, n)
		var id: String = await s.assets().remote.prep.prepare_item(it)
		_acc("download %s (textures/vertex colours) ready" % n, id != "" and await _wait(func() -> bool: return s.assets().remote.prep.state_of(it).state == RemotePrep.READY))
		var before := s.history.size()
		_place(s, LibrarySelection.remote(id), _centre_world(s) + Vector2(60 * s.document.objects.size(), 20))
		_acc("drop %s = one history action" % n, s.history.size() == before + 1 and s.render_state().registry().is_ready(id))
	var ref: Dictionary = crate.ref.duplicate()
	ref.version_id = OS.get_environment("WP_ACC_CRATE_V1")
	var old_id: String = await s.assets().remote.prep.prepare_ref(ref, "Crate v1")
	_acc("exact v1 prepared (not latest)", old_id != "" and await _wait(func() -> bool: return s.document.assets.is_prepared(old_id)) and s.document.assets.get_binding(old_id).asset_ref.version_id == ref.version_id)
	var placed := _place(s, LibrarySelection.remote(old_id), _centre_world(s) + Vector2(-120, -40))
	await s.assets().remote.updates.check()
	_acc("update offer for v1 object, scene stays on v1", s.assets().remote.updates.has_offer(old_id) and s.document.get_object(placed).binding_id == old_id)
	var dlg := _ui(s).update_dialog()
	s.tools.select(placed)
	await dlg.open_for(old_id)
	_acc("review ready", await _wait(func() -> bool: return dlg.can_apply()))
	print("ACC_INFO review text: ", dlg.body_text().replace("\n", " | "))
	var h2 := s.history.size()
	dlg.apply()
	var new_id: String = s.document.get_object(placed).binding_id
	_acc("approved update is one history action to the exact v2", new_id != old_id and s.history.size() == h2 + 1)
	_acc("undo returns to v1", s.undo() == "" and s.document.get_object(placed).binding_id == old_id)
	_acc("redo re-applies v2", s.redo() == "" and s.document.get_object(placed).binding_id == new_id)
	s.tools.select("")
	_acc("world saved", s.save_now() == "")
	var ids: Array = s.document.assets.ids()
	print("ACC_INFO objects=%d bindings=%d crate_binding=%s" % [s.document.objects.size(), ids.size(), crate_binding])
	var exact := true
	for i: String in ids:
		var b: AssetBinding = s.document.assets.get_binding(i)
		exact = exact and (b.is_bundled() or str(b.asset_ref.version_id).begins_with("ver_"))
	_acc("world references only exact versions", exact)
	s.assets().shutdown()  # stops the change-feed long poll the way the app does on teardown
	await _frames(10)
	SessionAssets.storage_dir = AssetStudioConnection.DIR


func test_offline_reopen_cached_and_uncached() -> void:
	if not _enabled() or OS.get_environment("WP_ACC_PHASE") != "offline":
		return
	var dir := OS.get_environment("WP_ACC_DIR")
	SessionAssets.storage_dir = dir + "/assetstudio"
	var s := await _real_session(dir + "/worlds")
	_acc("saved world reopened (objects=%d)" % s.document.objects.size(), s.boot_error == "" and s.document.objects.size() == 4)
	await _wait(func() -> bool: return s.read_only_reason == "")
	var evicted := OS.get_environment("WP_ACC_EVICTED") == "1"
	var unresolved := 0
	for id: String in s.document.assets.ids():
		if not s.document.assets.get_binding(id).is_bundled() and not s.render_state().registry().is_ready(id):
			unresolved += 1
	print("ACC_INFO read_only_reason=[%s] unresolved=%d evicted=%s" % [s.read_only_reason.replace("\n", " "), unresolved, str(evicted)])
	if not evicted:
		_acc("offline: every cached exact asset reopens, editing enabled", s.read_only_reason == "" and unresolved == 0)
		_acc("offline: objects drawn from prepared tiers", s.presenter.settle_now())
	else:
		_acc("offline, one blob evicted: explicit unresolved dependency, read-only", s.read_only_reason.begins_with("Read-only recovery:") and unresolved >= 1)
		_acc("the reason names the failure, no latest substitution", s.read_only_reason.contains("unavailable") or s.read_only_reason.contains("not_found"))
		var exact := true
		for id: String in s.document.assets.ids():
			var b: AssetBinding = s.document.assets.get_binding(id)
			exact = exact and (b.is_bundled() or str(b.asset_ref.version_id).begins_with("ver_"))
		_acc("bindings still pin their exact versions", exact)
	SessionAssets.storage_dir = AssetStudioConnection.DIR
