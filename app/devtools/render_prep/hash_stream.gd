extends RefCounted
## Byte stream for the docs/render-assets.md §3 hashes: integers little-endian, str = u32 byte
## length + UTF-8. Kept local to the devtool so the offline tool does not depend on runtime classes.

var _buf := PackedByteArray()


func u8(v: int) -> void:
	_buf.append(v & 0xFF)


func u32(v: int) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	_buf.append_array(b)


func u64(v: int) -> void:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u64(0, v)
	_buf.append_array(b)


func text(s: String) -> void:
	var u := s.to_utf8_buffer()
	u32(u.size())
	_buf.append_array(u)


func raw(b: PackedByteArray) -> void:
	_buf.append_array(b)


func ascii(s: String) -> void:
	_buf.append_array(s.to_ascii_buffer())


func sha256_hex() -> String:
	return sha256(_buf).hex_encode()


static func sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()
