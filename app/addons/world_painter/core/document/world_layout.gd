class_name WorldLayout
extends RefCounted
## Rectangle of terrain regions (docs/world-format.md §11.1). Immutable after construction:
## never assign the public fields. The storage worker only ever sees min/count as plain
## values, so a layout is rebuilt there rather than shared.

const MAX_COUNT := 8
const REGION_MIN := -8
const REGION_MAX := 7

var min_region: Vector2i
var region_count: Vector2i

var _locations: Array[Vector2i] = []
var _sample_min: Vector2i
var _sample_max: Vector2i
var _world_min: Vector2
var _world_max: Vector2


## Does not validate; use create() or from_manifest() for untrusted values.
func _init(p_min: Vector2i = Vector2i(-1, -1), p_count: Vector2i = Vector2i(2, 2)) -> void:
	min_region = p_min
	region_count = p_count
	for z in p_count.y:
		for x in p_count.x:
			_locations.append(Vector2i(p_min.x + x, p_min.y + z))
	var rs := WorldConstants.REGION_SAMPLES
	_sample_min = Vector2i(rs * p_min.x, rs * p_min.y)
	_sample_max = Vector2i(rs * (p_min.x + p_count.x) - 1, rs * (p_min.y + p_count.y) - 1)
	var span := float(rs) * WorldConstants.SAMPLE_SPACING
	_world_min = Vector2(span * p_min.x, span * p_min.y)
	_world_max = Vector2(span * (p_min.x + p_count.x) - WorldConstants.SAMPLE_SPACING,
			span * (p_min.y + p_count.y) - WorldConstants.SAMPLE_SPACING)


static func legacy() -> WorldLayout:
	return WorldLayout.new(Vector2i(-1, -1), Vector2i(2, 2))


## The "1 km" preset: 8 x 8 regions, regions [-4, 3] on both axes.
static func km1() -> WorldLayout:
	return WorldLayout.new(Vector2i(-4, -4), Vector2i(8, 8))


## "" when valid. The legacy layout is valid here; schema 3 rejects it separately.
static func validate(p_min: Vector2i, p_count: Vector2i) -> String:
	if p_count.x < 1 or p_count.x > MAX_COUNT or p_count.y < 1 or p_count.y > MAX_COUNT:
		return "region_count %s must be within [1, %d] on both axes" % [str(p_count), MAX_COUNT]
	if p_min.x < REGION_MIN or p_min.x > REGION_MAX or p_min.y < REGION_MIN or p_min.y > REGION_MAX:
		return "min_region %s must be within [%d, %d] on both axes" % [str(p_min), REGION_MIN, REGION_MAX]
	if p_min.x + p_count.x > REGION_MAX + 1 or p_min.y + p_count.y > REGION_MAX + 1:
		return "min_region %s + region_count %s leaves the region range [%d, %d]" % [
			str(p_min), str(p_count), REGION_MIN, REGION_MAX]
	return ""


## Null when the values are invalid.
static func create(p_min: Vector2i, p_count: Vector2i) -> WorldLayout:
	if validate(p_min, p_count) != "":
		return null
	return WorldLayout.new(p_min, p_count)


## Returns [WorldLayout, ""] or [null, error]. `d` is the parsed JSON `terrain.layout` value:
## exactly {min_region: [int, int], region_count: [int, int]}; numbers arrive as floats.
static func from_manifest(d: Variant) -> Array:
	if typeof(d) != TYPE_DICTIONARY:
		return [null, "terrain.layout must be an object"]
	var dict: Dictionary = d
	for k in dict:
		if not (typeof(k) == TYPE_STRING and (k == "min_region" or k == "region_count")):
			return [null, "terrain.layout has unknown field '%s'" % str(k)]
	var vals := {}
	for key in ["min_region", "region_count"]:
		if not dict.has(key):
			return [null, "terrain.layout missing field '%s'" % key]
		var v: Variant = dict[key]
		if typeof(v) != TYPE_ARRAY or v.size() != 2 or not _is_int(v[0]) or not _is_int(v[1]):
			return [null, "terrain.layout.%s must be two integers" % key]
		vals[key] = Vector2i(int(v[0]), int(v[1]))
	var err := validate(vals.min_region, vals.region_count)
	if err != "":
		return [null, "terrain.layout: " + err]
	return [WorldLayout.new(vals.min_region, vals.region_count), ""]


static func _is_int(v: Variant) -> bool:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return false
	var f := float(v)
	return is_finite(f) and f == floorf(f) and absf(f) <= 1024.0


## Canonical order: sorted by Z, then X. Shared array: do not modify.
func region_locations() -> Array[Vector2i]:
	return _locations


func region_total() -> int:
	return _locations.size()


## Global sample range (x = X axis, y = Z axis), both inclusive.
func global_sample_min() -> Vector2i:
	return _sample_min


func global_sample_max() -> Vector2i:
	return _sample_max


func world_min() -> Vector2:
	return _world_min


## Last bilinear-sampleable coordinate (x = X axis, y = Z axis).
func world_max_sample() -> Vector2:
	return _world_max


func world_rect() -> Rect2:
	return Rect2(_world_min, _world_max - _world_min)


## Nominal extent (every region fully), including the half-metre past the last sample.
func extent_rect() -> Rect2:
	var span := float(WorldConstants.REGION_SAMPLES) * WorldConstants.SAMPLE_SPACING
	return Rect2(_world_min, Vector2(span * region_count.x, span * region_count.y))


func is_valid_region(loc: Vector2i) -> bool:
	return loc.x >= min_region.x and loc.x < min_region.x + region_count.x \
		and loc.y >= min_region.y and loc.y < min_region.y + region_count.y


func is_valid_sample(gx: int, gz: int) -> bool:
	return gx >= _sample_min.x and gx <= _sample_max.x and gz >= _sample_min.y and gz <= _sample_max.y


## True when (x, z) lies inside the bilinear-sampleable extent.
func is_inside_world(x: float, z: float) -> bool:
	return x >= _world_min.x and x <= _world_max.x and z >= _world_min.y and z <= _world_max.y


func is_legacy() -> bool:
	return min_region == Vector2i(-1, -1) and region_count == Vector2i(2, 2)


## Every layout is written as schema 4 (the legacy 2x2 layout included).
func schema_version() -> int:
	return WorldConstants.SCHEMA_VERSION_V4

## Schema 2/3 files of this layout: 2 for the legacy 2x2 layout, 3 for every other.
func legacy_schema_version() -> int:
	return WorldConstants.SCHEMA_VERSION if is_legacy() else WorldConstants.SCHEMA_VERSION_LAYOUT


func equals(other: WorldLayout) -> bool:
	return other != null and min_region == other.min_region and region_count == other.region_count


func to_manifest() -> Dictionary:
	return {"min_region": [min_region.x, min_region.y], "region_count": [region_count.x, region_count.y]}


func name() -> String:
	if is_legacy():
		return "legacy"
	if min_region == Vector2i(-4, -4) and region_count == Vector2i(8, 8):
		return "km1"
	return "custom"
