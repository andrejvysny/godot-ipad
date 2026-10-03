class_name LiveWsTransport
extends LiveTransport
## LiveTransport over a connected WebSocketPeer (ADR 0016 P5): text and binary messages, with the peer's own
## outbound buffer as the backpressure signal. Owns no polling; the node that owns the peer polls it.

const DEFAULT_PORT := 8666

var peer: WebSocketPeer


## Hosts whose cleartext traffic never leaves the machine (shared by listener and client: only this file is on the iPad).
static func is_loopback(address: String) -> bool:
	return address == "localhost" or address == "::1" or address.begins_with("127.")


func attach(p_peer: WebSocketPeer) -> void:
	peer = p_peer


func detach() -> void:
	peer = null


func is_open() -> bool:
	return peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func backlog_bytes() -> int:
	return peer.get_current_outbound_buffered_amount() if peer != null else 0


func send_text(text: String) -> bool:
	return is_open() and peer.send_text(text) == OK


func send_binary(data: PackedByteArray) -> bool:
	return is_open() and peer.send(data, WebSocketPeer.WRITE_MODE_BINARY) == OK
