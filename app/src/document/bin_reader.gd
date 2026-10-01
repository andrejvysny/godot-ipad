class_name BinReader
extends RefCounted
## Bounds-checked little-endian cursor for scatter.bin / paths.bin. Reading past the end sets
## `error` once and returns zero values, so callers check `error` after each section.

var error: String = ""

var _data: PackedByteArray
var _pos := 0


func _init(data: PackedByteArray) -> void:
	_data = data


func remaining() -> int:
	return _data.size() - _pos


func at_end() -> bool:
	return _pos == _data.size()


func _need(n: int, what: String) -> bool:
	if error != "":
		return false
	if n < 0 or remaining() < n:
		error = "truncated while reading %s" % what
		return false
	return true


func ascii(n: int) -> String:
	if not _need(n, "header"):
		return ""
	var s := _data.slice(_pos, _pos + n).get_string_from_ascii()
	_pos += n
	return s


func u16(what: String) -> int:
	if not _need(2, what):
		return 0
	var v := _data.decode_u16(_pos)
	_pos += 2
	return v


func u32(what: String) -> int:
	if not _need(4, what):
		return 0
	var v := _data.decode_u32(_pos)
	_pos += 4
	return v


func f32(what: String) -> float:
	if not _need(4, what):
		return 0.0
	var v := _data.decode_float(_pos)
	_pos += 4
	return v


## u32 byte length + UTF-8. Invalid UTF-8 round-trips differently and is rejected.
func text(what: String, max_len: int = 1024) -> String:
	var n := u32(what + " length")
	if error != "":
		return ""
	if n > max_len or not _need(n, what):
		if error == "":
			error = "%s length %d exceeds %d" % [what, n, max_len]
		return ""
	var raw := _data.slice(_pos, _pos + n)
	_pos += n
	var s := raw.get_string_from_utf8()
	if s.to_utf8_buffer() != raw:
		error = "%s is not valid UTF-8" % what
		return ""
	return s
