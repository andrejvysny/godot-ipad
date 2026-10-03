class_name LivePeerSocket
extends Node
## Sender-side WebSocket client of the live protocol (ADR 0015 L2, ADR 0016 P5/P6). It connects, authenticates with
## `hello` (pairing token on the first connect, the in-memory session credential afterwards; never in the URL),
## reconnects with backoff, and keeps the link alive with ping every `ping_msec`, "unresponsive" after
## `unresponsive_msec` without traffic and a drop after `drop_msec`. Messages other than hello_result/pong are
## handed to the owner through text_received. `transport` is the LiveTransport the sender pumps into.
## Cleartext ws:// to a non-loopback host needs allow_insecure_lan.

signal state_changed(state: int)
signal session_ready(session_id: String, resumed: bool)
signal session_lost(reason: String)
signal text_received(text: String)
signal unresponsive_changed(unresponsive: bool)

enum State { IDLE, CONNECTING, AUTHENTICATING, READY, BACKOFF, REJECTED }

const BACKOFF_MSEC: Array[int] = [500, 1000, 2000, 4000, 8000]
const AUTH_TIMEOUT_MSEC := 5000
const APP_NAME := "world-painter-ipad"
const CAPABILITIES: Array[String] = ["blob", "preview"]

var host := "127.0.0.1"
var port := 8666
var allow_insecure_lan := false
var ping_msec := 2000
var unresponsive_msec := 6000
var drop_msec := 10000
var transport := LiveWsTransport.new()
var state := State.IDLE
var status_text := ""
var rtt_msec := -1.0
var stats := {"connects": 0, "reconnects": 0, "pings": 0, "drops": 0}

var _peer: WebSocketPeer
var _token := ""
var _credential := ""
var _session_id := ""
var _attempt := 0
var _retry_at := 0
var _state_since := 0
var _last_rx := 0
var _next_ping := 0
var _ping_sent_at := 0
var _nonce := 0
var _unresponsive := false


## "" or an error. `token` is the 64-hex pairing token; empty resumes with the in-memory credential.
func connect_to(p_host: String, p_port: int, p_allow_insecure_lan: bool, token: String = "") -> String:
	var t := token.strip_edges().to_lower()
	if t != "" and not LiveIds.is_hash(t):
		return "The pairing token is 64 lowercase hex characters."
	if t == "" and _credential == "":
		return "Enter the pairing token shown on the desktop."
	if p_port < 1 or p_port > 65535 or p_host.strip_edges() == "":
		return "Enter the desktop's host and port."
	if not LiveWsTransport.is_loopback(p_host.strip_edges()) and not p_allow_insecure_lan:
		return "Cleartext ws:// to a non-loopback host needs 'Allow insecure LAN'."
	_close_peer()
	host = p_host.strip_edges()
	port = p_port
	allow_insecure_lan = p_allow_insecure_lan
	if t != "":
		_token = t
		_credential = ""
		_session_id = LiveIds.new_id()
	_attempt = 0
	_open()
	return ""


## Disconnects. `forget` also drops the session credential (a new pairing token is needed afterwards).
func disconnect_link(forget: bool = false) -> void:
	var was_ready := state == State.READY
	_close_peer()
	_token = ""
	if forget:
		_credential = ""
	_set_state(State.IDLE, "Disconnected")
	if was_ready:
		session_lost.emit("disconnected")


func has_credential() -> bool:
	return _credential != ""


func session_id() -> String:
	return _session_id


func is_ready() -> bool:
	return state == State.READY


func is_unresponsive() -> bool:
	return _unresponsive


# --- Connection -----------------------------------------------------------------------------------

func _open() -> void:
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = 1048576
	_peer.outbound_buffer_size = 4194304
	transport.attach(_peer)
	var url := "ws://%s:%d" % [host if not host.contains(":") else "[%s]" % host, port]
	if _peer.connect_to_url(url) != OK:
		_lost("cannot connect")
		return
	stats.connects += 1
	_set_state(State.CONNECTING, "Connecting to %s:%d" % [host, port])


func _close_peer() -> void:
	if _peer != null:
		_peer.close(1000, "closing")
		_peer.poll()
	_peer = null
	transport.detach()
	_set_unresponsive(false)


func _set_state(s: State, text: String = "") -> void:
	state = s
	_state_since = Time.get_ticks_msec()
	if text != "":
		status_text = text
	state_changed.emit(int(s))


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if state == State.BACKOFF and now >= _retry_at:
		stats.reconnects += 1
		_open()
	if _peer == null:
		return
	_peer.poll()
	var ws_state := _peer.get_ready_state()
	if ws_state == WebSocketPeer.STATE_CLOSED:
		if state == State.AUTHENTICATING:
			_read_hello_result(now)  # a refusal arrives together with the close
		if _peer != null:
			_lost("connection closed")
		return
	match state:
		State.CONNECTING:
			if ws_state == WebSocketPeer.STATE_OPEN:
				_send_hello(now)
			elif now - _state_since > AUTH_TIMEOUT_MSEC:
				_lost("connect timeout")
		State.AUTHENTICATING:
			_read_hello_result(now)
			if state == State.AUTHENTICATING and now - _state_since > AUTH_TIMEOUT_MSEC:
				_lost("no answer to hello")
		State.READY:
			_read_ready(now)
			if state == State.READY:
				_keepalive(now)


func _send_hello(now: int) -> void:
	var auth := {"session_credential": _credential} if _credential != "" else {"pairing_token": _token}
	var built := LiveEnvelope.build("hello", _session_id, LiveIds.ZERO_ID, {"role": "sender",
		"protocol_versions": [LiveEnvelope.VERSION], "auth": auth, "app": APP_NAME, "capabilities": CAPABILITIES})
	if not built.ok or _peer.send_text(built.text) != OK:
		_lost("cannot send hello")
		return
	_last_rx = now
	_set_state(State.AUTHENTICATING, "Authenticating")


func _read_hello_result(now: int) -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var data := _peer.get_packet()
		if not _peer.was_string_packet():
			continue
		var parsed := LiveEnvelope.parse(data.get_string_from_utf8(), true, _session_id)
		if not parsed.ok or parsed.envelope.type != "hello_result":
			continue
		var p: Dictionary = parsed.envelope.payload
		if bool(p.accepted):
			_accepted(p, now)
		else:
			_refused(str(p.get("reason", "rejected")))
		return


func _accepted(p: Dictionary, now: int) -> void:
	var resumed := _credential != ""
	_credential = str(p.get("session_credential", _credential))
	_token = ""
	_attempt = 0
	_last_rx = now
	_next_ping = now + ping_msec
	_set_state(State.READY, "Connected")
	session_ready.emit(_session_id, resumed)


func _refused(reason: String) -> void:
	if reason == "writer_busy":
		_lost("the desktop already has a sender connected")
		return
	var was_credential := _credential != ""
	_close_peer()
	if was_credential:
		_credential = ""
	_token = ""
	_set_state(State.REJECTED, "The desktop refused the pairing (%s). Enter a new token." % reason)


func _read_ready(now: int) -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var data := _peer.get_packet()
		_last_rx = now
		_set_unresponsive(false)
		if not _peer.was_string_packet():
			continue
		var text := data.get_string_from_utf8()
		if _is_pong(text, now):
			continue
		text_received.emit(text)


func _is_pong(text: String, now: int) -> bool:
	if not text.contains("pong"):
		return false
	var parsed := LiveEnvelope.parse(text, true, _session_id)
	if not parsed.ok or parsed.envelope.type != "pong":
		return false
	if int(parsed.envelope.payload.nonce) == _nonce:
		rtt_msec = float(now - _ping_sent_at)
	return true


func _keepalive(now: int) -> void:
	if now >= _next_ping:
		_next_ping = now + ping_msec
		_nonce += 1
		_ping_sent_at = now
		var built := LiveEnvelope.build("ping", _session_id, LiveIds.ZERO_ID, {"nonce": _nonce})
		if built.ok:
			transport.send_text(built.text)
			stats.pings += 1
	var silent := now - _last_rx
	if silent >= drop_msec:
		stats.drops += 1
		_lost("no answer for %d s" % (drop_msec / 1000))
	elif silent >= unresponsive_msec:
		_set_unresponsive(true)


func _set_unresponsive(on: bool) -> void:
	if on != _unresponsive:
		_unresponsive = on
		unresponsive_changed.emit(on)


## The connection ended: reconnect with backoff (the credential, once issued, makes it a resume).
func _lost(reason: String) -> void:
	var was_ready := state == State.READY
	_close_peer()
	if _token == "" and _credential == "":
		_set_state(State.IDLE, reason)
	else:
		_retry_at = Time.get_ticks_msec() + BACKOFF_MSEC[mini(_attempt, BACKOFF_MSEC.size() - 1)]
		_attempt += 1
		_set_state(State.BACKOFF, "%s; retrying" % reason)
	if was_ready:
		session_lost.emit(reason)
