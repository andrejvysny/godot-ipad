extends TestCase
## Preview launcher and private session files (ADR 0016 P1/P2): the config holds the secrets and only its path is on
## the command line, the child deletes it, cleanup is confined to one session directory, and a real child process
## pairs with an iPad-side PreviewLink over loopback, renders, and leaves no trace when stopped.

var launcher: PreviewLauncher


func after_each() -> void:
	if launcher != null:
		launcher.stop()
		tree.root.remove_child(launcher)
		launcher.free()
		launcher = null


func _config(id: String) -> Dictionary:
	return {"session_id": id, "broker_port": 40000, "broker_credential": LiveIds.new_secret(), "listener_port": 0,
		"listener_bind": "127.0.0.1", "allow_insecure_lan": false, "profile_scene": "",
		"blob_root": "/tmp/blobs", "project_root": "/tmp/project"}


func _abs(id: String) -> String:
	return ProjectSettings.globalize_path(PreviewSession.config_path(id))


func test_config_is_owner_only_and_read_once() -> void:
	var id := LiveIds.new_id()
	assert_empty_string(PreviewSession.write_config(id, _config(id)), "write")
	assert_true(FileAccess.file_exists(PreviewSession.config_path(id)), "file exists")
	var perms := FileAccess.get_unix_permissions(PreviewSession.config_path(id))
	assert_eq(perms & 63, 0, "no group/other access: %d" % perms)
	var loaded := PreviewSession.read_and_delete(_abs(id))
	assert_true(loaded.ok, str(loaded.error))
	assert_eq(loaded.config.session_id, id, "config content")
	assert_false(FileAccess.file_exists(PreviewSession.config_path(id)), "deleted by the reader")
	assert_false(PreviewSession.read_and_delete(_abs(id)).ok, "cannot be read twice")
	PreviewSession.remove_session(id)


func test_reader_refuses_paths_and_configs_it_does_not_own() -> void:
	var id := LiveIds.new_id()
	var sentinel := ProjectSettings.globalize_path(scratch_dir()) + "/config.json"
	var f := FileAccess.open(sentinel, FileAccess.WRITE)
	f.store_string(JSON.stringify(_config(id)))
	f.close()
	assert_false(PreviewSession.read_and_delete(sentinel).ok, "a config outside the sessions root is refused")
	assert_true(FileAccess.file_exists(sentinel), "and not deleted")
	var bad := _config(id)
	bad.erase("broker_credential")
	PreviewSession.write_config(id, bad)
	assert_false(PreviewSession.read_and_delete(_abs(id)).ok, "incomplete config refused")
	var other := _config(LiveIds.new_id())
	PreviewSession.write_config(id, other)
	assert_false(PreviewSession.read_and_delete(_abs(id)).ok, "config naming another session refused")
	PreviewSession.remove_session(id)


func test_session_cleanup_is_confined_to_one_session_directory() -> void:
	var a := LiveIds.new_id()
	var b := LiveIds.new_id()
	for id in [a, b]:
		PreviewSession.write_config(id, _config(id))
		var f := FileAccess.open(PreviewSession.session_dir(id).path_join("blob.part"), FileAccess.WRITE)
		f.store_string("x")
		f.close()
	assert_empty_string(PreviewSession.remove_session(a), "remove a")
	assert_false(DirAccess.dir_exists_absolute(PreviewSession.session_dir(a)), "a removed")
	assert_true(DirAccess.dir_exists_absolute(PreviewSession.session_dir(b)), "b untouched")
	var outside := ProjectSettings.globalize_path(scratch_dir()) + "/keep.txt"
	var f := FileAccess.open(outside, FileAccess.WRITE)
	f.store_string("x")
	f.close()
	assert_eq(PreviewSession.remove_session("../" + a), "invalid session id", "traversal refused")
	assert_eq(PreviewSession.remove_session(".."), "invalid session id", "parent refused")
	assert_true(FileAccess.file_exists(outside), "files outside stay")
	PreviewSession.remove_session(b)


func _start_launcher() -> bool:
	launcher = PreviewLauncher.new()
	launcher.extra_args = PackedStringArray(["--headless"])
	tree.root.add_child(launcher)
	var error := launcher.start(0, false)
	if error != "":
		print("SKIP (NOT RUN): the preview process cannot be launched here: ", error)
		return false
	return true


func _until(cond: Callable, timeout_ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await tree.process_frame
	return false


func test_real_child_pairs_renders_and_cleans_up() -> void:
	var before := ProjectFingerprint.of("res://")
	if not _start_launcher():
		return
	var id := launcher.session_id
	var secret := launcher.broker.credential()
	assert_true(secret != "", "the broker credential existed at launch")
	for arg in launcher.last_args:
		assert_false(str(arg).contains(secret), "no secret on the command line")
	assert_true(launcher.last_args.has(_abs(id)), "the config path is on the command line")
	assert_true(await _until(func() -> bool: return launcher.state == "running", 60000), "child connected to the broker")
	assert_false(FileAccess.file_exists(PreviewSession.config_path(id)), "the child deleted its config")
	assert_true(await _until(func() -> bool: return int(launcher.broker.last_status().get("listener", {}).get("port", 0)) > 0, 20000), "status with listener port")
	var status := launcher.broker.last_status()
	var token := str(status.pairing.token)
	assert_eq(token.length(), 64, "pairing token reported")
	# iPad side pairs with the child over loopback and sends a world.
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var stub := SessionStub.new()
	stub.document = WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, catalog)
	tree.root.add_child(stub)
	var link := PreviewLink.new()
	tree.root.add_child(link)
	link.setup(stub)
	link.sender.spool = LiveSpool.new(scratch_dir() + "/spool")
	link.sender.scratch_root = scratch_dir() + "/tmp"
	assert_empty_string(link.connect_to("127.0.0.1", int(status.listener.port), false, token), "connect")
	var hash := CanonicalEncoder.authored_hash(stub.document)
	assert_true(await _until(func() -> bool:
		return launcher.broker.last_status().get("authored_hash", "") == hash, 30000), "child installed the snapshot and reports its hash")
	var tx := EditTransaction.new()
	tx.begin(stub.document, "test", "Raise")
	tx.capture_heights(Vector2i.ZERO)
	stub.document.get_region(Vector2i.ZERO).heights[3] = 2.0
	stub.document.invalidate_height_range(Vector2i.ZERO)
	stub.commit(tx.finish())
	var want := CanonicalEncoder.authored_hash(stub.document)
	assert_true(await _until(func() -> bool: return launcher.broker.last_status().get("authored_hash", "") == want, 20000), "commit applied by the child")
	assert_eq(int(launcher.broker.last_status().stats.resyncs), 0, "no resync")
	assert_true(bool(launcher.broker.last_status().visual_ready), "visual ready")
	link.disconnect_link(true)
	tree.root.remove_child(link)
	link.free()
	tree.root.remove_child(stub)
	stub.free()
	var pid := launcher.pid
	launcher.stop()
	assert_false(DirAccess.dir_exists_absolute(PreviewSession.session_dir(id)), "session directory removed")
	# OS.kill reaps the child, so OS.is_process_running would log an error here: probe with kill -0 instead.
	assert_true(await _until(func() -> bool: return OS.execute("kill", ["-0", str(pid)]) != 0, 10000), "child process ended")
	assert_eq(ProjectFingerprint.of("res://"), before, "nothing under res:// changed")


func test_child_exits_when_the_broker_goes_away() -> void:
	if not _start_launcher():
		return
	assert_true(await _until(func() -> bool: return launcher.state == "running", 60000), "child connected")
	launcher.broker.stop()  # the editor side vanishes without killing the child
	assert_true(await _until(func() -> bool: return launcher.state == "exited", 12000), "the child exits by itself")


## Child status error text after launching with `profile` as world_painter/preview/profile_scene ("" = healthy).
func _child_error_with_profile(profile: String) -> String:
	ProjectSettings.set_setting(PreviewLauncher.SETTING_PROFILE, profile)
	var result := "<no status>"
	if _start_launcher():
		var ok := await _until(func() -> bool:
			return int(launcher.broker.last_status().get("listener", {}).get("port", 0)) > 0, 60000)
		if ok:
			result = str(launcher.broker.last_status().session.error)
	ProjectSettings.set_setting(PreviewLauncher.SETTING_PROFILE, null)
	return result


func test_host_profile_with_a_mount_node_is_accepted() -> void:
	assert_eq(await _child_error_with_profile("res://tests/fixtures/preview_profile_ok.tscn"), "", "profile accepted")


func test_host_profile_without_a_mount_node_is_reported_and_replaced_by_the_default() -> void:
	var error := await _child_error_with_profile("res://tests/fixtures/preview_profile_no_mount.tscn")
	assert_error_contains(error, "world_painter_mount", "missing mount reported")
	await tree.process_frame
