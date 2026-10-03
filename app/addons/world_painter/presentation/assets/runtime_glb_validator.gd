class_name RuntimeGlbValidator
extends RefCounted
## Pure structural check of a portable GLB (INT-SPEC §6, §12): the JSON chunk is parsed and judged before any
## scene is created, so a hostile file never reaches GLTFDocument. validate() returns
## {"ok": true, "stats": {...}} or {"ok": false, "error": String}; it never logs.

const MIB := 1048576
const MAX_BYTES := 128 * MIB
const MAX_NODES := 1024
const MAX_MATERIALS := 64
const MAX_TRIANGLES := 200000
const MAX_TEXTURE_DIM := 4096
const MAX_TEXTURE_BYTES := 128 * MIB
const SCATTER_MAX_TRIANGLES := 2000
const SCATTER_MAX_MATERIALS := 2
const SCATTER_MAX_TEXTURE_DIM := 1024
## glTF extensions the loader understands. None initially: any extensionsRequired entry rejects the file.
const EXTENSION_ALLOWLIST: PackedStringArray = []

const MAGIC := 0x46546C67
const CHUNK_JSON := 0x4E4F534A
const CHUNK_BIN := 0x004E4942
const COMPONENT_BYTES := {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
const TYPE_COMPONENTS := {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


static func validate(glb: PackedByteArray) -> Dictionary:
	if glb.size() > MAX_BYTES:
		return _fail("file is %d bytes, over the %d MiB limit" % [glb.size(), MAX_BYTES / MIB])
	var container := _container(glb)
	if str(container.error) != "":
		return _fail(str(container.error))
	var doc: Dictionary = container.json
	var bin: PackedByteArray = container.bin
	var err := _features_error(doc)
	var lengths: Array = []
	if err == "":
		lengths = _buffer_lengths(doc, bin.size())
		err = _layout_error(doc, lengths)
	if err != "":
		return _fail(err)
	var stats := {"nodes": _arr(doc, "nodes").size(), "materials": _arr(doc, "materials").size()}
	if int(stats.nodes) > MAX_NODES:
		return _fail("%d nodes exceed the limit of %d" % [stats.nodes, MAX_NODES])
	if int(stats.materials) > MAX_MATERIALS:
		return _fail("%d materials exceed the limit of %d" % [stats.materials, MAX_MATERIALS])
	var geometry := _geometry(doc)
	if str(geometry.error) != "":
		return _fail(str(geometry.error))
	var images := _images(doc, bin)
	if str(images.error) != "":
		return _fail(str(images.error))
	stats.merge({"triangles": geometry.triangles, "materials_used": geometry.materials_used,
		"images": images.count, "max_texture_dim": images.max_dim, "texture_bytes": images.bytes})
	return {"ok": true, "stats": stats}


## True when the validated stats also satisfy the scatter structural budget (INT-SPEC §12).
static func scatter_budget_ok(stats: Dictionary) -> bool:
	return int(stats.triangles) <= SCATTER_MAX_TRIANGLES and int(stats.materials_used) <= SCATTER_MAX_MATERIALS \
			and int(stats.max_texture_dim) <= SCATTER_MAX_TEXTURE_DIM


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


static func _arr(doc: Dictionary, key: String) -> Array:
	var v: Variant = doc.get(key, [])
	return v if typeof(v) == TYPE_ARRAY else []


static func _u32(b: PackedByteArray, at: int) -> int:
	return b.decode_u32(at)


## {"error", "json", "bin"}: header, JSON chunk and the first BIN chunk of a version 2 GLB.
static func _container(glb: PackedByteArray) -> Dictionary:
	var out := {"error": "", "json": {}, "bin": PackedByteArray()}
	if glb.size() < 20 or _u32(glb, 0) != MAGIC:
		out.error = "not a GLB file"
		return out
	if _u32(glb, 4) != 2 or _u32(glb, 8) != glb.size():
		out.error = "unsupported GLB version or inconsistent length"
		return out
	var json_len := _u32(glb, 12)
	if _u32(glb, 16) != CHUNK_JSON or 20 + json_len > glb.size():
		out.error = "GLB has no valid JSON chunk first"
		return out
	var parser := JSON.new()
	if parser.parse(glb.slice(20, 20 + json_len).get_string_from_utf8()) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		out.error = "GLB JSON chunk is not a valid JSON object"
		return out
	out.json = parser.data
	var at := 20 + json_len
	while at + 8 <= glb.size():
		var chunk_len := _u32(glb, at)
		if at + 8 + chunk_len > glb.size():
			out.error = "GLB chunk overruns the file"
			return out
		if _u32(glb, at + 4) == CHUNK_BIN:
			out.bin = glb.slice(at + 8, at + 8 + chunk_len)
			break
		at += 8 + chunk_len
	return out


static func _features_error(doc: Dictionary) -> String:
	for ext: Variant in _arr(doc, "extensionsRequired"):
		if typeof(ext) != TYPE_STRING or not EXTENSION_ALLOWLIST.has(ext):
			return "required extension '%s' is not supported" % str(ext)
	if not _arr(doc, "skins").is_empty():
		return "skins are not supported"
	if not _arr(doc, "animations").is_empty():
		return "animations are not supported"
	for kind in ["buffers", "images"]:
		for entry: Variant in _arr(doc, kind):
			var uri: Variant = entry.get("uri") if typeof(entry) == TYPE_DICTIONARY else null
			if uri != null and (typeof(uri) != TYPE_STRING or not (uri as String).begins_with("data:")):
				return "external %s URI is not allowed" % kind.trim_suffix("s")
	return ""


## Usable byte length of each buffer: the BIN chunk for a uri-less first buffer, the data URI payload otherwise.
static func _buffer_lengths(doc: Dictionary, bin_size: int) -> Array:
	var out: Array = []
	var buffers := _arr(doc, "buffers")
	for i in buffers.size():
		var entry: Variant = buffers[i]
		var uri: Variant = entry.get("uri") if typeof(entry) == TYPE_DICTIONARY else null
		if typeof(entry) != TYPE_DICTIONARY:
			out.append(-1)
		elif uri == null:
			out.append(bin_size if i == 0 else -1)
		else:
			var comma := (uri as String).find(",")
			out.append(((uri as String).length() - comma - 1) * 3 / 4 if comma >= 0 else -1)
	return out


static func _layout_error(doc: Dictionary, lengths: Array) -> String:
	var views := _arr(doc, "bufferViews")
	for i in views.size():
		var v: Variant = views[i]
		if typeof(v) != TYPE_DICTIONARY or not _is_int(v.get("buffer")) or not _is_int(v.get("byteLength")):
			return "bufferView %d is malformed" % i
		var b := int(v.buffer)
		if b < 0 or b >= lengths.size() or int(lengths[b]) < 0:
			return "bufferView %d names a missing buffer" % i
		if int(v.get("byteOffset", 0)) < 0 or int(v.byteLength) < 0 \
				or int(v.get("byteOffset", 0)) + int(v.byteLength) > int(lengths[b]):
			return "bufferView %d lies outside its buffer" % i
	var accessors := _arr(doc, "accessors")
	for i in accessors.size():
		var err := _accessor_error(accessors[i], views)
		if err != "":
			return "accessor %d: %s" % [i, err]
	return ""


static func _accessor_error(a: Variant, views: Array) -> String:
	if typeof(a) != TYPE_DICTIONARY or not _is_int(a.get("count")) or int(a.count) < 0:
		return "malformed"
	if not COMPONENT_BYTES.has(int(a.get("componentType", 0))) or not TYPE_COMPONENTS.has(a.get("type")):
		return "unsupported component or type"
	if a.has("sparse") or not a.has("bufferView"):
		return ""
	var bv: int = int(a.bufferView) if _is_int(a.bufferView) else -1
	if bv < 0 or bv >= views.size():
		return "names a missing bufferView"
	var elem: int = int(COMPONENT_BYTES[int(a.componentType)]) * int(TYPE_COMPONENTS[a.type])
	var stride: int = int(views[bv].get("byteStride", elem))
	var need: int = int(a.get("byteOffset", 0)) + maxi(int(a.count) - 1, 0) * stride + elem
	return "" if int(a.count) == 0 or need <= int(views[bv].byteLength) else "reads past its bufferView"


static func _is_int(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)) and float(v) == floorf(float(v))


## {"error", "triangles", "materials_used"}: triangles counted over every node that instances a mesh.
static func _geometry(doc: Dictionary) -> Dictionary:
	var out := {"error": "", "triangles": 0, "materials_used": 0}
	var accessors := _arr(doc, "accessors")
	var per_mesh: Array = []
	var used := {}
	for m: Variant in _arr(doc, "meshes"):
		var tris := 0
		for p: Variant in (m.get("primitives", []) if typeof(m) == TYPE_DICTIONARY else []):
			var n := _primitive_triangles(p, accessors)
			if n < 0:
				out.error = "mesh primitive is not an indexed or plain triangle list with POSITION"
				return out
			tris += n
			used[int(p.get("material", -1))] = true
		per_mesh.append(tris)
	var total := 0
	for node: Variant in _arr(doc, "nodes"):
		var mesh: Variant = node.get("mesh") if typeof(node) == TYPE_DICTIONARY else null
		if mesh != null:
			if not _is_int(mesh) or int(mesh) < 0 or int(mesh) >= per_mesh.size():
				out.error = "node names a missing mesh"
				return out
			total += int(per_mesh[int(mesh)])
			if total > MAX_TRIANGLES:
				out.error = "more than %d triangles exceed the limit of %d" % [total, MAX_TRIANGLES]
				return out
	if total == 0:
		out.error = "no mesh geometry in the scene"
	out.triangles = total
	out.materials_used = used.size()
	return out


## Triangle count of one primitive, or -1 when it is not a supported triangle primitive.
static func _primitive_triangles(p: Variant, accessors: Array) -> int:
	if typeof(p) != TYPE_DICTIONARY or typeof(p.get("attributes")) != TYPE_DICTIONARY or not p.attributes.has("POSITION"):
		return -1
	var mode: int = int(p.get("mode", 4))
	if mode != 4 and mode != 5 and mode != 6:
		return -1
	var source: Variant = p.get("indices", p.attributes.POSITION)
	if not _is_int(source) or int(source) < 0 or int(source) >= accessors.size() or typeof(accessors[int(source)]) != TYPE_DICTIONARY:
		return -1
	var count: int = int(accessors[int(source)].get("count", 0))
	return count / 3 if mode == 4 else maxi(count - 2, 0)


## {"error", "count", "max_dim", "bytes"}: header-derived size of every image (PNG IHDR, JPEG SOF).
static func _images(doc: Dictionary, bin: PackedByteArray) -> Dictionary:
	var out := {"error": "", "count": 0, "max_dim": 0, "bytes": 0}
	var views := _arr(doc, "bufferViews")
	for entry: Variant in _arr(doc, "images"):
		var raw := _image_bytes(entry, views, bin)
		var dims := image_dimensions(raw)
		if dims.x <= 0 or dims.y <= 0:
			out.error = "image is not a readable PNG or JPEG"
			return out
		out.count += 1
		out.max_dim = maxi(int(out.max_dim), maxi(dims.x, dims.y))
		out.bytes += dims.x * dims.y * 4
		if maxi(dims.x, dims.y) > MAX_TEXTURE_DIM:
			out.error = "image %dx%d exceeds the %d px texture limit" % [dims.x, dims.y, MAX_TEXTURE_DIM]
			return out
		if int(out.bytes) > MAX_TEXTURE_BYTES:
			out.error = "decoded textures exceed %d MiB" % (MAX_TEXTURE_BYTES / MIB)
			return out
	return out


static func _image_bytes(entry: Variant, views: Array, bin: PackedByteArray) -> PackedByteArray:
	if typeof(entry) != TYPE_DICTIONARY:
		return PackedByteArray()
	if entry.has("uri"):
		var uri: String = entry.uri
		return Marshalls.base64_to_raw(uri.substr(uri.find(",") + 1)) if uri.find(",") >= 0 else PackedByteArray()
	var bv: Variant = entry.get("bufferView")
	if not _is_int(bv) or int(bv) < 0 or int(bv) >= views.size() or typeof(views[int(bv)]) != TYPE_DICTIONARY:
		return PackedByteArray()
	var view: Dictionary = views[int(bv)]
	var start := int(view.get("byteOffset", 0))
	return bin.slice(start, mini(start + int(view.byteLength), bin.size())) if int(view.get("buffer", 0)) == 0 else PackedByteArray()


## Pixel size from the image header, Vector2i.ZERO for anything but PNG and JPEG.
static func image_dimensions(raw: PackedByteArray) -> Vector2i:
	if raw.size() >= 24 and raw.slice(0, 8) == PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]) \
			and raw.slice(12, 16).get_string_from_ascii() == "IHDR":
		return Vector2i(_be32(raw, 16), _be32(raw, 20))
	if raw.size() < 4 or raw[0] != 0xFF or raw[1] != 0xD8:
		return Vector2i.ZERO
	var at := 2
	while at + 9 < raw.size():
		if raw[at] != 0xFF:
			return Vector2i.ZERO
		var marker := raw[at + 1]
		if marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC:
			return Vector2i((raw[at + 7] << 8) | raw[at + 8], (raw[at + 5] << 8) | raw[at + 6])
		at += 2 + ((raw[at + 2] << 8) | raw[at + 3])
	return Vector2i.ZERO


static func _be32(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]
