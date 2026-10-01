class_name ScatterLayer
extends RefCounted
## Scatter instances (docs/world-format.md §5). Instance order is the document order and is
## significant. Storage keeps a slot table (`asset_ids`/`asset_versions`, may hold unused
## slots after removals) plus parallel per-instance arrays; encode() writes the canonical
## minimal table. Floats are float32 on disk and in the packed arrays, so values round-trip
## bit-exactly. Instance Y is never stored: it follows the terrain.

const MAGIC := "WPSC"
const VERSION := 1
const FLAG_TILT := 1
const FLAGS_ALLOWED := FLAG_TILT
const INSTANCE_BYTES := 20
const MAX_SLOTS := 0xFFFF
const MAX_ASSET_ID_LEN := 256

var asset_ids := PackedStringArray()
var asset_versions := PackedInt32Array()
var slot := PackedInt32Array()
var flags := PackedInt32Array()
var x := PackedFloat32Array()
var z := PackedFloat32Array()
var yaw := PackedFloat32Array()
var scale := PackedFloat32Array()


func count() -> int:
	return slot.size()


## False (nothing added) when the layer already holds `max_count` instances; the default is the
## schema 2 limit, documents of other schemas pass WorldLimits.for_schema(...).max_scatter_instances.
func add(asset_id: String, asset_version: int, px: float, pz: float, p_yaw: float, p_scale: float, p_flags: int,
		max_count: int = WorldConstants.MAX_SCATTER_INSTANCES) -> bool:
	if count() >= max_count:
		return false
	var s := _slot_for(asset_id, asset_version)
	if s < 0:
		return false
	slot.append(s)
	flags.append(p_flags)
	x.append(px)
	z.append(pz)
	yaw.append(p_yaw)
	scale.append(p_scale)
	return true


func _slot_for(asset_id: String, asset_version: int) -> int:
	for i in asset_ids.size():
		if asset_ids[i] == asset_id and asset_versions[i] == asset_version:
			return i
	if asset_ids.size() >= MAX_SLOTS:
		return -1
	asset_ids.append(asset_id)
	asset_versions.append(asset_version)
	return asset_ids.size() - 1


func asset_of(i: int) -> String:
	return asset_ids[slot[i]]


func version_of(i: int) -> int:
	return asset_versions[slot[i]]


## Removes the instances at `indices` (any order, duplicates and out-of-range ignored).
## Remaining instances keep their relative order; the slot table is left as is.
func remove_indices(indices: PackedInt32Array) -> void:
	var drop := PackedByteArray()
	drop.resize(count())
	for i in indices:
		if i >= 0 and i < drop.size():
			drop[i] = 1
	var n := count()
	var out := ScatterLayer.new()
	out.asset_ids = asset_ids
	out.asset_versions = asset_versions
	for i in n:
		if drop[i] == 0:
			out.slot.append(slot[i])
			out.flags.append(flags[i])
			out.x.append(x[i])
			out.z.append(z[i])
			out.yaw.append(yaw[i])
			out.scale.append(scale[i])
	slot = out.slot
	flags = out.flags
	x = out.x
	z = out.z
	yaw = out.yaw
	scale = out.scale


func clone() -> ScatterLayer:
	var c := ScatterLayer.new()
	c.asset_ids = asset_ids.duplicate()
	c.asset_versions = asset_versions.duplicate()
	c.slot = slot.duplicate()
	c.flags = flags.duplicate()
	c.x = x.duplicate()
	c.z = z.duplicate()
	c.yaw = yaw.duplicate()
	c.scale = scale.duplicate()
	return c


## Semantic equality: unused slots and slot numbering do not matter.
func equals(other: ScatterLayer) -> bool:
	if other == null or count() != other.count():
		return false
	if flags != other.flags or x != other.x or z != other.z or yaw != other.yaw or scale != other.scale:
		return false
	if asset_ids == other.asset_ids and asset_versions == other.asset_versions:
		return slot == other.slot
	for i in count():
		if asset_of(i) != other.asset_of(i) or version_of(i) != other.version_of(i):
			return false
	return true


## Canonical bytes: table = referenced (id, version) pairs sorted by id byte-wise.
func encode() -> PackedByteArray:
	var used := {}  # asset_id -> version
	var used_slots := {}
	for s in slot:
		used_slots[s] = true
	for s in used_slots:
		used[asset_ids[s]] = asset_versions[s]
	var ids := PackedStringArray(used.keys())
	ids.sort()
	var index_of := {}
	for i in ids.size():
		index_of[ids[i]] = i
	var e := CanonicalEncoder.new()
	e.put_raw(MAGIC.to_ascii_buffer())
	e.put_u32(VERSION)
	e.put_u32(ids.size())
	for id in ids:
		e.put_str(id)
		e.put_u32(used[id])
	var n := count()
	e.put_u32(n)
	var block := PackedByteArray()
	block.resize(n * INSTANCE_BYTES)
	for i in n:
		var o := i * INSTANCE_BYTES
		block.encode_u16(o, index_of[asset_ids[slot[i]]])
		block.encode_u16(o + 2, flags[i])
		block.encode_float(o + 4, x[i])
		block.encode_float(o + 8, z[i])
		block.encode_float(o + 12, yaw[i])
		block.encode_float(o + 16, scale[i])
	e.put_raw(block)
	return e.bytes()


## Structure only: returns [ScatterLayer, ""] or [null, error]. Catalog, extent, yaw-limit and
## scale rules belong to WorldValidator. `max_instances` is the schema's limit (WorldLimits);
## the default is the schema 2 limit.
static func decode(bytes: PackedByteArray, max_instances: int = WorldLimits.SCHEMA_2.max_scatter_instances) -> Array:
	var r := BinReader.new(bytes)
	var err := _decode_header(r)
	if err != "":
		return [null, err]
	var layer := ScatterLayer.new()
	err = _decode_table(r, layer)
	if err != "":
		return [null, err]
	err = _decode_instances(r, layer, max_instances)
	if err != "":
		return [null, err]
	return [layer, ""]


static func _decode_header(r: BinReader) -> String:
	if r.ascii(4) != MAGIC:
		return "scatter.bin: bad magic" if r.error == "" else "scatter.bin: " + r.error
	var version := r.u32("version")
	if r.error != "":
		return "scatter.bin: " + r.error
	if version != VERSION:
		return "scatter.bin: unsupported version %d" % version
	return ""


static func _decode_table(r: BinReader, layer: ScatterLayer) -> String:
	var asset_count := r.u32("asset_count")
	if r.error == "" and (asset_count > MAX_SLOTS or asset_count * 8 > r.remaining()):
		return "scatter.bin: asset_count %d is not plausible" % asset_count
	var prev := ""
	for i in asset_count:
		var id := r.text("asset_id", MAX_ASSET_ID_LEN)
		var version := r.u32("asset_version")
		if r.error != "":
			break
		if i > 0 and not (prev < id):
			return "scatter.bin: asset table is not sorted and unique at '%s'" % id
		prev = id
		layer.asset_ids.append(id)
		layer.asset_versions.append(version)
	return "" if r.error == "" else "scatter.bin: " + r.error


static func _decode_instances(r: BinReader, layer: ScatterLayer, max_instances: int) -> String:
	var n := r.u32("instance_count")
	if r.error != "":
		return "scatter.bin: " + r.error
	if n > max_instances:
		return "scatter.bin: %d instances exceed the limit of %d" % [n, max_instances]
	if n * INSTANCE_BYTES > r.remaining():
		return "scatter.bin: truncated while reading instances"
	var used := PackedByteArray()
	used.resize(layer.asset_ids.size())
	for i in n:
		var s := r.u16("asset_index")
		var fl := r.u16("flags")
		var vals := [r.f32("x"), r.f32("z"), r.f32("yaw_rad"), r.f32("scale")]
		if s >= layer.asset_ids.size():
			return "scatter.bin: instance %d asset_index %d >= asset_count %d" % [i, s, layer.asset_ids.size()]
		if (fl & ~FLAGS_ALLOWED) != 0:
			return "scatter.bin: instance %d has unknown flag bits 0x%04x" % [i, fl]
		for v: float in vals:
			if not is_finite(v):
				return "scatter.bin: instance %d has a non-finite value" % i
		used[s] = 1
		layer.slot.append(s)
		layer.flags.append(fl)
		layer.x.append(vals[0])
		layer.z.append(vals[1])
		layer.yaw.append(vals[2])
		layer.scale.append(vals[3])
	if not r.at_end():
		return "scatter.bin: %d trailing bytes" % r.remaining()
	if used.count(0) > 0:
		return "scatter.bin: asset table lists assets no instance uses"
	return ""
