"""Pinned schema constants and generation paths."""
from __future__ import annotations

from pathlib import Path
import re

REPO = Path(__file__).resolve().parent.parent
APP_DIR = REPO / "app"

# --- WorldConstants --------------------------------------------------------------------
FORMAT = "world-painter-poc"
SCHEMA_VERSION = 2
SAMPLE_SPACING = 0.5
REGION_SAMPLES = 256
REGION_SAMPLE_COUNT = REGION_SAMPLES * REGION_SAMPLES
REGION_MAP_BYTES = REGION_SAMPLE_COUNT * 4
REGION_LOCATIONS: list[tuple[int, int]] = [(-1, -1), (0, -1), (-1, 0), (0, 0)]
GLOBAL_SAMPLE_MIN = -256
GLOBAL_SAMPLE_MAX = 255
WORLD_MIN = -128.0
WORLD_MAX_SAMPLE = 127.5
HEIGHT_MIN = -32.0
HEIGHT_MAX = 64.0
MATERIAL_GRASS = 0
MATERIAL_DIRT = 1
MATERIAL_ROCK = 2
MATERIAL_SAND = 3
MATERIAL_SLOTS = {"0": "grass", "1": "dirt", "2": "rock", "3": "sand"}
HEIGHT_ENCODING = "float32-little-endian"
CONTROL_ENCODING = "uint32-little-endian"
CONTROL_SCHEMA = "terrain3d-1.0.2-control-v2"
COLOR_ENCODING = "rgba8-tint-v1"
DEFAULT_CONTROL = 0x00000001  # auto bit set, base 0, overlay 0, blend 0
DEFAULT_COLOR = b"\xff\xff\xff\x00"
GROUNDINGS = ("FOLLOW_TERRAIN", "WORLD_FIXED")
ORIGINS = ("MANUAL", "SCATTER")
# Auto-paint rules (world-format §3): key -> (kind, min, max); default values.
RULE_SPECS: dict[str, tuple[str, int, int]] = {
	"rock_enabled": ("bool", 0, 1),
	"rock_slope_deg": ("int", 10, 60),
	"sand_enabled": ("bool", 0, 1),
	"sand_height_dm": ("int", -30, 30),
}
DEFAULT_RULES: dict[str, bool | int] = {
	"rock_enabled": True, "rock_slope_deg": 30, "sand_enabled": True, "sand_height_dm": -4}

# --- Scatter / paths (world-format §5, §6) ---------------------------------------------
SCATTER_MAGIC = b"WPSC"
PATHS_MAGIC = b"WPPA"
SCATTER_VERSION = 1
PATHS_VERSION = 1
SCATTER_INSTANCE_BYTES = 20
SCATTER_MAX_INSTANCES = 20000
SCATTER_FLAG_TILT = 1
YAW_MAX = 3.1416
PATHS_MAX_COUNT = 256
PATH_MIN_POINTS = 2
PATH_MAX_POINTS = 256
PATH_WIDTH_MIN = 1.0
PATH_WIDTH_MAX = 6.0

TERRAIN_BLOCK = {
	"sample_spacing_m": SAMPLE_SPACING,
	"region_samples": REGION_SAMPLES,
	"region_locations": [list(loc) for loc in REGION_LOCATIONS],
	"height_encoding": HEIGHT_ENCODING,
	"control_encoding": CONTROL_ENCODING,
	"control_schema": CONTROL_SCHEMA,
	"color_encoding": COLOR_ENCODING,
	"material_slots": MATERIAL_SLOTS,
	"rules": DEFAULT_RULES,
}

# --- Package limits (world-format §9) --------------------------------------------------
MANIFEST_MAX_BYTES = 64 * 1024
OBJECTS_MAX_BYTES = 4 * 1024 * 1024
SCATTER_MAX_BYTES = 512 * 1024
PATHS_MAX_BYTES = 640 * 1024
PACKAGE_MAX_TOTAL_BYTES = 12 * 1024 * 1024
PACKAGE_MAX_FILE_BYTES = 20 * 1024 * 1024  # ZipInspector.default_limits().max_file_bytes
PACKAGE_MAX_ENTRIES = 20
MAX_OBJECTS = 2000
QUAT_TOLERANCE = 1e-6
GROUNDING_TOLERANCE_M = 1e-3

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
HEX16_RE = re.compile(r"^[0-9a-fA-F]{16}$")

AUTHORED_MAGIC = b"WPOC-AUTHORED-V2\n"
CATALOG_MAGIC = b"WPOC-CATALOG-V1\n"


def region_stem(loc: tuple[int, int]) -> str:
	return "regions/r_%d_%d" % (loc[0], loc[1])


def height_path(loc: tuple[int, int]) -> str:
	return region_stem(loc) + ".height.f32le"


def control_path(loc: tuple[int, int]) -> str:
	return region_stem(loc) + ".control.u32le"


def color_path(loc: tuple[int, int]) -> str:
	return region_stem(loc) + ".color.rgba8"


SCATTER_PATH = "scatter.bin"
PATHS_PATH = "paths.bin"
# Sorted byte-wise (ASCII str sort is byte-wise).
PAYLOAD_PATHS: list[str] = sorted(
	["objects.json", PATHS_PATH, SCATTER_PATH] + [height_path(l) for l in REGION_LOCATIONS]
	+ [control_path(l) for l in REGION_LOCATIONS] + [color_path(l) for l in REGION_LOCATIONS])
GENERATION_FILES: set[str] = set(PAYLOAD_PATHS) | {"manifest.json"}
