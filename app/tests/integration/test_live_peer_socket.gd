extends TestCase
## LivePeerSocket (iPad side of the link, ADR 0016 P5/P6): cleartext guard, refused pairing, keep-alive timers and
## reconnect with the session credential.

var listener: LiveListener
var driver: LiveReceiverDriver
var socket: LivePeerSocket


func before_each() -> void:
	listener = LiveListener.new()
	tree.root.add_child(listener)
	assert_empty_string(listener.listen(0), "listen")
	socket = LivePeerSocket.new()
	tree.root.add_child(socket)


func after_each() -> void:
	socket.disconnect_link(true)
	listener.stop()
	for n: Node in [socket, driver, listener]:
		if n != null:
			tree.root.remove_child(n)
			n.free()
	driver = null


func _attach_driver() -> void:
	driver = LiveReceiverDriver.new()
	tree.root.add_child(driver)
	driver.setup(listener, AssetCatalog.load_from()[0], scratch_dir() + "/receiver")


func _until(cond: Callable, timeout_ms: int = 6000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await tree.process_frame
	return false


func _token() -> String:
	return str(listener.pairing_info().token)


func test_cleartext_to_a_lan_host_needs_the_flag_and_tokens_are_validated() -> void:
	assert_error_contains(socket.connect_to("192.168.1.20", 8666, false, _token()), "insecure", "no flag")
	assert_error_contains(socket.connect_to("127.0.0.1", 8666, false, "abc"), "64", "bad token format")
	assert_error_contains(socket.connect_to("127.0.0.1", 8666, false, ""), "token", "no token and no credential")
	assert_error_contains(socket.connect_to("", 8666, false, _token()), "host", "no host")
	assert_error_contains(socket.connect_to("127.0.0.1", 70000, false, _token()), "port", "bad port")
	assert_eq(socket.state, LivePeerSocket.State.IDLE, "never started")


func test_wrong_token_is_refused_and_not_retried() -> void:
	assert_empty_string(socket.connect_to("127.0.0.1", listener.port(), false, LiveIds.new_secret()), "connect")
	assert_true(await _until(func() -> bool: return socket.state == LivePeerSocket.State.REJECTED), "refused")
	var connects := int(socket.stats.connects)
	await _until(func() -> bool: return false, 1200)
	assert_eq(int(socket.stats.connects), connects, "no reconnect loop with a refused token")
	assert_false(socket.has_credential(), "no credential")


func test_pings_measure_the_round_trip() -> void:
	_attach_driver()
	socket.ping_msec = 100
	assert_empty_string(socket.connect_to("127.0.0.1", listener.port(), false, _token()), "connect")
	assert_true(await _until(func() -> bool: return socket.is_ready()), "ready")
	assert_true(await _until(func() -> bool: return socket.rtt_msec >= 0.0), "pong received")
	assert_false(socket.is_unresponsive(), "responsive")


func test_silent_receiver_makes_the_link_unresponsive_then_drops_and_resumes() -> void:
	listener.idle_drop_msec = 60000  # the receiver side stays, it just never answers
	socket.ping_msec = 100
	socket.unresponsive_msec = 400
	socket.drop_msec = 900
	var flags: Array[bool] = []
	socket.unresponsive_changed.connect(func(on: bool) -> void: flags.append(on))
	var lost: Array[String] = []
	socket.session_lost.connect(func(reason: String) -> void: lost.append(reason))
	assert_empty_string(socket.connect_to("127.0.0.1", listener.port(), false, _token()), "connect")
	assert_true(await _until(socket.is_ready), "ready")
	assert_true(await _until(func() -> bool: return flags.has(true)), "unresponsive after the silence")
	assert_true(await _until(func() -> bool: return not lost.is_empty()), "dropped")
	assert_eq(int(socket.stats.drops), 1, "one drop counted")
	assert_true(socket.has_credential(), "the credential survives for the resume")
	assert_true(socket.state == LivePeerSocket.State.BACKOFF or socket.state == LivePeerSocket.State.CONNECTING \
			or socket.state == LivePeerSocket.State.AUTHENTICATING, "reconnecting")
