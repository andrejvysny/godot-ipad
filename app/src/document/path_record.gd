class_name PathRecord
extends RefCounted
## One spline path (docs/world-format.md §6): control points (x, z) and a ribbon width.
## Width and points are float32 on disk, so they are always held float32-rounded
## (PackedVector2Array is float32 in a default Godot build) and round-trip bit-exactly.

const MAGIC := "WPPA"
const VERSION := 1

var path_id: String = ""
var width_m: float = WorldConstants.PATH_WIDTH_MIN:
	set(v):
		width_m = PackedFloat32Array([v])[0]
var points := PackedVector2Array()


func clone() -> PathRecord:
	var c := PathRecord.new()
	c.path_id = path_id
	c.width_m = width_m
	c.points = points.duplicate()
	return c


func equals(other: PathRecord) -> bool:
	return other != null and path_id == other.path_id and width_m == other.width_m and points == other.points


## Bounding rect of the control points (zero rect when empty).
func bounds() -> Rect2:
	if points.is_empty():
		return Rect2()
	var r := Rect2(points[0], Vector2.ZERO)
	for p in points:
		r = r.expand(p)
	return r


## Canonical bytes: paths sorted by id byte-wise.
static func encode_all(paths: Dictionary) -> PackedByteArray:
	var ids := PackedStringArray(paths.keys())
	ids.sort()
	var e := CanonicalEncoder.new()
	e.put_raw(MAGIC.to_ascii_buffer())
	e.put_u32(VERSION)
	e.put_u32(ids.size())
	for id in ids:
		var rec: PathRecord = paths[id]
		e.put_str(id)
		e.put_f32(rec.width_m)
		e.put_u32(rec.points.size())
		var block := PackedByteArray()
		block.resize(rec.points.size() * 8)
		for i in rec.points.size():
			block.encode_float(i * 8, rec.points[i].x)
			block.encode_float(i * 8 + 4, rec.points[i].y)
		e.put_raw(block)
	return e.bytes()


## Structure only: returns [{id: PathRecord}, ""] or [null, error]. Extent is checked by
## WorldValidator.
static func decode_all(bytes: PackedByteArray) -> Array:
	var r := BinReader.new(bytes)
	if r.ascii(4) != MAGIC:
		return [null, "paths.bin: bad magic" if r.error == "" else "paths.bin: " + r.error]
	var version := r.u32("version")
	var n := r.u32("path_count")
	if r.error != "":
		return [null, "paths.bin: " + r.error]
	if version != VERSION:
		return [null, "paths.bin: unsupported version %d" % version]
	if n > WorldConstants.MAX_PATHS:
		return [null, "paths.bin: %d paths exceed the limit of %d" % [n, WorldConstants.MAX_PATHS]]
	var out := {}
	var prev := ""
	for i in n:
		var parsed := _decode_one(r)
		if parsed[1] != "":
			return [null, "paths.bin: " + parsed[1]]
		var rec: PathRecord = parsed[0]
		if i > 0 and not (prev < rec.path_id):
			return [null, "paths.bin: path ids are not sorted and unique at %s" % rec.path_id]
		prev = rec.path_id
		out[rec.path_id] = rec
	if not r.at_end():
		return [null, "paths.bin: %d trailing bytes" % r.remaining()]
	return [out, ""]


static func _decode_one(r: BinReader) -> Array:
	var rec := PathRecord.new()
	rec.path_id = r.text("path_id", 64)
	var width := r.f32("width_m")
	var count := r.u32("point_count")
	if r.error != "":
		return [null, r.error]
	if not ObjectRecord.is_uuid(rec.path_id):
		return [null, "path_id '%s' is not a lowercase UUID" % rec.path_id]
	if not (width >= WorldConstants.PATH_WIDTH_MIN and width <= WorldConstants.PATH_WIDTH_MAX):
		return [null, "path %s width %s outside [%s, %s]" % [rec.path_id, width,
			WorldConstants.PATH_WIDTH_MIN, WorldConstants.PATH_WIDTH_MAX]]
	if count < WorldConstants.PATH_POINTS_MIN or count > WorldConstants.PATH_POINTS_MAX:
		return [null, "path %s has %d points, allowed %d..%d" % [rec.path_id, count,
			WorldConstants.PATH_POINTS_MIN, WorldConstants.PATH_POINTS_MAX]]
	if count * 8 > r.remaining():
		return [null, "truncated while reading points of path %s" % rec.path_id]
	rec.width_m = width
	for i in count:
		var px := r.f32("point x")
		var pz := r.f32("point z")
		if not (is_finite(px) and is_finite(pz)):
			return [null, "path %s point %d is not finite" % [rec.path_id, i]]
		rec.points.append(Vector2(px, pz))
	return [rec, ""]
