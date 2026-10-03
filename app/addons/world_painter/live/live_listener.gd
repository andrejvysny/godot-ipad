class_name LiveListener
extends Node
## Receiver-side WebSocket listener of the live protocol (ADR 0015 L2, ADR 0016 P1/P6): accepts TCP, upgrades to
## WebSocket, authenticates and hands exactly one writer's messages to its owner.
## - Pairing token: 32 random bytes hex, single use, expires after `pairing_ttl_msec`; it is only ever read from the
##   first `hello` text message. After success a random in-memory `session_credential` lets the same sender resume
##   until stop(). A bad token never consumes the token; MAX_BAD_ATTEMPTS bad attempts revoke it.
## - Unauthenticated peers: at most MAX_PENDING, `auth_deadline_msec` to send a valid hello of at most 8 KiB, and a
##   binary frame closes the peer. Binding anything but loopback requires allow_insecure_lan (cleartext, ADR 0015 L2).
## - One writer: a second authenticated hello gets `writer_busy` until the first connection is closed or idle for
##   `idle_drop_msec`.
## Nothing here parses blobs or world data; text/binary messages of the writer are emitted as signals.

signal peer_authenticated(session_id: String, resumed: bool)
signal text_received(text: String)
signal binary_received(data: PackedByteArray)
signal peer_closed(reason: String)
signal pairing_changed()

const MAX_PENDING := 4
const MAX_BAD_ATTEMPTS := 8
const INBOUND_BUFFER := 1048576
const OUTBOUND_BUFFER := 4194304
const MAX_PACKETS_PER_FRAME := 64
const MAX_BYTES_PER_FRAME := 8388608
const CLOSE_GRACE_MSEC := 2000
const REJECT_LINGER_MSEC := 250
const LIMITS := {"max_text_bytes": 65536, "pre_auth_text_bytes": 8192, "max_chunk_bytes": 262144}

var auth_deadline_msec := 5000
var pairing_ttl_msec := 300000
var idle_drop_msec := 10000
var allow_insecure_lan := false
var profile_name := "default"
var stats := {"accepted": 0, "authenticated": 0, "rejected": 0, "refused": 0, "writer_busy": 0}

var _server := TCPServer.new()
var _pending: Array[Dictionary] = []  # {peer, born}
var _closing: Array[Dictionary] = []  # {peer, until}
var _writer: WebSocketPeer
var _writer_rx_msec := 0
var _token := ""
var _token_expires := 0
var _token_state := "none"  # none | valid | used | expired | revoked
var _bad_attempts := 0
var _credential := ""
var _session_id := ""
var _bind_address := ""


## "" or an error. Port 0 picks a free port (see port()).
func listen(port: int, bind_address: String = "127.0.0.1", p_allow_insecure_lan: bool = false) -> String:
	allow_insecure_lan = p_allow_insecure_lan
	if not LiveWsTransport.is_loopback(bind_address) and not allow_insecure_lan:
		return "Refusing to listen on %s: a cleartext non-loopback listener needs allow_insecure_lan." % bind_address
	if _server.is_listening():
		return "already listening"
	var err := _server.listen(port, bind_address)
	if err != OK:
		return "cannot listen on %s:%d (error %d)" % [bind_address, port, err]
	_bind_address = bind_address
	refresh_pairing()
	return ""


func is_listening() -> bool:
	return _server.is_listening()


func port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0


func bind_address() -> String:
	return _bind_address


## Closes every connection, revokes the token and the session credential.
func stop() -> void:
	_close_writer("preview stopped")
	for entry in _pending:
		(entry.peer as WebSocketPeer).close(1001, "stopped")
	_pending.clear()
	_server.stop()
	_credential = ""
	_session_id = ""
	_token = ""
	_token_state = "none"
	pairing_changed.emit()


# --- Pairing ------------------------------------------------------------------------------------

## New single-use token valid for pairing_ttl_msec. Does not touch an established session.
func refresh_pairing() -> String:
	_token = LiveIds.new_secret()
	_token_expires = Time.get_ticks_msec() + pairing_ttl_msec
	_token_state = "valid"
	_bad_attempts = 0
	pairing_changed.emit()
	return _token


## {state, token (only while valid), expires_in_ms}.
func pairing_info() -> Dictionary:
	_expire_token()
	var valid := _token_state == "valid"
	return {"state": _token_state, "token": _token if valid else "",
		"expires_in_ms": maxi(0, _token_expires - Time.get_ticks_msec()) if valid else 0}


func has_credential() -> bool:
	return _credential != ""


func writer_connected() -> bool:
	return _writer != null


func session_id() -> String:
	return _session_id


func pending_count() -> int:
	return _pending.size()


func _expire_token() -> void:
	if _token_state == "valid" and Time.get_ticks_msec() >= _token_expires:
		_token = ""
		_token_state = "expired"
		pairing_changed.emit()


# --- Frame loop -----------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	_expire_token()
	if _server.is_listening():
		_accept()
	_poll_pending(now)
	_poll_writer(now)
	_poll_closing(now)


func _accept() -> void:
	while _server.is_connection_available():
		var stream := _server.take_connection()
		stats.accepted += 1
		if _pending.size() >= MAX_PENDING:
			stats.refused += 1
			stream.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = INBOUND_BUFFER
		ws.outbound_buffer_size = OUTBOUND_BUFFER
		if ws.accept_stream(stream) != OK:
			stream.disconnect_from_host()
			continue
		_pending.append({"peer": ws, "born": Time.get_ticks_msec()})


func _poll_pending(now: int) -> void:
	var keep: Array[Dictionary] = []
	for entry in _pending:
		var ws: WebSocketPeer = entry.peer
		ws.poll()
		if _pending_alive(entry, now):
			keep.append(entry)
	_pending = keep


## False once the entry was resolved (authenticated, rejected or dropped) and must leave the pending list.
func _pending_alive(entry: Dictionary, now: int) -> bool:
	var ws: WebSocketPeer = entry.peer
	var state := ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED or state == WebSocketPeer.STATE_CLOSING:
		return false
	if now - int(entry.born) >= auth_deadline_msec:
		_reject(ws, "auth_deadline", "")
		return false
	if state != WebSocketPeer.STATE_OPEN or ws.get_available_packet_count() == 0:
		return true
	var data := ws.get_packet()
	if not ws.was_string_packet():
		_reject(ws, "binary_before_auth", "")
		return false
	if data.size() > LiveEnvelope.MAX_PRE_AUTH_BYTES:
		_reject(ws, "pre_auth_too_large", "")
		return false
	_handle_hello(ws, data.get_string_from_utf8(), now)
	return false


# --- Authentication ---------------------------------------------------------------------------------

func _handle_hello(ws: WebSocketPeer, text: String, now: int) -> void:
	var parsed := LiveEnvelope.parse(text, false)
	if not parsed.ok:
		_reject(ws, "bad_hello", "")
		return
	var env: Dictionary = parsed.envelope
	var p: Dictionary = env.payload
	if p.role != "sender" or not (p.protocol_versions as Array).has(LiveEnvelope.VERSION):
		_reject(ws, "unsupported_hello", env.session_id)
		return
	var auth: Dictionary = p.auth
	var resumed := auth.has("session_credential")
	var ok := _credential_ok(auth.session_credential, env.session_id) if resumed else _token_ok(auth.pairing_token)
	if not ok:
		_bad_attempt()
		_reject(ws, "pairing_failed", env.session_id)
		return
	if _writer != null:
		stats.writer_busy += 1
		_reject(ws, "writer_busy", env.session_id)
		return
	if not resumed:
		_token = ""
		_token_state = "used"
		_credential = LiveIds.new_secret()
		_session_id = env.session_id
		pairing_changed.emit()
	_writer = ws
	_writer_rx_msec = now
	stats.authenticated += 1
	_send_hello_result(ws, env.session_id, {"accepted": true, "session_credential": _credential,
		"limits": LIMITS, "receiver": {"profile": profile_name}})
	peer_authenticated.emit(_session_id, resumed)


func _token_ok(candidate: String) -> bool:
	_expire_token()
	return _token_state == "valid" and _equal_secret(candidate, _token)


func _credential_ok(candidate: String, session: String) -> bool:
	return _credential != "" and session == _session_id and _equal_secret(candidate, _credential)


func _bad_attempt() -> void:
	_bad_attempts += 1
	if _token_state == "valid" and _bad_attempts >= MAX_BAD_ATTEMPTS:
		_token = ""
		_token_state = "revoked"
		pairing_changed.emit()


static func _equal_secret(a: String, b: String) -> bool:
	var x := a.to_utf8_buffer()
	var y := b.to_utf8_buffer()
	if x.size() != y.size():
		return false
	var diff := 0
	for i in x.size():
		diff |= x[i] ^ y[i]
	return diff == 0


## Answers a failed hello (the reason is generic on purpose) and closes the peer. A peer that was answered is closed
## after REJECT_LINGER_MSEC (or when it closes first): Godot drops unread inbound data when the close frame arrives.
func _reject(ws: WebSocketPeer, reason: String, session: String) -> void:
	stats.rejected += 1
	var now := Time.get_ticks_msec()
	var answered := ws.get_ready_state() == WebSocketPeer.STATE_OPEN and LiveIds.is_id(session)
	if answered and _closing.size() < MAX_PENDING * 4:
		_send_hello_result(ws, session, {"accepted": false, "reason": reason})
		if reason == "writer_busy":
			var err := LiveEnvelope.build("error", session, LiveIds.ZERO_ID,
				{"code": "writer_busy", "message": "another sender is connected"})
			if err.ok:
				ws.send_text(err.text)
		_closing.append({"peer": ws, "until": now + CLOSE_GRACE_MSEC, "close_at": now + REJECT_LINGER_MSEC,
			"reason": reason})
		return
	ws.close(1008, reason)
	_closing.append({"peer": ws, "until": now + CLOSE_GRACE_MSEC, "close_at": 0, "reason": reason})


func _send_hello_result(ws: WebSocketPeer, session: String, payload: Dictionary) -> void:
	var built := LiveEnvelope.build("hello_result", session, LiveIds.ZERO_ID, payload)
	if built.ok:
		ws.send_text(built.text)


# --- Writer ------------------------------------------------------------------------------------------

func _poll_writer(now: int) -> void:
	if _writer == null:
		return
	_writer.poll()
	if _writer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_drop_writer("connection closed")
		return
	var packets := 0
	var bytes := 0
	while _writer != null and _writer.get_available_packet_count() > 0 and packets < MAX_PACKETS_PER_FRAME \
			and bytes < MAX_BYTES_PER_FRAME:
		var data := _writer.get_packet()
		_writer_rx_msec = now
		packets += 1
		bytes += data.size()
		if _writer.was_string_packet():
			text_received.emit(data.get_string_from_utf8())
		else:
			binary_received.emit(data)
	if _writer != null and now - _writer_rx_msec >= idle_drop_msec:
		_close_writer("idle")


func send_text(text: String) -> bool:
	return _writer != null and _writer.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and _writer.send_text(text) == OK


func send_binary(data: PackedByteArray) -> bool:
	return _writer != null and _writer.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and _writer.send(data, WebSocketPeer.WRITE_MODE_BINARY) == OK


## Closes the writer's connection; the sender may resume later with its credential.
func close_writer(reason: String = "closed by receiver") -> void:
	_close_writer(reason)


func _close_writer(reason: String) -> void:
	if _writer == null:
		return
	_writer.close(1000, reason)
	_closing.append({"peer": _writer, "until": Time.get_ticks_msec() + CLOSE_GRACE_MSEC, "close_at": 0, "reason": reason})
	_drop_writer(reason)


func _drop_writer(reason: String) -> void:
	if _writer == null:
		return
	_writer = null
	peer_closed.emit(reason)


func _poll_closing(now: int) -> void:
	var keep: Array[Dictionary] = []
	for entry in _closing:
		var ws: WebSocketPeer = entry.peer
		ws.poll()
		if int(entry.close_at) > 0 and now >= int(entry.close_at) and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.close(1008, str(entry.reason))
			entry.close_at = 0
		if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED and now < int(entry.until):
			keep.append(entry)
	_closing = keep


func _exit_tree() -> void:
	if _server.is_listening():
		stop()
