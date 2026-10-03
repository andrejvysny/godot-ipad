extends TestCase
## LiveListener authentication paths over a real loopback WebSocket (ADR 0015 L2, ADR 0016 P6): bad, expired and
## reused tokens, late and oversized hello, binary before auth, pending cap, second writer, credential resume.

const SESSION := "0123456789abcdef0123456789abcdef"
const OTHER_SESSION := "fedcba9876543210fedcba9876543210"

var listener: LiveListener
var probes: Array[WsProbe] = []
var authed: Array = []
var closed: Array[String] = []


func before_each() -> void:
	listener = LiveListener.new()
	listener.peer_authenticated.connect(func(id: String, resumed: bool) -> void: authed.append([id, resumed]))
	listener.peer_closed.connect(func(reason: String) -> void: closed.append(reason))
	tree.root.add_child(listener)


func after_each() -> void:
	listener.stop()
	tree.root.remove_child(listener)
	listener.free()
	probes.clear()


func _start() -> void:
	assert_empty_string(listener.listen(0, "127.0.0.1"), "listen")


func _probe() -> WsProbe:
	var p := WsProbe.new()
	assert_true(p.connect_to(listener.port()), "connect")
	probes.append(p)
	return p


## Runs frames, polling every probe, until `cond` holds or `timeout_ms` passes.
func _until(cond: Callable, timeout_ms: int = 4000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		for p in probes:
			p.poll()
		if cond.call():
			return true
		await tree.process_frame
	return false


func _authenticate(p: WsProbe, auth: Dictionary, session: String = SESSION) -> void:
	await _until(func() -> bool: return p.is_open())
	p.send_text(WsProbe.hello(session, auth))


func _token_auth() -> Dictionary:
	return {"pairing_token": listener.pairing_info().token}


func test_pairing_token_authenticates_and_issues_credential() -> void:
	_start()
	var token := str(listener.pairing_info().token)
	assert_eq(token.length(), 64, "token is 32 bytes hex")
	var p := _probe()
	await _authenticate(p, {"pairing_token": token})
	assert_true(await _until(func() -> bool: return not p.payload_of("hello_result").is_empty()), "hello_result")
	var r := p.payload_of("hello_result")
	assert_true(bool(r.accepted), "accepted")
	assert_true(LiveIds.is_hash(r.session_credential), "credential")
	assert_eq(authed, [[SESSION, false]], "authenticated once, not resumed")
	assert_eq(listener.pairing_info().state, "used", "token consumed")


func test_bad_token_is_rejected_and_token_survives() -> void:
	_start()
	var p := _probe()
	await _authenticate(p, {"pairing_token": LiveIds.new_secret()})
	assert_true(await _until(func() -> bool: return p.is_closed()), "peer closed")
	assert_false(bool(p.payload_of("hello_result").get("accepted", true)), "rejected")
	assert_true(authed.is_empty(), "nobody authenticated")
	assert_eq(listener.pairing_info().state, "valid", "a bad guess does not burn the token")
	var good := _probe()
	await _authenticate(good, _token_auth())
	assert_true(await _until(func() -> bool: return authed.size() == 1), "real token still works")


func test_many_bad_attempts_revoke_the_token() -> void:
	_start()
	for i in LiveListener.MAX_BAD_ATTEMPTS:
		var p := _probe()
		await _authenticate(p, {"pairing_token": LiveIds.new_secret()})
		await _until(func() -> bool: return p.is_closed())
	assert_eq(listener.pairing_info().state, "revoked", "token revoked")


func test_expired_token_is_rejected() -> void:
	listener.pairing_ttl_msec = 50
	_start()
	var token := str(listener.pairing_info().token)
	await _until(func() -> bool: return false, 120)
	assert_eq(listener.pairing_info().state, "expired", "expired")
	var p := _probe()
	await _authenticate(p, {"pairing_token": token})
	assert_true(await _until(func() -> bool: return p.is_closed()), "closed")
	assert_true(authed.is_empty(), "expired token must not authenticate")


func test_token_cannot_be_reused() -> void:
	_start()
	var token := str(listener.pairing_info().token)
	var first := _probe()
	await _authenticate(first, {"pairing_token": token})
	await _until(func() -> bool: return authed.size() == 1)
	listener.close_writer()
	await _until(func() -> bool: return not listener.writer_connected())
	var second := _probe()
	await _authenticate(second, {"pairing_token": token}, OTHER_SESSION)
	assert_true(await _until(func() -> bool: return second.is_closed()), "second closed")
	assert_eq(authed.size(), 1, "the token worked once")


func test_late_hello_closes_the_peer() -> void:
	listener.auth_deadline_msec = 300
	_start()
	var p := _probe()
	assert_true(await _until(func() -> bool: return p.is_closed(), 3000), "closed at the deadline")
	assert_eq(listener.pending_count(), 0, "no pending peer left")


func test_oversize_pre_auth_message_closes_the_peer() -> void:
	_start()
	var p := _probe()
	await _until(func() -> bool: return p.is_open())
	p.send_text("x".repeat(LiveEnvelope.MAX_PRE_AUTH_BYTES + 1))
	assert_true(await _until(func() -> bool: return p.is_closed()), "closed")
	assert_true(authed.is_empty(), "no session")


func test_binary_before_auth_closes_the_peer() -> void:
	_start()
	var p := _probe()
	await _until(func() -> bool: return p.is_open())
	p.send_bytes(PackedByteArray([1, 2, 3]))
	assert_true(await _until(func() -> bool: return p.is_closed()), "closed")
	assert_eq(listener.stats.rejected, 1, "counted as a rejection")


func test_non_hello_before_auth_closes_the_peer() -> void:
	_start()
	var p := _probe()
	await _until(func() -> bool: return p.is_open())
	p.send_text(LiveEnvelope.build("ping", SESSION, LiveIds.ZERO_ID, {"nonce": 1}).text)
	assert_true(await _until(func() -> bool: return p.is_closed()), "closed")


func test_pending_peers_are_capped() -> void:
	listener.auth_deadline_msec = 2000
	_start()
	for i in 7:
		_probe()
	await _until(func() -> bool: return listener.stats.accepted >= 7)
	assert_true(listener.pending_count() <= LiveListener.MAX_PENDING, "pending %d" % listener.pending_count())
	assert_true(listener.stats.refused >= 3, "extra peers refused: %d" % listener.stats.refused)


func test_second_writer_is_rejected_until_the_first_closes() -> void:
	_start()
	var first := _probe()
	await _authenticate(first, _token_auth())
	await _until(func() -> bool: return authed.size() == 1)
	var credential := str(first.payload_of("hello_result").get("session_credential", ""))
	# A valid pairing token while a writer is connected: writer_busy, token not consumed.
	listener.refresh_pairing()
	var second := _probe()
	await _authenticate(second, _token_auth(), OTHER_SESSION)
	assert_true(await _until(func() -> bool: return second.is_closed()), "second closed")
	assert_true(second.types().has("error"), "error envelope")
	assert_eq(second.payload_of("error").get("code", ""), "writer_busy", "writer_busy code")
	assert_eq(listener.pairing_info().state, "valid", "the token was not consumed")
	# The same sender resuming while its old connection is still up is also a second writer.
	var third := _probe()
	await _authenticate(third, {"session_credential": credential})
	assert_true(await _until(func() -> bool: return third.is_closed()), "third closed")
	assert_eq(authed.size(), 1, "still one writer")
	listener.close_writer()
	await _until(func() -> bool: return not listener.writer_connected())
	var fourth := _probe()
	await _authenticate(fourth, {"session_credential": credential})
	assert_true(await _until(func() -> bool: return authed.size() == 2), "resume after the writer left")
	assert_eq(authed[1], [SESSION, true], "resumed")


func test_credential_resume_requires_the_paired_session_and_credential() -> void:
	_start()
	var first := _probe()
	await _authenticate(first, _token_auth())
	await _until(func() -> bool: return authed.size() == 1)
	var credential := str(first.payload_of("hello_result").session_credential)
	listener.close_writer()
	await _until(func() -> bool: return not listener.writer_connected())
	var wrong_cred := _probe()
	await _authenticate(wrong_cred, {"session_credential": LiveIds.new_secret()})
	assert_true(await _until(func() -> bool: return wrong_cred.is_closed()), "wrong credential closed")
	var wrong_session := _probe()
	await _authenticate(wrong_session, {"session_credential": credential}, OTHER_SESSION)
	assert_true(await _until(func() -> bool: return wrong_session.is_closed()), "wrong session closed")
	assert_eq(authed.size(), 1, "neither authenticated")
	var good := _probe()
	await _authenticate(good, {"session_credential": credential})
	assert_true(await _until(func() -> bool: return authed.size() == 2), "resume")
	listener.stop()
	assert_false(listener.has_credential(), "stop revokes the credential")


func test_idle_writer_is_dropped() -> void:
	listener.idle_drop_msec = 300
	_start()
	var p := _probe()
	await _authenticate(p, _token_auth())
	await _until(func() -> bool: return authed.size() == 1)
	assert_true(await _until(func() -> bool: return not listener.writer_connected(), 3000), "idle writer dropped")
	assert_eq(closed.size(), 1, "peer_closed emitted")


func test_non_loopback_bind_needs_the_insecure_flag() -> void:
	assert_error_contains(listener.listen(0, "0.0.0.0"), "allow_insecure_lan", "refused")
	assert_false(listener.is_listening(), "not listening")
	assert_empty_string(listener.listen(0, "0.0.0.0", true), "allowed with the flag")
	assert_true(listener.is_listening(), "listening")
