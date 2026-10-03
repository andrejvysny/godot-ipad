class_name WsProbe
extends RefCounted
## Raw WebSocket client for listener tests: connects to a loopback port, sends arbitrary frames and records what the
## server sends back and whether (and why) it closed. Poll it from the test's frame loop.

var peer := WebSocketPeer.new()
var texts: Array[String] = []
var binaries: Array[PackedByteArray] = []
var close_code := -1
var was_open := false


func connect_to(port: int) -> bool:
	peer.inbound_buffer_size = 1048576
	peer.outbound_buffer_size = 1048576
	return peer.connect_to_url("ws://127.0.0.1:%d" % port) == OK


func poll() -> void:
	peer.poll()
	var state := peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		was_open = true
	while peer.get_available_packet_count() > 0:  # data sent just before a close is still readable
		var data := peer.get_packet()
		if peer.was_string_packet():
			texts.append(data.get_string_from_utf8())
		else:
			binaries.append(data)
	if state == WebSocketPeer.STATE_CLOSED and close_code == -1:
		close_code = peer.get_close_code()


func is_open() -> bool:
	return peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_closed() -> bool:
	return peer.get_ready_state() == WebSocketPeer.STATE_CLOSED


func send_text(text: String) -> bool:
	return peer.send_text(text) == OK


func send_bytes(data: PackedByteArray) -> bool:
	return peer.send(data, WebSocketPeer.WRITE_MODE_BINARY) == OK


## Types of the envelopes received so far.
func types() -> Array[String]:
	var out: Array[String] = []
	for t in texts:
		var parsed: Variant = JSON.parse_string(t)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(str((parsed as Dictionary).get("type", "?")))
	return out


## Payload of the first received envelope of `type`, or {}.
func payload_of(type: String) -> Dictionary:
	for t in texts:
		var parsed: Variant = JSON.parse_string(t)
		if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).get("type") == type:
			return (parsed as Dictionary).payload
	return {}


static func hello(session: String, auth: Dictionary, role: String = "sender") -> String:
	var built := LiveEnvelope.build("hello", session, LiveIds.ZERO_ID, {"role": role, "protocol_versions": [1],
		"auth": auth, "app": "probe", "capabilities": ["blob"]})
	return built.text
