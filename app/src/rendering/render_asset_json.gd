class_name RenderAssetJson
extends RefCounted
## Strict JSON field helpers shared by RenderAssetDescriptor and RenderAssetRegistry.
## JSON numbers arrive as floats, so integrality is checked explicitly. Booleans are never numbers.

const MAX_PATH_LENGTH := 256


static func check_keys(d: Dictionary, keys: Array, what: String) -> String:
	for k in keys:
		if not d.has(k):
			return "%s missing field '%s'" % [what, k]
	for k in d:
		if not keys.has(k):
			return "%s has unknown field '%s'" % [what, str(k)]
	return ""


static func is_number(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func is_int(v: Variant) -> bool:
	return is_number(v) and absf(float(v)) <= 9007199254740992.0 and float(v) == floorf(float(v))


static func is_int_in(v: Variant, lo: int, hi: int) -> bool:
	return is_int(v) and float(v) >= float(lo) and float(v) <= float(hi)


static func is_str(v: Variant) -> bool:
	return typeof(v) == TYPE_STRING and v != ""


static func is_hex64(v: Variant) -> bool:
	if typeof(v) != TYPE_STRING or (v as String).length() != 64:
		return false
	for c in (v as String):
		if not ("0123456789abcdef".contains(c)):
			return false
	return true


static func is_pow2(v: int) -> bool:
	return v > 0 and (v & (v - 1)) == 0


## Returns null unless v is an array of 3 finite numbers.
static func vec3(v: Variant) -> Variant:
	if typeof(v) != TYPE_ARRAY or (v as Array).size() != 3:
		return null
	for x in v:
		if not is_number(x):
			return null
	return Vector3(v[0], v[1], v[2])


## docs/render-assets.md §4 path rules for a relative path. "" when acceptable.
static func path_error(rel: Variant) -> String:
	if typeof(rel) != TYPE_STRING or rel == "":
		return "path must be a non-empty string"
	var s: String = rel
	if s.length() > MAX_PATH_LENGTH:
		return "path is too long"
	if s.contains("\\") or s.begins_with("/") or s.contains(":"):
		return "path '%s' must be relative with '/' separators" % s
	for c in s:
		if c.unicode_at(0) < 32:
			return "path contains control characters"
	for seg in s.split("/"):
		if seg == "" or seg == "." or seg == "..":
			return "path '%s' has an empty or traversal segment" % s
	return ""


static func read_bytes(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [PackedByteArray(), "cannot read '%s' (error %d)" % [path, FileAccess.get_open_error()]]
	return [f.get_buffer(f.get_length()), ""]
