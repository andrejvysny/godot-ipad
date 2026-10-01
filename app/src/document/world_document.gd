class_name WorldDocument
extends RefCounted
## Canonical authored world (spec §10.1). Owns terrain bytes and object records; holds no
## nodes or platform objects. Terrain3D images and scene nodes are rebuildable projections.
## Tools mutate buffers only inside an EditTransaction that captured the before-values.

## Writers derive the schema from `layout.schema_version()`; this field mirrors it for readers.
var schema_version: int = WorldConstants.SCHEMA_VERSION
## Immutable region rectangle; replace the reference, never mutate it.
var layout: WorldLayout = WorldLayout.legacy()
var world_id: String = ""
var document_revision: int = 0
var catalog_id: String = ""
var catalog_version: int = 0
var catalog_sha256: String = ""
## Provenance of the loaded content (e.g. "fixture:gentle_hills"); not authored data.
var source_label: String = ""

var regions: Dictionary = {}  # Vector2i -> RegionBuffers
var objects: Dictionary = {}  # String object_id -> ObjectRecord
var rules: TerrainRules = TerrainRules.defaults()
var scatter: ScatterLayer = ScatterLayer.new()
var paths: Dictionary = {}  # String path_id -> PathRecord

var _height_range_cache: Dictionary = {}  # Vector2i -> Vector2(min, max)


static func create_flat(height: float, control_value: int, p_layout: WorldLayout = null) -> WorldDocument:
	var doc := WorldDocument.new()
	if p_layout != null:
		doc.layout = p_layout
		doc.schema_version = p_layout.schema_version()
	doc.world_id = ObjectRecord.new_uuid_v4()
	for loc in doc.layout.region_locations():
		doc.regions[loc] = RegionBuffers.filled(loc, height, control_value)
	return doc


func duplicate_deep() -> WorldDocument:
	var d := WorldDocument.new()
	d.schema_version = schema_version
	d.layout = layout
	d.world_id = world_id
	d.document_revision = document_revision
	d.catalog_id = catalog_id
	d.catalog_version = catalog_version
	d.catalog_sha256 = catalog_sha256
	d.source_label = source_label
	for loc in regions:
		d.regions[loc] = (regions[loc] as RegionBuffers).duplicate_deep()
	for id in objects:
		d.objects[id] = (objects[id] as ObjectRecord).clone()
	d.rules = rules.clone()
	d.scatter = scatter.clone()
	for id in paths:
		d.paths[id] = (paths[id] as PathRecord).clone()
	return d


func bump_revision() -> void:
	document_revision += 1


func get_region(loc: Vector2i) -> RegionBuffers:
	return regions.get(loc)


func sorted_region_locations() -> Array[Vector2i]:
	var locs: Array[Vector2i] = []
	for loc in regions:
		locs.append(loc)
	locs.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return locs


func sorted_object_ids() -> PackedStringArray:
	var ids := PackedStringArray(objects.keys())
	ids.sort()
	return ids


# --- Terrain samples -------------------------------------------------------------------

func get_height_at_sample(gx: int, gz: int) -> float:
	var r: RegionBuffers = regions.get(Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT))
	if r == null:
		return NAN
	return r.heights[(gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES + (gx & WorldConstants.REGION_MASK)]


## Packed tint R<<24 | G<<16 | B<<8 | A, or -1 when the sample is outside the loaded regions.
func get_color_at_sample(gx: int, gz: int) -> int:
	var r: RegionBuffers = regions.get(Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT))
	if r == null:
		return -1
	var o := ((gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES + (gx & WorldConstants.REGION_MASK)) * 4
	return (r.color[o] << 24) | (r.color[o + 1] << 16) | (r.color[o + 2] << 8) | r.color[o + 3]


func get_control_at_sample(gx: int, gz: int) -> int:
	var r: RegionBuffers = regions.get(Vector2i(gx >> WorldConstants.REGION_SHIFT, gz >> WorldConstants.REGION_SHIFT))
	if r == null:
		return -1
	return r.control[(gz & WorldConstants.REGION_MASK) * WorldConstants.REGION_SAMPLES + (gx & WorldConstants.REGION_MASK)] & 0xFFFFFFFF


## Bilinear height matching Terrain3DData.get_height for the pinned revision. NAN outside
## the loaded extent or inside a hole cell; callers must treat NAN as "no sample", never as zero.
func sample_height(x: float, z: float) -> float:
	if not layout.is_inside_world(x, z):
		return NAN
	var fx := x / WorldConstants.SAMPLE_SPACING
	var fz := z / WorldConstants.SAMPLE_SPACING
	var gx := floori(fx)
	var gz := floori(fz)
	var tx := fx - gx
	var tz := fz - gz
	# Hole ownership is the containing control cell, not interpolated neighboring flags.
	if (get_control_at_sample(gx, gz) & ControlCodec.HOLE_BIT) != 0:
		return NAN
	var h00 := get_height_at_sample(gx, gz)
	if tx == 0.0 and tz == 0.0:
		return h00
	# At the max edge the +1 neighbor is missing; its weight is zero there, so clamp the index.
	var sample_max := layout.global_sample_max()
	var gx1 := mini(gx + 1, sample_max.x)
	var gz1 := mini(gz + 1, sample_max.y)
	var h10 := get_height_at_sample(gx1, gz)
	var h01 := get_height_at_sample(gx, gz1)
	var h11 := get_height_at_sample(gx1, gz1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Central-difference normal; NAN vector outside the extent.
func sample_normal(x: float, z: float) -> Vector3:
	var h := sample_height(x, z)
	if is_nan(h):
		return Vector3(NAN, NAN, NAN)
	var d := WorldConstants.SAMPLE_SPACING
	var hx0 := _height_or(x - d, z, h)
	var hx1 := _height_or(x + d, z, h)
	var hz0 := _height_or(x, z - d, h)
	var hz1 := _height_or(x, z + d, h)
	return Vector3(hx0 - hx1, 2.0 * d, hz0 - hz1).normalized()


func _height_or(x: float, z: float, fallback: float) -> float:
	var h := sample_height(x, z)
	return fallback if is_nan(h) else h


## Must be called after any height mutation of `loc` so picking bounds stay correct.
func invalidate_height_range(loc: Vector2i) -> void:
	_height_range_cache.erase(loc)


func invalidate_all_height_ranges() -> void:
	_height_range_cache.clear()


func region_height_range(loc: Vector2i) -> Vector2:
	if _height_range_cache.has(loc):
		return _height_range_cache[loc]
	var r: RegionBuffers = regions.get(loc)
	if r == null:
		return Vector2(NAN, NAN)
	var lo := INF
	var hi := -INF
	for h in r.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	var result := Vector2(lo, hi)
	_height_range_cache[loc] = result
	return result


func height_range() -> Vector2:
	var lo := INF
	var hi := -INF
	for loc in regions:
		var r := region_height_range(loc)
		lo = minf(lo, r.x)
		hi = maxf(hi, r.y)
	return Vector2(lo, hi)


# --- Objects ---------------------------------------------------------------------------

func get_object(id: String) -> ObjectRecord:
	return objects.get(id)


## Stores `record` (the caller must not keep mutating it; clone first).
func put_object(record: ObjectRecord) -> void:
	objects[record.object_id] = record


func remove_object(id: String) -> void:
	objects.erase(id)


# --- Paths -----------------------------------------------------------------------------

func get_path_record(id: String) -> PathRecord:
	return paths.get(id)


## Stores `record` (the caller must not keep mutating it; clone first).
func put_path(record: PathRecord) -> void:
	paths[record.path_id] = record


func remove_path(id: String) -> void:
	paths.erase(id)


func sorted_path_ids() -> PackedStringArray:
	var ids := PackedStringArray(paths.keys())
	ids.sort()
	return ids
