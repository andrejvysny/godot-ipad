"""Pinned schema constants and generation paths."""
from __future__ import annotations

from pathlib import Path
import re

REPO = Path(__file__).resolve().parent.parent
APP_DIR = REPO / "app"

# --- WorldConstants --------------------------------------------------------------------
FORMAT = "world-painter-poc"
SCHEMA_VERSION = 1
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
MATERIAL_SLOTS = {"0": "grass", "1": "dirt"}
HEIGHT_ENCODING = "float32-little-endian"
CONTROL_ENCODING = "uint32-little-endian"
CONTROL_SCHEMA = "terrain3d-1.0.2-control-v1"
GROUNDINGS = ("FOLLOW_TERRAIN", "WORLD_FIXED")
ORIGINS = ("MANUAL", "SCATTER")
TERRAIN_BLOCK = {
	"sample_spacing_m": SAMPLE_SPACING,
	"region_samples": REGION_SAMPLES,
	"region_locations": [list(loc) for loc in REGION_LOCATIONS],
	"height_encoding": HEIGHT_ENCODING,
	"control_encoding": CONTROL_ENCODING,
	"control_schema": CONTROL_SCHEMA,
	"material_slots": MATERIAL_SLOTS,
}

# --- Package limits (world-format §7) --------------------------------------------------
MANIFEST_MAX_BYTES = 64 * 1024
OBJECTS_MAX_BYTES = 4 * 1024 * 1024
PACKAGE_MAX_TOTAL_BYTES = 8 * 1024 * 1024
PACKAGE_MAX_FILE_BYTES = 16 * 1024 * 1024  # ZipInspector.default_limits().max_file_bytes
MAX_OBJECTS = 2000
QUAT_TOLERANCE = 1e-6
GROUNDING_TOLERANCE_M = 1e-3

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
HEX16_RE = re.compile(r"^[0-9a-fA-F]{16}$")

AUTHORED_MAGIC = b"WPOC-AUTHORED-V1\n"
CATALOG_MAGIC = b"WPOC-CATALOG-V1\n"


def region_stem(loc: tuple[int, int]) -> str:
	return "regions/r_%d_%d" % (loc[0], loc[1])


def height_path(loc: tuple[int, int]) -> str:
	return region_stem(loc) + ".height.f32le"


def control_path(loc: tuple[int, int]) -> str:
	return region_stem(loc) + ".control.u32le"


PAYLOAD_PATHS: list[str] = sorted(
	["objects.json"] + [height_path(l) for l in REGION_LOCATIONS] + [control_path(l) for l in REGION_LOCATIONS])
GENERATION_FILES: set[str] = set(PAYLOAD_PATHS) | {"manifest.json"}
