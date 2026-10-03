class_name CanonicalEncoder
extends RefCounted
## Shared canonical byte encoding for the authored-content hash (docs/world-format.md §7, §11.4).
## Python (scripts/worldpoc_format.py) implements the identical stream; tests pin known vectors.
## Schema 4 (contracts/world-painter/world-v4/authored-hash-v4.md) is what every writer produces; the
## V2/V3 streams remain only to verify legacy generations (computed from bundled bindings).
## Hashing binary values avoids depending on JSON whitespace or float formatting.
## Integers little-endian; str = u32 byte length + UTF-8; -0.0 is written as +0.0.
## world_id and document_revision are deliberately excluded: undo+redo or reopening a
## copy must yield the same authored hash.

const MAGIC := "WPOC-AUTHORED-V2\n"
const MAGIC_V3 := "WPOC-AUTHORED-V3\n"
const MAGIC_V4 := "WPOC-AUTHORED-V4\n"

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


## Schema 4 object entry (binding_id replaces asset_id + asset_version).
static func encode_object(e: CanonicalEncoder, r: ObjectRecord) -> void:
	e.put_str(r.object_id)
	e.put_str(r.binding_id)
	_put_object_values(e, r)


static func _put_object_values(e: CanonicalEncoder, r: ObjectRecord) -> void:
	for v in r.position:
		e.put_f64(v)
	for v in r.rotation_xyzw:
		e.put_f64(v)
	e.put_f64(r.uniform_scale)
	e.put_str(r.grounding)
	e.put_f64(r.height_offset_m)
	e.put_str(r.origin)
	e.put_str(r.scatter_operation_id)


static func _put_rules_and_layout(e: CanonicalEncoder, layout: WorldLayout, rules: TerrainRules, with_layout: bool) -> void:
	e.put_f64(WorldConstants.SAMPLE_SPACING)
	e.put_u32(WorldConstants.REGION_SAMPLES)
	if with_layout:
		e.put_i32(layout.min_region.x)
		e.put_i32(layout.min_region.y)
		e.put_u32(layout.region_count.x)
		e.put_u32(layout.region_count.y)
	e.put_u8(1 if rules.rock_enabled else 0)
	e.put_i32(rules.rock_slope_deg)
	e.put_u8(1 if rules.sand_enabled else 0)
	e.put_i32(rules.sand_height_dm)


## Schema 4 stream up to the region list; `lock_digest` is the raw sha256 of the asset_locks.json bytes.
static func _head(layout: WorldLayout, lock_digest: PackedByteArray, rules: TerrainRules) -> CanonicalEncoder:
	var e := CanonicalEncoder.new()
	e.put_raw(MAGIC_V4.to_ascii_buffer())
	e.put_u32(WorldConstants.SCHEMA_VERSION_V4)
	e.put_raw(lock_digest)
	_put_rules_and_layout(e, layout, rules, true)
	return e


## The same hash as authored_hash(doc), from a checkpoint snapshot's plain values (storage worker).
## `digests` maps payload path -> raw sha256 of its bytes (asset_locks.json included); `object_canon`
## holds encode_object() bytes per object in sorted id order.
static func authored_hash_of_parts(layout: WorldLayout, rules: TerrainRules, digests: Dictionary,
		object_canon: Array) -> String:
	var e := _head(layout, digests[WorldConstants.ASSET_LOCK_FILE], rules)
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


static func _put_regions_and_files(e: CanonicalEncoder, doc: WorldDocument, scatter_bytes: PackedByteArray) -> void:
	var locs := doc.sorted_region_locations()
	e.put_u32(locs.size())
	for loc in locs:
		var r := doc.get_region(loc)
		e.put_i32(loc.x)
		e.put_i32(loc.y)
		e.put_raw(sha256(r.height_bytes()))
		e.put_raw(sha256(r.control_bytes()))
		e.put_raw(sha256(r.color_bytes()))
	e.put_raw(sha256(scatter_bytes))
	e.put_raw(sha256(PathRecord.encode_all(doc.paths)))


## Empty bytes when the document references a binding its lock does not hold (never a valid world).
static func authored_bytes(doc: WorldDocument) -> PackedByteArray:
	var lock := doc.assets.encode_referenced(doc)
	if lock[1] != "":
		return PackedByteArray()
	var e := _head(doc.layout, sha256(lock[0]), doc.rules)
	_put_regions_and_files(e, doc, doc.scatter.encode())
	var ids := doc.sorted_object_ids()
	e.put_u32(ids.size())
	for id in ids:
		encode_object(e, doc.get_object(id))
	return e.bytes()


## "" for a document whose lock cannot be encoded.
static func authored_hash(doc: WorldDocument) -> String:
	var bytes := authored_bytes(doc)
	return "" if bytes.is_empty() else sha256_hex(bytes)


# --- Legacy streams (schema 2/3) ------------------------------------------------------------

## Maps a document's bundled bindings back to catalog (asset_id, version) pairs: {binding_id: [id, version]}
## plus the single catalog identity {id, version, sha256}. Returns [mapping, catalog, error].
static func legacy_mapping(doc: WorldDocument) -> Array:
	var mapping := {}
	var cat := {}
	for id in doc.assets.referenced_ids(doc):
		var b := doc.assets.get_binding(id)
		if b == null or not b.is_bundled():
			return [{}, {}, "binding '%s' is not a bundled binding" % id]
		var identity := {"id": b.catalog_id, "version": b.catalog_version, "sha256": b.catalog_sha256}
		if not cat.is_empty() and cat != identity:
			return [{}, {}, "bindings come from more than one catalog"]
		cat = identity
		mapping[id] = [b.asset_id, b.asset_version]
	if cat.is_empty():
		var trusted := doc.assets.catalog
		if trusted == null:
			return [{}, {}, "no catalog to describe an asset-free legacy world"]
		cat = {"id": trusted.catalog_id, "version": trusted.catalog_version, "sha256": trusted.sha256}
	return [mapping, cat, ""]


## V2 (legacy layout) or V3 stream of `doc`, for verifying a schema 2/3 generation. Returns [bytes, error].
static func legacy_authored_bytes(doc: WorldDocument) -> Array:
	var legacy := doc.layout.is_legacy()
	var mapped := legacy_mapping(doc)
	if mapped[2] != "":
		return [PackedByteArray(), mapped[2]]
	var mapping: Dictionary = mapped[0]
	var cat: Dictionary = mapped[1]
	var e := CanonicalEncoder.new()
	e.put_raw((MAGIC if legacy else MAGIC_V3).to_ascii_buffer())
	e.put_u32(doc.layout.legacy_schema_version())
	e.put_str(cat.id)
	e.put_u32(cat.version)
	e.put_str(cat.sha256)
	_put_rules_and_layout(e, doc.layout, doc.rules, not legacy)
	_put_regions_and_files(e, doc, doc.scatter.encode_legacy_v1(mapping))
	var ids := doc.sorted_object_ids()
	e.put_u32(ids.size())
	for id in ids:
		var r := doc.get_object(id)
		e.put_str(r.object_id)
		e.put_str(mapping[r.binding_id][0])
		e.put_u32(mapping[r.binding_id][1])
		_put_object_values(e, r)
	return [e.bytes(), ""]


## Returns [hash, error].
static func legacy_authored_hash(doc: WorldDocument) -> Array:
	var bytes := legacy_authored_bytes(doc)
	return ["", bytes[1]] if bytes[1] != "" else [sha256_hex(bytes[0]), ""]
