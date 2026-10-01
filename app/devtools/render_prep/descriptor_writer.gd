extends RefCounted
## docs/render-assets.md hashes (§3) and the deterministic JSON writer for descriptors/index.

const HashStream := preload("res://devtools/render_prep/hash_stream.gd")
const ROLES: Array[String] = ["selected", "near", "mid", "far", "ghost"]


static func source_hash(asset_id: String, version: int, preview_bytes: PackedByteArray, scatter_bytes: Variant) -> String:
	var s := HashStream.new()
	s.ascii("WPRA-SOURCE-V1\n")
	s.text(asset_id)
	s.u32(version)
	s.raw(HashStream.sha256(preview_bytes))
	s.u8(0 if scatter_bytes == null else 1)
	if scatter_bytes != null:
		s.raw(HashStream.sha256(scatter_bytes as PackedByteArray))
	return s.sha256_hex()


static func derivative_hash(d: Dictionary) -> String:
	var s := HashStream.new()
	s.ascii("WPRA-DERIVATIVE-V1\n")
	s.text(d.asset_id)
	s.u32(int(d.asset_version))
	s.raw((d.source_content_hash as String).hex_decode())
	s.text(d.category)
	s.u8(1 if d.vegetation else 0)
	s.u8(1 if d.decorative else 0)
	for role in ROLES:
		var r: Dictionary = d.representations[role]
		s.text(role)
		if r.has("alias"):
			s.u8(1)
			s.text(r.alias)
			s.u32(0)
			s.u32(0)
		else:
			s.u8(0)
			s.text(r.mesh)
			s.u32(int(r.triangles))
			s.u32(int(r.surfaces))
	var deps: Array = d.dependencies
	s.u32(deps.size())
	for dep: Dictionary in deps:
		s.text(dep.key)
		s.text(dep.type)
		s.text(dep.path)
		s.u64(int(dep.bytes))
		s.raw((dep.sha256 as String).hex_decode())
	var mats: Dictionary = d.materials
	var mat_keys := _sorted_keys(mats)
	s.u32(mat_keys.size())
	for k in mat_keys:
		s.text(k)
		s.text(mats[k].dependency)
		s.text(mats[k].alpha_mode)
		s.text("" if mats[k].texture == null else mats[k].texture)
	var texs: Dictionary = d.textures
	var tex_keys := _sorted_keys(texs)
	s.u32(tex_keys.size())
	for k in tex_keys:
		var t: Dictionary = texs[k]
		s.text(k)
		s.text(t.low.dependency)
		s.u32(int(t.low.width))
		s.u32(int(t.low.height))
		var p: Variant = t.preview
		s.text("" if p == null else p.dependency)
		s.u32(0 if p == null else int(p.width))
		s.u32(0 if p == null else int(p.height))
	return s.sha256_hex()


static func _sorted_keys(d: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for k in d:
		keys.append(k)
	keys.sort()
	return keys


## Insertion-ordered JSON, 2-space indent, short number arrays inline, floats at 6 decimals.
static func to_json(v: Variant, level: int = 0) -> String:
	match typeof(v):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return num(v)
		TYPE_STRING:
			return JSON.stringify(v)
		TYPE_ARRAY:
			return _array_json(v, level)
		TYPE_DICTIONARY:
			return _dict_json(v, level)
		TYPE_VECTOR3:
			return "[%s, %s, %s]" % [num(v.x), num(v.y), num(v.z)]
	return JSON.stringify(str(v))


static func num(f: float) -> String:
	var s := "%.6f" % f
	while s.ends_with("0") and not s.ends_with(".0"):
		s = s.substr(0, s.length() - 1)
	return "0.0" if s == "-0.0" else s


static func _array_json(a: Array, level: int) -> String:
	if a.is_empty():
		return "[]"
	var flat := true
	for x in a:
		flat = flat and (typeof(x) == TYPE_FLOAT or typeof(x) == TYPE_INT or typeof(x) == TYPE_STRING)
	var parts: PackedStringArray = []
	for x in a:
		parts.append(to_json(x, level + 1))
	if flat and a.size() <= 4:
		return "[" + ", ".join(parts) + "]"
	var pad := "  ".repeat(level + 1)
	return "[\n" + ",\n".join(PackedStringArray(Array(parts).map(func(p: String) -> String: return pad + p))) + "\n" + "  ".repeat(level) + "]"


static func _dict_json(d: Dictionary, level: int) -> String:
	if d.is_empty():
		return "{}"
	var pad := "  ".repeat(level + 1)
	var parts: PackedStringArray = []
	for k in d:
		parts.append("%s%s: %s" % [pad, JSON.stringify(str(k)), to_json(d[k], level + 1)])
	return "{\n" + ",\n".join(parts) + "\n" + "  ".repeat(level) + "}"
