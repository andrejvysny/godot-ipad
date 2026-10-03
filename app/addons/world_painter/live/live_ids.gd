class_name LiveIds
extends RefCounted
## Random 128-bit lowercase-hex ids (session, stream, message, transfer, operation) and hex validators for the
## live protocol (ADR 0015 L1). Ids carry no meaning; they only have to be unguessable and collision-free.

const ID_HEX_LEN := 32
const HASH_HEX_LEN := 64
## hello is sent before a session exists; the envelope still needs well-formed ids.
const ZERO_ID := "00000000000000000000000000000000"


static func new_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


## 32 random bytes as 64 hex chars (pairing token, session credential).
static func new_secret() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


static func is_id(s: Variant) -> bool:
	return typeof(s) == TYPE_STRING and _is_lower_hex(s, ID_HEX_LEN)


static func is_hash(s: Variant) -> bool:
	return typeof(s) == TYPE_STRING and _is_lower_hex(s, HASH_HEX_LEN)


static func hex_to_bytes(hex: String) -> PackedByteArray:
	return hex.hex_decode()


static func _is_lower_hex(s: String, n: int) -> bool:
	if s.length() != n:
		return false
	for i in n:
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true
