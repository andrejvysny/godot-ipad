class_name WorldConstants
extends RefCounted
## Fixed reference-world layout for the PoC (spec §3.1). Mirrors the pinned
## Terrain3D 1.0.2 sample grid: global sample g maps to world coordinate g * SAMPLE_SPACING,
## region = floor(g / REGION_SAMPLES). There is no duplicated seam row; the last valid
## sample is at +127.5 m, so bilinear sampling is valid on [WORLD_MIN, WORLD_MAX_SAMPLE].

const SCHEMA_VERSION := 2
const SAMPLE_SPACING := 0.5
const REGION_SAMPLES := 256
const REGION_SHIFT := 8  # log2(REGION_SAMPLES); arithmetic shift == floor division for negatives
const REGION_MASK := 255
const REGION_SAMPLE_COUNT := REGION_SAMPLES * REGION_SAMPLES
const REGION_MAP_BYTES := REGION_SAMPLE_COUNT * 4

## Region locations in canonical order: sorted by Z, then X (row-major).
const REGION_LOCATIONS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0),
]

const GLOBAL_SAMPLE_MIN := -256
const GLOBAL_SAMPLE_MAX := 255
const WORLD_MIN := -128.0
const WORLD_MAX_SAMPLE := 127.5

const HEIGHT_MIN := -32.0
const HEIGHT_MAX := 64.0

const MATERIAL_GRASS := 0
const MATERIAL_DIRT := 1
const MATERIAL_ROCK := 2
const MATERIAL_SAND := 3
const MATERIAL_SLOTS := {"0": "grass", "1": "dirt", "2": "rock", "3": "sand"}

## Auto bit set, base 0, overlay 0, blend 0: the auto-paint rule layer only.
const DEFAULT_CONTROL := 0x00000001
## Tint map bytes per sample R, G, B, A: white, weight 0 (no tint).
const DEFAULT_COLOR_BYTES := [0xFF, 0xFF, 0xFF, 0x00]

const RULE_ROCK_ENABLED_DEFAULT := true
const RULE_ROCK_SLOPE_DEFAULT := 30
const RULE_SAND_ENABLED_DEFAULT := true
const RULE_SAND_HEIGHT_DM_DEFAULT := -4
const RULE_ROCK_SLOPE_MIN := 10
const RULE_ROCK_SLOPE_MAX := 60
const RULE_SAND_HEIGHT_DM_MIN := -30
const RULE_SAND_HEIGHT_DM_MAX := 30

const MAX_SCATTER_INSTANCES := 20000
const MAX_PATHS := 256
const PATH_POINTS_MIN := 2
const PATH_POINTS_MAX := 256
const PATH_WIDTH_MIN := 1.0
const PATH_WIDTH_MAX := 6.0
const YAW_LIMIT := 3.1416

const HEIGHT_ENCODING := "float32-little-endian"
const CONTROL_ENCODING := "uint32-little-endian"
const CONTROL_SCHEMA := "terrain3d-1.0.2-control-v2"
const COLOR_ENCODING := "rgba8-tint-v1"

const SCATTER_FILE := "scatter.bin"
const PATHS_FILE := "paths.bin"

const GROUNDING_FOLLOW := "FOLLOW_TERRAIN"
const GROUNDING_FIXED := "WORLD_FIXED"
const ORIGIN_MANUAL := "MANUAL"
const ORIGIN_SCATTER := "SCATTER"

const PACKAGE_EXTENSION := "worldpoc"


static func region_file_stem(loc: Vector2i) -> String:
	return "regions/r_%d_%d" % [loc.x, loc.y]


static func is_valid_region(loc: Vector2i) -> bool:
	return REGION_LOCATIONS.has(loc)


static func is_valid_sample(gx: int, gz: int) -> bool:
	return gx >= GLOBAL_SAMPLE_MIN and gx <= GLOBAL_SAMPLE_MAX \
		and gz >= GLOBAL_SAMPLE_MIN and gz <= GLOBAL_SAMPLE_MAX


static func sample_region(g: int) -> int:
	return g >> REGION_SHIFT


static func sample_local(g: int) -> int:
	return g & REGION_MASK


## True when (x, z) lies inside the bilinear-sampleable extent.
static func is_inside_world(x: float, z: float) -> bool:
	return x >= WORLD_MIN and x <= WORLD_MAX_SAMPLE and z >= WORLD_MIN and z <= WORLD_MAX_SAMPLE


static func host_is_little_endian() -> bool:
	return PackedInt32Array([1]).to_byte_array()[0] == 1
