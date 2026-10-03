class_name LiveScatterTile
extends RefCounted
## WPST scatter preview tile (INT-SPEC-1.1 §10.5): "WPST", u32 version = 1, u32 binding_count, binding_count x
## str binding_id (sorted, u32 length + UTF-8), u32 instance_count (<= 16384), then 20-byte records
## {u16 binding_index, u16 flags, f32 x, f32 z, f32 yaw, f32 scale} whose X/Z lie inside the tile's world rectangle.

const MAGIC := "WPST"
const VERSION := 1
const MAX_INSTANCES := 16384
const RECORD_BYTES := 20


## `layer` instances at `indices` (document order) -> WPST bytes, or empty when over the instance cap.
static func encode(layer: ScatterLayer, indices: PackedInt32Array) -> PackedByteArray:
	if indices.size() > MAX_INSTANCES:
		return PackedByteArray()
	var used := {}
	for i in indices:
		used[layer.binding_of(i)] = true
	var ids := PackedStringArray(used.keys())
	ids.sort()
	var e := CanonicalEncoder.new()
	e.put_raw(MAGIC.to_ascii_buffer())
	e.put_u32(VERSION)
	e.put_u32(ids.size())
	for id in ids:
		e.put_str(id)
	e.put_u32(indices.size())
	var block := PackedByteArray()
	block.resize(indices.size() * RECORD_BYTES)
	var o := 0
	for i in indices:
		block.encode_u16(o, ids.find(layer.binding_of(i)))
		block.encode_u16(o + 2, layer.flags[i])
		block.encode_float(o + 4, layer.x[i])
		block.encode_float(o + 8, layer.z[i])
		block.encode_float(o + 12, layer.yaw[i])
		block.encode_float(o + 16, layer.scale[i])
		o += RECORD_BYTES
	e.put_raw(block)
	return e.bytes()


## {ok, error, binding_ids: PackedStringArray, count: int}. `rect` is the tile's world rectangle (x, z half-open).
static func validate(bytes: PackedByteArray, rect: Rect2) -> Dictionary:
	var r := BinReader.new(bytes)
	if r.ascii(4) != MAGIC or r.u32("version") != VERSION:
		return _fail("WPST: bad magic or version")
	var n_ids := r.u32("binding_count")
	if r.error != "" or n_ids > ScatterLayer.MAX_SLOTS or n_ids * 4 > r.remaining():
		return _fail("WPST: binding_count is not plausible")
	var ids := PackedStringArray()
	for i in n_ids:
		var id := r.text("binding_id", ScatterLayer.MAX_BINDING_ID_LEN)
		if r.error != "" or not AssetBinding.is_valid_id(id) or (i > 0 and not (ids[i - 1] < id)):
			return _fail("WPST: invalid or unsorted binding table")
		ids.append(id)
	var count := r.u32("instance_count")
	if r.error != "" or count > MAX_INSTANCES or count * RECORD_BYTES != r.remaining():
		return _fail("WPST: instance_count does not match the file size")
	return _check_records(r, ids, count, rect)


static func _check_records(r: BinReader, ids: PackedStringArray, count: int, rect: Rect2) -> Dictionary:
	for i in count:
		var index := r.u16("binding_index")
		var flags := r.u16("flags")
		var x := r.f32("x")
		var z := r.f32("z")
		r.f32("yaw")
		var scale := r.f32("scale")
		if r.error != "" or index >= ids.size() or (flags & ~ScatterLayer.FLAGS_ALLOWED) != 0:
			return _fail("WPST: invalid instance %d" % i)
		if not (is_finite(x) and is_finite(z) and is_finite(scale)) or x < rect.position.x \
				or x >= rect.end.x or z < rect.position.y or z >= rect.end.y:
			return _fail("WPST: instance %d lies outside its tile" % i)
	return {"ok": true, "error": "", "binding_ids": ids, "count": count}


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "binding_ids": PackedStringArray(), "count": 0}
