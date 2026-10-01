class_name TerrainRules
extends RefCounted
## Auto-paint rules stored in the manifest (docs/world-format.md §1.1, §3). Integers keep
## the values exact without f64le: slope in degrees, sand height in decimetres.

const LAYER_NAMES: Array[String] = ["Grass", "Dirt", "Rock", "Sand"]
const KEYS := ["rock_enabled", "rock_slope_deg", "sand_enabled", "sand_height_dm"]

var rock_enabled: bool = WorldConstants.RULE_ROCK_ENABLED_DEFAULT
var rock_slope_deg: int = WorldConstants.RULE_ROCK_SLOPE_DEFAULT
var sand_enabled: bool = WorldConstants.RULE_SAND_ENABLED_DEFAULT
var sand_height_dm: int = WorldConstants.RULE_SAND_HEIGHT_DM_DEFAULT


static func defaults() -> TerrainRules:
	return TerrainRules.new()


func clone() -> TerrainRules:
	var r := TerrainRules.new()
	r.rock_enabled = rock_enabled
	r.rock_slope_deg = rock_slope_deg
	r.sand_enabled = sand_enabled
	r.sand_height_dm = sand_height_dm
	return r


func equals(other: TerrainRules) -> bool:
	return other != null and rock_enabled == other.rock_enabled \
		and rock_slope_deg == other.rock_slope_deg and sand_enabled == other.sand_enabled \
		and sand_height_dm == other.sand_height_dm


## "" when every value is inside its documented range.
func range_error() -> String:
	if rock_slope_deg < WorldConstants.RULE_ROCK_SLOPE_MIN or rock_slope_deg > WorldConstants.RULE_ROCK_SLOPE_MAX:
		return "rules.rock_slope_deg %d outside [%d, %d]" % [rock_slope_deg,
			WorldConstants.RULE_ROCK_SLOPE_MIN, WorldConstants.RULE_ROCK_SLOPE_MAX]
	if sand_height_dm < WorldConstants.RULE_SAND_HEIGHT_DM_MIN or sand_height_dm > WorldConstants.RULE_SAND_HEIGHT_DM_MAX:
		return "rules.sand_height_dm %d outside [%d, %d]" % [sand_height_dm,
			WorldConstants.RULE_SAND_HEIGHT_DM_MIN, WorldConstants.RULE_SAND_HEIGHT_DM_MAX]
	return ""


func to_dict() -> Dictionary:
	return {
		"rock_enabled": rock_enabled,
		"rock_slope_deg": rock_slope_deg,
		"sand_enabled": sand_enabled,
		"sand_height_dm": sand_height_dm,
	}


## Returns [TerrainRules, ""] or [null, error]. JSON numbers arrive as floats.
static func from_dict(v: Variant) -> Array:
	if typeof(v) != TYPE_DICTIONARY:
		return [null, "rules must be an object"]
	for k in KEYS:
		if not v.has(k):
			return [null, "rules missing field '%s'" % k]
	for k in v:
		if not KEYS.has(k):
			return [null, "rules has unknown field '%s'" % str(k)]
	for k in ["rock_enabled", "sand_enabled"]:
		if typeof(v[k]) != TYPE_BOOL:
			return [null, "rules.%s must be a boolean" % k]
	for k in ["rock_slope_deg", "sand_height_dm"]:
		if not _is_integral(v[k]):
			return [null, "rules.%s must be an integer" % k]
	var r := TerrainRules.new()
	r.rock_enabled = v.rock_enabled
	r.rock_slope_deg = int(v.rock_slope_deg)
	r.sand_enabled = v.sand_enabled
	r.sand_height_dm = int(v.sand_height_dm)
	var err := r.range_error()
	return [null, err] if err != "" else [r, ""]


## CPU mirror of the shader rule (docs/world-format.md §1.1): grass, sand below the sand height,
## rock above the slope (rock wins), hard edges. -1 when there is no surface sample.
static func material_at(doc: WorldDocument, x: float, z: float) -> int:
	var h := doc.sample_height(x, z)
	if is_nan(h):
		return -1
	var n := doc.sample_normal(x, z)
	var slope_deg := rad_to_deg(acos(clampf(n.y, 0.0, 1.0)))
	var r := doc.rules
	if r.rock_enabled and slope_deg > float(r.rock_slope_deg):
		return WorldConstants.MATERIAL_ROCK
	if r.sand_enabled and h < float(r.sand_height_dm) / 10.0:
		return WorldConstants.MATERIAL_SAND
	return WorldConstants.MATERIAL_GRASS


static func _is_integral(x: Variant) -> bool:
	if typeof(x) != TYPE_FLOAT and typeof(x) != TYPE_INT:
		return false
	var f := float(x)
	return is_finite(f) and f == floorf(f) and absf(f) <= 1.0e9
