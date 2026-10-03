class_name LiveTransport
extends RefCounted
## Abstract transport the live sender pumps into (ADR 0015 L1). Implementations (the IP-06 WebSocket peer, the
## in-process fake of the tests) move opaque text and binary messages and report how much they still hold, which is
## the sender's only backpressure signal. Nothing here blocks.

## False while no peer is connected; the sender then keeps its queue and spool bounded and waits.
func is_open() -> bool:
	return false


## Bytes accepted but not yet delivered. The sender stops writing while this is at or above its high-water mark.
func backlog_bytes() -> int:
	return 0


## False when the message could not be accepted (the sender retries the same message on its next pump).
func send_text(_text: String) -> bool:
	return false


func send_binary(_data: PackedByteArray) -> bool:
	return false
