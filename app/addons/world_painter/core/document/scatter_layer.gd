class_name ScatterLayer
extends RefCounted
## Scatter instances (docs/world-format.md §5, §12). Instance order is the document order and is
## significant. Storage keeps a slot table (`binding_ids`, may hold unused slots after removals)
## plus parallel per-instance arrays; encode() writes the canonical minimal table (scatter.bin v2).
## Floats are float32 on disk and in the packed arrays, so values round-trip bit-exactly. Instance Y
## is never stored: it follows the terrain.

const MAGIC := "WPSC"
const VERSION := 2
const LEGACY_VERSION := 1
const FLAG_TILT := 1
const FLAGS_ALLOWED := FLAG_TILT
const INSTANCE_BYTES := 20
const MAX_SLOTS := 0xFFFF
const MAX_ASSET_ID_LEN := 256
const MAX_BINDING_ID_LEN := 33

var binding_ids := PackedStringArray()
var slot := PackedInt32Array()
var flags := PackedInt32Array()
var x := PackedFloat32Array()
var z := PackedFloat32Array()
var yaw := PackedFloat32Array()
var scale := PackedFloat32Array()


func count() -> int:
	return slot.size()


## False (nothing added) when the layer already holds `max_count` instances; the default is the
## schema 2 limit, documents pass WorldLimits.for_schema(...).max_scatter_instances.
func add(binding_id: String, px: float, pz: float, p_yaw: float, p_scale: float, p_flags: int,
		max_count: int = WorldConstants.MAX_SCATTER_INSTANCES) -> bool:
	if count() >= max_count:
		return false
	var s := _slot_for(binding_id)
	if s < 0:
		return false
	slot.append(s)
	flags.append(p_flags)
	x.append(px)
	z.append(pz)
	yaw.append(p_yaw)
	scale.append(p_scale)
	return true


func _slot_for(binding_id: String) -> int:
	var found := binding_ids.find(binding_id)
	if found >= 0:
		return found
	if binding_ids.size() >= MAX_SLOTS:
		return -1
	binding_ids.append(binding_id)
	return binding_ids.size() - 1


func binding_of(i: int) -> String:
	return binding_ids[slot[i]]


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
	c.binding_ids = binding_ids.duplicate()
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
	if binding_ids == other.binding_ids:
		return slot == other.slot
	for i in count():
		if binding_of(i) != other.binding_of(i):
			return false
	return true


## Canonical bytes (scatter.bin v2): table = referenced binding ids sorted byte-wise.
func encode() -> PackedByteArray:
	var used := {}
	for s in slot:
		used[binding_ids[s]] = true
	var ids := PackedStringArray(used.keys())
	ids.sort()
	var e := CanonicalEncoder.new()
	e.put_raw(MAGIC.to_ascii_buffer())
	e.put_u32(VERSION)
	e.put_u32(ids.size())
	for id in ids:
		e.put_str(id)
	_put_instances(e, _slot_to_index(func(s: int) -> String: return binding_ids[s], ids))
	return e.bytes()


## Table position per slot for the table `ids` (sorted keys); `key_of(slot)` names a slot's key.
func _slot_to_index(key_of: Callable, ids: PackedStringArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(binding_ids.size())
	for s in binding_ids.size():
		out[s] = ids.find(key_of.call(s))
	return out


func _put_instances(e: CanonicalEncoder, slot_to_index: PackedInt32Array) -> void:
	var n := count()
	e.put_u32(n)
	var block := PackedByteArray()
	block.resize(n * INSTANCE_BYTES)
	for i in n:
		var o := i * INSTANCE_BYTES
		block.encode_u16(o, slot_to_index[slot[i]])
		block.encode_u16(o + 2, flags[i])
		block.encode_float(o + 4, x[i])
		block.encode_float(o + 8, z[i])
		block.encode_float(o + 12, yaw[i])
		block.encode_float(o + 16, scale[i])
	e.put_raw(block)


## Canonical scatter.bin v1 bytes of the instances (schema 2/3 hash verification). `mapping` is
## {binding_id: [asset_id, asset_version]} for every referenced binding.
func encode_legacy_v1(mapping: Dictionary) -> PackedByteArray:
	var used := {}  # asset_id -> version
	for s in slot:
		var pair: Array = mapping[binding_ids[s]]
		used[pair[0]] = pair[1]
	var ids := PackedStringArray(used.keys())
	ids.sort()
	var e := CanonicalEncoder.new()
	e.put_raw(MAGIC.to_ascii_buffer())
	e.put_u32(LEGACY_VERSION)
	e.put_u32(ids.size())
	for id in ids:
		e.put_str(id)
		e.put_u32(used[id])
	_put_instances(e, _slot_to_index(func(s: int) -> String: return (mapping.get(binding_ids[s], ["", 0]) as Array)[0], ids))
	return e.bytes()


## scatter.bin v2, structure only: returns [ScatterLayer, ""] or [null, error]. Binding existence, extent,
## yaw-limit and scale rules belong to WorldValidator. `max_instances` is the schema's limit (WorldLimits).
static func decode(bytes: PackedByteArray, max_instances: int = WorldLimits.SCHEMA_4.max_scatter_instances) -> Array:
	var parsed := _decode(bytes, max_instances, VERSION)
	return [parsed[0], parsed[1]]


## scatter.bin v1 (schema 2/3): returns [ScatterLayer, "", PackedInt32Array versions] or [null, error, empty].
## The layer's `binding_ids` hold the catalog asset ids; the codec maps them to bindings.
static func decode_legacy_v1(bytes: PackedByteArray, max_instances: int) -> Array:
	return _decode(bytes, max_instances, LEGACY_VERSION)


static func _decode(bytes: PackedByteArray, max_instances: int, want_version: int) -> Array:
	var r := BinReader.new(bytes)
	var err := _decode_header(r, want_version)
	if err != "":
		return [null, err, PackedInt32Array()]
	var layer := ScatterLayer.new()
	var versions := PackedInt32Array()
	err = _decode_table(r, layer, versions, want_version)
	if err != "":
		return [null, err, PackedInt32Array()]
	err = _decode_instances(r, layer, max_instances)
	if err != "":
		return [null, err, PackedInt32Array()]
	return [layer, "", versions]


static func _decode_header(r: BinReader, want_version: int) -> String:
	if r.ascii(4) != MAGIC:
		return "scatter.bin: bad magic" if r.error == "" else "scatter.bin: " + r.error
	var version := r.u32("version")
	if r.error != "":
		return "scatter.bin: " + r.error
	if version != want_version:
		return "scatter.bin: unsupported version %d" % version
	return ""


static func _decode_table(r: BinReader, layer: ScatterLayer, versions: PackedInt32Array, want_version: int) -> String:
	var legacy := want_version == LEGACY_VERSION
	var entry_count := r.u32("binding_count")
	if r.error == "" and (entry_count > MAX_SLOTS or entry_count * (8 if legacy else 4) > r.remaining()):
		return "scatter.bin: binding_count %d is not plausible" % entry_count
	var prev := ""
	for i in entry_count:
		var id := r.text("binding_id", MAX_ASSET_ID_LEN if legacy else MAX_BINDING_ID_LEN)
		var version := r.u32("asset_version") if legacy else 0
		if r.error != "":
			break
		if i > 0 and not (prev < id):
			return "scatter.bin: binding table is not sorted and unique at '%s'" % id
		if not legacy and not AssetBinding.is_valid_id(id):
			return "scatter.bin: '%s' is not a binding id" % id
		prev = id
		layer.binding_ids.append(id)
		versions.append(version)
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
	used.resize(layer.binding_ids.size())
	for i in n:
		var s := r.u16("binding_index")
		var fl := r.u16("flags")
		var vals := [r.f32("x"), r.f32("z"), r.f32("yaw_rad"), r.f32("scale")]
		if s >= layer.binding_ids.size():
			return "scatter.bin: instance %d binding_index %d >= binding_count %d" % [i, s, layer.binding_ids.size()]
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
		return "scatter.bin: binding table lists bindings no instance uses"
	return ""
