class_name BrokerChannel
extends RefCounted
## One end of the loopback broker connection between the editor plugin and the preview child (ADR 0016 P3):
## frames are u32 little-endian length + UTF-8 JSON object, at most 64 KiB (8 KiB before authentication).
## poll() returns the complete messages received; a malformed or oversized frame sets `error` and the owner closes.

const MAX_FRAME := 65536
const MAX_PRE_AUTH_FRAME := 8192

var stream: StreamPeerTCP
var authenticated := false
var error := ""

var _buffer := PackedByteArray()


func _init(p_stream: StreamPeerTCP) -> void:
	stream = p_stream


## TCP connected or still connecting.
func is_alive() -> bool:
	stream.poll()
	var s := stream.get_status()
	return s == StreamPeerTCP.STATUS_CONNECTED or s == StreamPeerTCP.STATUS_CONNECTING


func is_connected_now() -> bool:
	stream.poll()
	return stream.get_status() == StreamPeerTCP.STATUS_CONNECTED


func poll() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	stream.poll()
	if error != "" or stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return out
	var n := stream.get_available_bytes()
	if n > 0:
		var got := stream.get_data(mini(n, 4 * MAX_FRAME))
		if got[0] == OK:
			_buffer.append_array(got[1] as PackedByteArray)
	var cap := MAX_FRAME if authenticated else MAX_PRE_AUTH_FRAME
	while error == "" and _buffer.size() >= 4:
		var length := _buffer.decode_u32(0)
		if length == 0 or length > cap:
			error = "frame of %d bytes is outside 1..%d" % [length, cap]
			break
		if _buffer.size() < 4 + length:
			break
		var parsed: Variant = JSON.parse_string(_buffer.slice(4, 4 + length).get_string_from_utf8())
		_buffer = _buffer.slice(4 + length)
		if typeof(parsed) != TYPE_DICTIONARY or typeof((parsed as Dictionary).get("type")) != TYPE_STRING:
			error = "frame is not a typed JSON object"
			break
		out.append(parsed)
		cap = MAX_FRAME if authenticated else MAX_PRE_AUTH_FRAME
	if error == "" and _buffer.size() > cap + 4:
		error = "buffered data exceeds the frame cap"
	return out


## False when the message is too large or the stream is gone.
func send(message: Dictionary) -> bool:
	if stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	var body := JSON.stringify(message).to_utf8_buffer()
	if body.size() > MAX_FRAME:
		return false
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, body.size())
	frame.append_array(body)
	return stream.put_data(frame) == OK


func close() -> void:
	stream.disconnect_from_host()
