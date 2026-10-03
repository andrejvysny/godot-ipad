class_name ScatterPlacer
extends RefCounted
## Candidate test and insertion for scattered instances (docs/editor-v2.md §6). Pure logic over
## a document's ScatterLayer; the caller captures the layer for history before the first add.
## All randomness comes from the injected seed, so a seed reproduces a result exactly.

enum Result { ADDED, NO_SOURCE, NO_SAMPLE, SLOPE, SPACING, OBJECT, LIMIT, OUTSIDE }

const SCALE_MARGIN := 1e-5  # keeps the float32-rounded scale inside the catalog range
const OBJECT_PAD_FACTOR := 0.5

var limit_reached := false
var max_instances := 0  # WorldLimits scatter limit of the document's schema
var added := 0

var _doc: WorldDocument
var _index: ScatterIndex
var _rng := RandomNumberGenerator.new()
var _assets: Array[AssetDefinition] = []
var _bindings := PackedStringArray()  # binding id per _assets entry
var _cumulative := PackedFloat64Array()
var _slope_min := 0.0
var _slope_max := 90.0
var _spacing := 1.0
var _align := false
var _avoid: Array[Vector3] = []  # x, z, footprint radius of manual objects


## `config` is ToolCommands.scatter_config(). `avoid` enables the manual-object clearance.
func _init(doc: WorldDocument, catalog: AssetCatalog, config: Dictionary, avoid: bool,
		seed_value: int, index: ScatterIndex = null) -> void:
	_doc = doc
	max_instances = int(WorldLimits.for_schema(doc.schema_version).max_scatter_instances)
	_index = index if index != null else ScatterIndex.new(doc.scatter)
	_rng.seed = seed_value
	_slope_min = float(config.get("slope_min", 0.0))
	_slope_max = float(config.get("slope_max", 90.0))
	_spacing = float(config.get("spacing", 1.0))
	_align = bool(config.get("align", false))
	var total := 0.0
	for item: Dictionary in config.get("items", []):
		var asset := catalog.get_asset(str(item.asset_id))
		var binding_id := doc.assets.bundled_binding_for(asset.asset_id) if asset != null else ""
		if asset != null and asset.scatter_allowed and binding_id != "":
			total += float(item.weight)
			_assets.append(asset)
			_bindings.append(binding_id)
			_cumulative.append(total)
	if avoid:
		_collect_objects()


func limit_message() -> String:
	return "Scatter limit reached (%d)." % max_instances


func index() -> ScatterIndex:
	return _index


func rng() -> RandomNumberGenerator:
	return _rng


func has_source() -> bool:
	return not _assets.is_empty()


func try_add(x: float, z: float) -> Result:
	if _assets.is_empty():
		return Result.NO_SOURCE
	if _doc.scatter.count() >= max_instances:
		limit_reached = true
		return Result.LIMIT
	if not _doc.layout.is_inside_world(x, z):
		return Result.OUTSIDE
	var normal := _doc.sample_normal(x, z)
	if not normal.is_finite():
		return Result.NO_SAMPLE
	var slope := rad_to_deg(acos(clampf(normal.y, -1.0, 1.0)))
	if slope < _slope_min or slope > _slope_max:
		return Result.SLOPE
	var asset := _pick_asset()
	var min_dist := maxf(_spacing, 0.8 * asset.footprint_radius_m)
	if _index.has_within(x, z, min_dist):
		return Result.SPACING
	if _near_object(x, z, min_dist):
		return Result.OBJECT
	_insert(asset, x, z)
	return Result.ADDED


func _insert(asset: AssetDefinition, x: float, z: float) -> void:
	var binding_id := _bindings[_assets.find(asset)]
	var scale_value := _rng.randf_range(asset.scale_min, asset.scale_max)
	scale_value = clampf(scale_value, asset.scale_min + SCALE_MARGIN, asset.scale_max - SCALE_MARGIN)
	var yaw := _rng.randf_range(-PI, PI)
	var flags := ScatterLayer.FLAG_TILT if _align else 0
	if _doc.scatter.add(binding_id, x, z, yaw, scale_value, flags, max_instances):
		_index.add_last()
		added += 1


func _pick_asset() -> AssetDefinition:
	var roll := _rng.randf() * _cumulative[_cumulative.size() - 1]
	for i in _assets.size():
		if roll < _cumulative[i]:
			return _assets[i]
	return _assets[_assets.size() - 1]


func _near_object(x: float, z: float, min_dist: float) -> bool:
	for o in _avoid:
		var dx := o.x - x
		var dz := o.y - z
		var reach := o.z + OBJECT_PAD_FACTOR * min_dist
		if dx * dx + dz * dz <= reach * reach:
			return true
	return false


func _collect_objects() -> void:
	for id in _doc.sorted_object_ids():
		var rec := _doc.get_object(id)
		if rec.origin != WorldConstants.ORIGIN_MANUAL:
			continue
		var asset := _doc.assets.definition(rec.binding_id)
		var footprint := asset.footprint_radius_m if asset != null else 0.0
		_avoid.append(Vector3(rec.position[0], rec.position[2], footprint * rec.uniform_scale))
