class_name LiveTiles
extends RefCounted
## 64x64-sample tiles of the 256x256 region maps (INT-SPEC-1.1 §10.4). Every map is handled as its little-endian
## byte image (262144 bytes, 4 bytes per sample, row-major), so one code path serves height_f32le, control_u32le
## and color_rgba8. A tile is 64 rows of 256 bytes = 16384 bytes. Callers must have checked little-endian hosts.

const TILE := 64
const TILES_PER_SIDE := 4
const TILE_BYTES := 16384
const ROW_BYTES := 1024  # one region row
const TILE_ROW_BYTES := 256
const BAND_BYTES := TILE * ROW_BYTES  # one row of tiles
const KIND_HEIGHT := "height_f32le"
const KIND_CONTROL := "control_u32le"
const KIND_COLOR := "color_rgba8"
const KINDS: Array[String] = [KIND_HEIGHT, KIND_CONTROL, KIND_COLOR]
const SCATTER_TILE_METERS := 32.0  # 64 samples * 0.5 m


static func bytes_of_region(r: RegionBuffers, kind: String) -> PackedByteArray:
	match kind:
		KIND_HEIGHT:
			return r.heights.to_byte_array()
		KIND_CONTROL:
			return r.control.to_byte_array()
	return r.color.duplicate()


## Byte image of a map array held by a WorldChange (PackedFloat32/Int32/Byte array).
static func bytes_of_array(kind: String, values: Variant) -> PackedByteArray:
	if kind == KIND_COLOR:
		return (values as PackedByteArray).duplicate()
	return (values as PackedFloat32Array).to_byte_array() if kind == KIND_HEIGHT \
		else (values as PackedInt32Array).to_byte_array()


## Writes the byte image back into the region (a fresh typed array; the old one stays valid for rollback).
static func set_region_bytes(r: RegionBuffers, kind: String, bytes: PackedByteArray) -> void:
	match kind:
		KIND_HEIGHT:
			r.heights = bytes.to_float32_array()
		KIND_CONTROL:
			r.control = bytes.to_int32_array()
		_:
			r.color = bytes


static func tile(bytes: PackedByteArray, tx: int, tz: int) -> PackedByteArray:
	var out := PackedByteArray()
	var o := tz * BAND_BYTES + tx * TILE_ROW_BYTES
	for row in TILE:
		out.append_array(bytes.slice(o, o + TILE_ROW_BYTES))
		o += ROW_BYTES
	return out


## Tile coordinates whose bytes differ. Equal arrays and equal tile rows are skipped with native comparisons.
static func changed_tiles(a: PackedByteArray, b: PackedByteArray) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if a == b:
		return out
	for tz in TILES_PER_SIDE:
		var lo := tz * BAND_BYTES
		if a.slice(lo, lo + BAND_BYTES) == b.slice(lo, lo + BAND_BYTES):
			continue
		for tx in TILES_PER_SIDE:
			if tile(a, tx, tz) != tile(b, tx, tz):
				out.append(Vector2i(tx, tz))
	return out


## `updates`: Vector2i(tx, tz) -> 16384-byte tile. Returns base unchanged when there is nothing to write.
@warning_ignore("integer_division")
static func compose(base: PackedByteArray, updates: Dictionary) -> PackedByteArray:
	if updates.is_empty():
		return base
	var out := PackedByteArray()
	for row in WorldConstants.REGION_SAMPLES:
		var tz := row / TILE
		var ro := row * ROW_BYTES
		var local := (row % TILE) * TILE_ROW_BYTES
		for tx in TILES_PER_SIDE:
			var u: Variant = updates.get(Vector2i(tx, tz))
			if u == null:
				out.append_array(base.slice(ro + tx * TILE_ROW_BYTES, ro + (tx + 1) * TILE_ROW_BYTES))
			else:
				out.append_array((u as PackedByteArray).slice(local, local + TILE_ROW_BYTES))
	return out


static func region_stem(loc: Vector2i) -> String:
	return "r_%d_%d" % [loc.x, loc.y]


## Archive member of a terrain tile (matches delta.schema.json safe_member).
static func member_path(loc: Vector2i, tx: int, tz: int, kind: String) -> String:
	return "tiles/%s.t%d_%d.%s" % [region_stem(loc), tx, tz, kind]


static func scatter_member_path(loc: Vector2i, tx: int, tz: int) -> String:
	return "scatter/%s.t%d_%d.wpst" % [region_stem(loc), tx, tz]


## World-space XZ rectangle covered by a tile.
static func world_rect(loc: Vector2i, tx: int, tz: int) -> Rect2:
	var x0 := float(loc.x * WorldConstants.REGION_SAMPLES + tx * TILE) * WorldConstants.SAMPLE_SPACING
	var z0 := float(loc.y * WorldConstants.REGION_SAMPLES + tz * TILE) * WorldConstants.SAMPLE_SPACING
	return Rect2(x0, z0, SCATTER_TILE_METERS, SCATTER_TILE_METERS)


## {loc, tx, tz} of the tile containing world point (x, z).
@warning_ignore("integer_division")
static func tile_at(x: float, z: float) -> Dictionary:
	var gx := floori(x / WorldConstants.SAMPLE_SPACING)
	var gz := floori(z / WorldConstants.SAMPLE_SPACING)
	return {"loc": Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT),
		"tx": (gx & WorldConstants.REGION_MASK) / TILE, "tz": (gz & WorldConstants.REGION_MASK) / TILE}
