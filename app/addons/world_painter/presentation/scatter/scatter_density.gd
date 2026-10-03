class_name ScatterDensity
extends RefCounted
## Deterministic decorative thinning (spec §10). An instance's key is FNV-1a 32-bit over
## (asset_id UTF-8 bytes, x as float32 LE, z as float32 LE, world seed as u32 LE). It depends only on the
## instance itself, so adding or removing other instances never changes it. An instance is kept iff
## key / 2^32 < density: the kept sets of increasing densities are nested supersets by construction.

const FNV_OFFSET := 0x811C9DC5
const FNV_PRIME := 0x01000193
const RANGE := 4294967296.0


static func fnv1a(bytes: PackedByteArray, state: int = FNV_OFFSET) -> int:
	var h := state
	for b in bytes:
		h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF
	return h


static func world_seed(world_id: String) -> int:
	return fnv1a(world_id.to_utf8_buffer())


static func key(asset_id: String, x: float, z: float, seed_value: int) -> int:
	return keys_of(asset_id, PackedFloat32Array([x, z]).to_byte_array(), seed_value)[0]


static func keeps(key_value: int, density: float) -> bool:
	return float(key_value) < density * RANGE


## Keys of the instances whose float32 (x, z) pairs are `xz_bytes` (8 bytes per instance).
static func keys_of(asset_id: String, xz_bytes: PackedByteArray, seed_value: int) -> PackedInt64Array:
	var prefix := fnv1a(asset_id.to_utf8_buffer())
	var n := xz_bytes.size() / 8
	var out := PackedInt64Array()
	out.resize(n)
	var s0 := seed_value & 0xFF
	var s1 := (seed_value >> 8) & 0xFF
	var s2 := (seed_value >> 16) & 0xFF
	var s3 := (seed_value >> 24) & 0xFF
	for i in n:
		var h := prefix
		var o := i * 8
		for j in 8:
			h = ((h ^ xz_bytes[o + j]) * FNV_PRIME) & 0xFFFFFFFF
		h = ((h ^ s0) * FNV_PRIME) & 0xFFFFFFFF
		h = ((h ^ s1) * FNV_PRIME) & 0xFFFFFFFF
		h = ((h ^ s2) * FNV_PRIME) & 0xFFFFFFFF
		h = ((h ^ s3) * FNV_PRIME) & 0xFFFFFFFF
		out[i] = h
	return out


## Cached keys of one (cell, asset) list; appended instances extend the cache, any other change clears it.
static func cell_keys(cell: ScatterCell, asset_id: String, seed_value: int) -> PackedInt64Array:
	var keys: PackedInt64Array = cell.keys.get(asset_id, PackedInt64Array())
	var xz: PackedFloat32Array = cell.xz[asset_id]
	var n := xz.size() / 2
	if keys.size() < n:
		keys.append_array(keys_of(asset_id, xz.slice(keys.size() * 2).to_byte_array(), seed_value))
		cell.keys[asset_id] = keys
	return keys
