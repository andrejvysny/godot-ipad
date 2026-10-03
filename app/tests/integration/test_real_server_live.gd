extends TestCase
## Host acceptance of E2E-09..12 (docs/evidence/int-v1): the real EditorSession as sender, the REAL preview child
## process (headless) over loopback WebSocket, and the real editor-side broker resolving the child's assets from a
## REAL AssetStudio listener. Skipped unless WP_ACC_URL is set. Env: WP_ACC_URL, WP_ACC_SERVER_ID, WP_ACC_TOKEN_FILE
## (read-only), WP_ACC_LIBRARY, WP_ACC_PROJECT_JSON (an assetstudio.project.json naming that server and library),
## WP_ACC_DIR. Latencies are host loopback, Debug build, headless: synthetic, never device figures.
## Output lines "LIVE <step> PASS|FAIL" and "LIVE_METRIC ...".

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const NAMES := ["Neutral PBR Crate", "Textured Tree", "Vertex Color Foliage"]

var log_filter: TerrainTests.KnownWarningFilter
var s: EditorSession
var launcher: PreviewLauncher
var link: PreviewLink
var t_stroke := 1.0


func before_each() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	if link != null and is_instance_valid(link):
		link.disconnect_link(true)
	if launcher != null and is_instance_valid(launcher):
		launcher.stop()
		tree.root.remove_child(launcher)
		launcher.free()
	launcher = null
	if is_instance_valid(link):
		if link.get_parent() != null:
			link.get_parent().remove_child(link)
		link.free()
	link = null
	if is_instance_valid(s):
		s.assets().shutdown()
		if s.get_parent() != null:
			tree.root.remove_child(s)
		s.free()
	SessionAssets.storage_dir = AssetStudioConnection.DIR
	OS.remove_logger(log_filter)


func _enabled(phase: String = "live") -> bool:
	return OS.get_environment("WP_ACC_URL") != "" and OS.get_environment("WP_ACC_PHASE") == phase


func _ok(step: String, ok: bool) -> void:
	print("LIVE %s %s" % [step, "PASS" if ok else "FAIL"])
	assert_true(ok, step)


func _until(cond: Callable, timeout_ms: int = 10000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await tree.process_frame
	return cond.call()


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _sample(x: float, z: float) -> PointerSample:
	var p := PointerSample.new()
	p.source = PointerSample.Source.PENCIL
	t_stroke += 0.02
	p.timestamp_s = t_stroke
	p.position_viewport = s.rig.get_camera().unproject_position(Vector3(x, s.document.sample_height(x, z), z))
	return p


func _act(type: String, x: float, z: float) -> void:
	s._on_tool_action({"type": type, "sample": _sample(x, z), "over_ui": false})


func _stroke_commit(tool: String, x0: float, x1: float, z: float) -> void:
	s.tools.set_tool(tool)
	_act("tool_begin", x0, z)
	_act("tool_move", (x0 + x1) * 0.5, z)
	_act("tool_end", x1, z)


func _status() -> Dictionary:
	return launcher.broker.last_status()


func _child_has(hash: String) -> bool:
	return str(_status().get("authored_hash", "")) == hash


func _setup_world(host_side: bool = true) -> void:
	var dir := OS.get_environment("WP_ACC_DIR")
	var sid := OS.get_environment("WP_ACC_SERVER_ID")
	var url := OS.get_environment("WP_ACC_URL")
	var token := FileAccess.get_file_as_string(OS.get_environment("WP_ACC_TOKEN_FILE")).strip_edges()
	if host_side:
		# host project configuration + the broker's own registry/cache (user://assetstudio): distinct from the iPad session's
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://assetstudio"))
		var f := FileAccess.open("res://assetstudio.project.json", FileAccess.WRITE)
		f.store_buffer(FileAccess.get_file_as_bytes(OS.get_environment("WP_ACC_PROJECT_JSON")))
		f.close()
		var host := AssetStudioConnection.new()
		_ok("host (broker) connection configured", host.configure(sid, url, token) == "")
		host.shutdown()
	SessionAssets.storage_dir = dir + "/live_ipad_assetstudio"
	s = EditorSession.new()
	s.storage_root = dir + "/live_worlds"
	s.start_fixture = "flat"
	s.provider_override = InputTests.FakeProvider.new()
	s.platform_override = "iOS"
	s.build_ui = false
	tree.root.add_child(s)
	await _frames(3)
	await _until(func() -> bool: return not s.storage.is_busy(), 8000)
	_ok("iPad session connection", s.assets().connection.configure(sid, url, token) == "")
	await s.assets().reconnect()
	var key := RemoteLibrary.key_of(sid, OS.get_environment("WP_ACC_LIBRARY"))
	s.assets().remote.select(key)
	await s.assets().remote.browse(key)
	var x := -8.0
	for n in NAMES:
		var item: Dictionary = {}
		for it: Dictionary in s.assets().remote.items(key):
			if str(it.name) == n:
				item = it
		var id: String = await s.assets().remote.prep.prepare_item(item)
		await _until(func() -> bool: return s.document.assets.is_prepared(id), 20000)
		_ok("prepared %s from the real server" % n, id != "" and s.document.assets.is_prepared(id))
		s.tools.begin_drop(LibrarySelection.remote(id))
		var pos := s.rig.get_camera().unproject_position(Vector3(x, s.document.sample_height(x, 0.0), 0.0))
		s.tools.update_drop(pos, false)
		s.tools.finish_drop(pos, false)
		x += 8.0
	_ok("3 remote objects placed", s.document.objects.size() == 3)


func _start_child() -> void:
	launcher = PreviewLauncher.new()
	launcher.extra_args = PackedStringArray(["--headless"])
	tree.root.add_child(launcher)
	var err := launcher.start(0, false)
	_ok("preview child process launched", err == "")
	_ok("child connected to the broker", await _until(func() -> bool: return launcher.state == "running", 60000))
	_ok("child listener up", await _until(func() -> bool: return int(_status().get("listener", {}).get("port", 0)) > 0, 20000))
	link = PreviewLink.new()
	tree.root.add_child(link)
	link.setup(s)
	var token := str(_status().pairing.token)
	_ok("iPad paired with the child over loopback", link.connect_to("127.0.0.1", int(_status().listener.port), false, token) == "")
	var want := s.authored_hash()
	_ok("child installed the snapshot (hash equal)", await _until(func() -> bool: return _child_has(want), 30000))
	_ok("child resolved every asset through the broker from the real server (visual ready)",
			await _until(func() -> bool: return bool(_status().get("visual_ready", false)) and (_status().get("missing", []) as Array).is_empty(), 60000))


func _pct(v: Array[float], q: float) -> float:
	var c := v.duplicate()
	c.sort()
	return c[mini(int(c.size() * q), c.size() - 1)]


func test_live_session_against_real_child_and_real_server() -> void:
	if not _enabled():
		return
	await _setup_world()
	var fingerprint_before := ProjectFingerprint.of("res://")
	await _start_child()
	# --- E2E-09: commits install matching hash (sculpt, paint, path, remote object drop after connect)
	for t: Array in [["raise", -4.0, 4.0, -3.0], ["paint", -6.0, 6.0, 3.0]]:
		_stroke_commit(t[0], t[1], t[2], t[3])
		var h := s.authored_hash()
		_ok("%s commit: child hash equals sender hash" % t[0], await _until(func() -> bool: return _child_has(h), 10000))
	s.tools.set_tool("path")
	_act("tool_begin", -10.0, 8.0)
	for i in range(1, 12):
		_act("tool_move", -10.0 + i * 1.8, 8.0)
	_act("tool_end", 10.0, 8.0)
	var hp := s.authored_hash()
	_ok("path commit (flatten + follow-terrain regrounding in one revision): child hash equal", await _until(func() -> bool: return _child_has(hp), 10000))
	_ok("no resync so far", int(_status().stats.resyncs) == 0)
	# provisional feedback appears while a stroke is open
	s.tools.set_tool("raise")
	var committed := s.authored_hash()
	_act("tool_begin", -2.0, -6.0)
	var overlay_seen := false
	for i in 40:
		_act("tool_move", -2.0 + i * 0.1, -6.0)
		await tree.create_timer(0.066).timeout
		overlay_seen = overlay_seen or bool(_status().get("session", {}).get("overlay", false))
	_ok("child reports a provisional overlay during the stroke (previews sent=%d)" % int(link.sender.stats.previews), overlay_seen and int(link.sender.stats.previews) > 0)
	# --- E2E-10 cancel mid-stroke
	s.cancel_active()
	_ok("cancel: child overlay disappears", await _until(func() -> bool: return not bool(_status().get("session", {}).get("overlay", true)), 4000))
	_ok("cancel: committed replica unchanged and the iPad document rolled back", _child_has(committed) and s.authored_hash() == committed)
	# --- E2E-10 background mid-stroke
	_act("tool_begin", 2.0, -6.0)
	for i in 10:
		_act("tool_move", 2.0 + i * 0.1, -6.0)
		await tree.create_timer(0.066).timeout
	s._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_ok("background: child overlay disappears and committed state stays", await _until(func() -> bool: return not bool(_status().get("session", {}).get("overlay", true)), 4000) and _child_has(committed))
	# --- E2E-10 drop the connection mid-stroke; the iPad keeps editing locally
	s.tools.set_tool("raise")
	_act("tool_begin", 3.0, -9.0)
	for i in 8:
		_act("tool_move", 3.0 + i * 0.1, -9.0)
		await tree.create_timer(0.066).timeout
	link.socket._peer.close()
	_ok("drop: sender notices the loss", await _until(func() -> bool: return not link.is_ready(), 6000))
	_act("tool_move", 4.5, -9.0)
	_act("tool_end", 5.0, -9.0)
	var local := s.authored_hash()
	_ok("drop: the stroke committed locally (iPad edit preserved)", local != committed and s.document.document_revision > 0)
	_ok("drop: reconnect resumes and the child catches up to the exact hash", await _until(func() -> bool: return link.is_ready() and _child_has(local), 30000))
	_ok("drop: child overlay cleared", not bool(_status().get("session", {}).get("overlay", true)))
	# --- E2E-11 live hostile traffic against the real child
	var hash := s.authored_hash()
	var tr := link.socket.transport
	tr.send_text("not json")
	tr.send_text("{\"protocol\":\"world-painter-live\"}")
	tr.send_binary(PackedByteArray([0x57, 0x50, 0x42, 0x31, 1, 2, 3]))
	await tree.create_timer(0.8).timeout
	_ok("hostile frames: child replica unchanged", _child_has(hash))
	_stroke_commit("raise", 0.0, 2.0, -12.0)
	var hh := s.authored_hash()
	_ok("session still works after hostile input", await _until(func() -> bool: return _child_has(hh), 10000))
	# --- E2E-17: an unpaired / wrongly paired peer cannot send a world to the real child
	var intruder := LivePeerSocket.new()
	tree.root.add_child(intruder)
	_ok("intruder connect call accepted", intruder.connect_to("127.0.0.1", int(_status().listener.port), false, "ab".repeat(32)) == "")
	_ok("intruder with a wrong pairing token is refused", await _until(func() -> bool: return intruder.state == LivePeerSocket.State.REJECTED or intruder.state == LivePeerSocket.State.IDLE, 8000) and not intruder.is_ready())
	intruder.disconnect_link(true)
	tree.root.remove_child(intruder)
	intruder.free()
	_ok("the paired session and the child's replica are untouched by the intruder", link.is_ready() and _child_has(s.authored_hash()))
	# --- measurements
	var acks: Array[float] = []
	for i in 200:
		_stroke_commit("raise", -12.0 + float(i % 20) * 0.3, -11.0 + float(i % 20) * 0.3, 10.0 + float(i % 7) * 0.2)
		var t0 := Time.get_ticks_usec()
		var rev := s.document.document_revision
		await _until(func() -> bool: return int(link.sender.stats.acked_revision) >= rev, 5000)
		acks.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	_ok("200 commits acknowledged", int(link.sender.stats.acked_revision) == s.document.document_revision)
	print("LIVE_METRIC commit_ack_ms n=%d p50=%.1f p95=%.1f max=%.1f" % [acks.size(), _pct(acks, 0.5), _pct(acks, 0.95), _pct(acks, 1.0)])
	var rtts: Array[float] = []
	link.socket.ping_msec = 40
	var last_pings := int(link.socket.stats.pings)
	s.tools.set_tool("raise")
	var strokes := 0
	var t_end := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < t_end and rtts.size() < 240:
		_act("tool_begin", -12.0, 6.0 - strokes * 0.1)
		for i in 14:
			_act("tool_move", -12.0 + i * 0.4, 6.0 - strokes * 0.1)
			await tree.create_timer(0.066).timeout
			if int(link.socket.stats.pings) != last_pings and link.socket.rtt_msec >= 0.0:
				last_pings = int(link.socket.stats.pings)
				rtts.append(link.socket.rtt_msec)
		s.cancel_active()
		strokes += 1
	print("LIVE_METRIC provisional_surrogate_ping_rtt_ms n=%d p50=%.1f p95=%.1f max=%.1f previews_sent=%d strokes=%d" % [rtts.size(), _pct(rtts, 0.5), _pct(rtts, 0.95), _pct(rtts, 1.0), int(link.sender.stats.previews), strokes])
	_ok("at least 200 provisional-surrogate samples", rtts.size() >= 200)
	# --- E2E-12 isolation
	link.disconnect_link(true)
	launcher.stop()
	_ok("preview isolation: nothing under res:// changed during the session", ProjectFingerprint.of("res://") == fingerprint_before)


func _ctl(name: String) -> String:
	return OS.get_environment("WP_ACC_CTL").path_join(name)


func _wait_ctl(name: String, timeout_ms: int = 240000) -> bool:
	return await _until(func() -> bool: return FileAccess.file_exists(_ctl(name)), timeout_ms)


func _put_ctl(name: String, data: Dictionary) -> void:
	var f := FileAccess.open(_ctl(name), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


func _edit_and_ack(tag: String, place_object: bool) -> Dictionary:
	_stroke_commit("raise", -3.0, 3.0, -14.0 + float(tag.length()))
	if place_object:
		var ids: Array = s.document.assets.ids()
		for id: String in ids:
			if not s.document.assets.get_binding(id).is_bundled():
				s.tools.begin_drop(LibrarySelection.remote(id))
				var pos := s.rig.get_camera().unproject_position(Vector3(12.0, s.document.sample_height(12.0, 6.0), 6.0))
				s.tools.update_drop(pos, false)
				s.tools.finish_drop(pos, false)
				break
	var rev := s.document.document_revision
	await _until(func() -> bool: return int(link.sender.stats.acked_revision) >= rev, 10000)
	return {"hash": s.authored_hash(), "revision": rev, "objects": s.document.objects.size()}


## iPad side of the Apply composition (E2E-13/14/15): the consumer's editor process owns the preview child + Apply.
func test_apply_composition_sender() -> void:
	if not _enabled("apply"):
		return
	await _setup_world(false)
	_ok("pairing details published by the consumer editor", await _wait_ctl("pairing.json", 120000))
	var pairing: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_ctl("pairing.json")))
	link = PreviewLink.new()
	tree.root.add_child(link)
	link.setup(s)
	_ok("iPad paired with the consumer's preview child", link.connect_to("127.0.0.1", int(pairing.port), false, str(pairing.token)) == "")
	_ok("snapshot acknowledged by the child", await _until(func() -> bool: return link.sender.baseline_acked() and int(link.sender.stats.acked_revision) == s.document.document_revision, 60000))
	_put_ctl("ipad_ready1.json", {"hash": s.authored_hash(), "revision": s.document.document_revision, "objects": s.document.objects.size()})
	_ok("consumer froze + reviewed", await _wait_ctl("driver_frozen1.json"))
	_put_ctl("ipad_edited1.json", await _edit_and_ack("e1", true))
	_ok("consumer applied generation 1", await _wait_ctl("driver_apply1_done.json"))
	_put_ctl("ipad_edited2.json", await _edit_and_ack("e2", false))
	_ok("consumer modified the generated content", await _wait_ctl("driver_modified.json"))
	_put_ctl("ipad_edited3.json", await _edit_and_ack("e3", false))
	_ok("consumer ready for the crash series", await _wait_ctl("driver_crash_ready.json"))
	_put_ctl("ipad_edited4.json", await _edit_and_ack("e4", false))
	_ok("consumer finished", await _wait_ctl("driver_done.json", 600000))
	_ok("consumer reported no failed step", int(JSON.parse_string(FileAccess.get_file_as_string(_ctl("driver_done.json"))).failed) == 0)
