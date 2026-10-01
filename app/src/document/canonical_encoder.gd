class_name CanonicalEncoder
extends RefCounted
## Shared canonical byte encoding for the authored-content hash (docs/world-format.md §7, §11.4).
## Python (scripts/worldpoc_format.py) implements the identical stream; tests pin known vectors.
## Hashing binary values avoids depending on JSON whitespace or float formatting.
## Integers little-endian; str = u32 byte length + UTF-8; -0.0 is written as +0.0.
## world_id and document_revision are deliberately excluded: undo+redo or reopening a
## copy must yield the same authored hash.

const MAGIC := "WPOC-AUTHORED-V2\n"
const MAGIC_V3 := "WPOC-AUTHORED-V3\n"

var _buf := PackedByteArray()


func put_u32(v: int) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	_buf.append_array(b)


func put_u64(v: int) -> void:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u64(0, v)
	_buf.append_array(b)


func put_i32(v: int) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	_buf.append_array(b)


func put_u16(v: int) -> void:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v)
	_buf.append_array(b)


func put_f32(v: float) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	_buf.append_array(b)


func put_u8(v: int) -> void:
	_buf.append(v & 0xFF)


func put_f64(v: float) -> void:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, 0.0 if v == 0.0 else v)
	_buf.append_array(b)


func put_str(s: String) -> void:
	var u := s.to_utf8_buffer()
	put_u32(u.size())
	_buf.append_array(u)


func put_raw(b: PackedByteArray) -> void:
	_buf.append_array(b)


func bytes() -> PackedByteArray:
	return _buf


static func sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()


static func sha256_hex(data: PackedByteArray) -> String:
	return sha256(data).hex_encode()


static func encode_object(e: CanonicalEncoder, r: ObjectRecord) -> void:
	e.put_str(r.object_id)
	e.put_str(r.asset_id)
	e.put_u32(r.asset_version)
	for v in r.position:
		e.put_f64(v)
	for v in r.rotation_xyzw:
		e.put_f64(v)
	e.put_f64(r.uniform_scale)
	e.put_str(r.grounding)
	e.put_f64(r.height_offset_m)
	e.put_str(r.origin)
	e.put_str(r.scatter_operation_id)


## Everything before the region list.
static func _head(layout: WorldLayout, catalog_id: String, catalog_version: int, catalog_sha256: String,
		rules: TerrainRules) -> CanonicalEncoder:
	var e := CanonicalEncoder.new()
	var legacy := layout.is_legacy()
	e.put_raw((MAGIC if legacy else MAGIC_V3).to_ascii_buffer())
	e.put_u32(layout.schema_version())
	e.put_str(catalog_id)
	e.put_u32(catalog_version)
	e.put_str(catalog_sha256)
	e.put_f64(WorldConstants.SAMPLE_SPACING)
	e.put_u32(WorldConstants.REGION_SAMPLES)
	if not legacy:
		e.put_i32(layout.min_region.x)
		e.put_i32(layout.min_region.y)
		e.put_u32(layout.region_count.x)
		e.put_u32(layout.region_count.y)
	e.put_u8(1 if rules.rock_enabled else 0)
	e.put_i32(rules.rock_slope_deg)
	e.put_u8(1 if rules.sand_enabled else 0)
	e.put_i32(rules.sand_height_dm)
	return e


## The same hash as authored_hash(doc), from a checkpoint snapshot's plain values (storage worker).
## `digests` maps payload path -> raw sha256 of its bytes; `object_canon` holds encode_object()
## bytes per object in sorted id order.
static func authored_hash_of_parts(layout: WorldLayout, catalog_id: String, catalog_version: int,
		catalog_sha256: String, rules: TerrainRules, digests: Dictionary, object_canon: Array) -> String:
	var e := _head(layout, catalog_id, catalog_version, catalog_sha256, rules)
	var locs := layout.region_locations()
	e.put_u32(locs.size())
	for loc in locs:
		e.put_i32(loc.x)
		e.put_i32(loc.y)
		var stem := WorldConstants.region_file_stem(loc)
		for suffix in [".height.f32le", ".control.u32le", ".color.rgba8"]:
			e.put_raw(digests[stem + suffix])
	e.put_raw(digests[WorldConstants.SCATTER_FILE])
	e.put_raw(digests[WorldConstants.PATHS_FILE])
	e.put_u32(object_canon.size())
	for chunk: PackedByteArray in object_canon:
		e.put_raw(chunk)
	return sha256_hex(e.bytes())


static func authored_bytes(doc: WorldDocument) -> PackedByteArray:
	var e := _head(doc.layout, doc.catalog_id, doc.catalog_version, doc.catalog_sha256, doc.rules)
	var locs := doc.sorted_region_locations()
	e.put_u32(locs.size())
	for loc in locs:
		var r := doc.get_region(loc)
		e.put_i32(loc.x)
		e.put_i32(loc.y)
		e.put_raw(sha256(r.height_bytes()))
		e.put_raw(sha256(r.control_bytes()))
		e.put_raw(sha256(r.color_bytes()))
	e.put_raw(sha256(doc.scatter.encode()))
	e.put_raw(sha256(PathRecord.encode_all(doc.paths)))
	var ids := doc.sorted_object_ids()
	e.put_u32(ids.size())
	for id in ids:
		encode_object(e, doc.get_object(id))
	return e.bytes()


static func authored_hash(doc: WorldDocument) -> String:
	return sha256_hex(authored_bytes(doc))
