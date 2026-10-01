"""Pinned schema constants and generation paths."""
from __future__ import annotations

from pathlib import Path
import math
import re
from typing import Any

REPO = Path(__file__).resolve().parent.parent
APP_DIR = REPO / "app"

# --- WorldConstants --------------------------------------------------------------------
FORMAT = "world-painter-poc"
SCHEMA_VERSION = 2  # legacy 2x2 layout; also the schema every pre-layout world uses
SCHEMA_VERSION_LAYOUT = 3  # layout worlds (world-format §11)
SUPPORTED_SCHEMAS = (SCHEMA_VERSION, SCHEMA_VERSION_LAYOUT)
SAMPLE_SPACING = 0.5
REGION_SAMPLES = 256
REGION_SAMPLE_COUNT = REGION_SAMPLES * REGION_SAMPLES
REGION_MAP_BYTES = REGION_SAMPLE_COUNT * 4
REGION_LOCATIONS: list[tuple[int, int]] = [(-1, -1), (0, -1), (-1, 0), (0, 0)]  # legacy layout only
GLOBAL_SAMPLE_MIN = -256  # legacy layout only
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
SCATTER_FLAG_TILT = 1
YAW_MAX = 3.1416
PATHS_MAX_COUNT = 256
PATH_MIN_POINTS = 2
PATH_MAX_POINTS = 256
PATH_WIDTH_MIN = 1.0
PATH_WIDTH_MAX = 6.0

TERRAIN_BLOCK = {  # schema 2; terrain_block(layout) builds the schema 3 variant
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

# --- Layouts (world-format §11.1) -------------------------------------------------------
# A layout is (min_region, region_count), each an (x, z) tuple.
Layout = tuple[tuple[int, int], tuple[int, int]]
LEGACY_LAYOUT: Layout = ((-1, -1), (2, 2))
KM1_LAYOUT: Layout = ((-4, -4), (8, 8))
LAYOUT_COUNT_MAX = 8
REGION_COORD_MIN = -8
REGION_COORD_MAX = 7


def validate_layout(min_region: tuple[int, int], count: tuple[int, int]) -> str:
	"""'' when valid (the legacy layout is valid here; schema 3 rejects it separately)."""
	if not all(1 <= c <= LAYOUT_COUNT_MAX for c in count):
		return "region_count %s must be within [1, %d] on both axes" % (list(count), LAYOUT_COUNT_MAX)
	if not all(REGION_COORD_MIN <= m <= REGION_COORD_MAX for m in min_region):
		return "min_region %s must be within [%d, %d] on both axes" % (list(min_region), REGION_COORD_MIN, REGION_COORD_MAX)
	if any(m + c > REGION_COORD_MAX + 1 for m, c in zip(min_region, count)):
		return "min_region %s + region_count %s leaves the region range [%d, %d]" % (
			list(min_region), list(count), REGION_COORD_MIN, REGION_COORD_MAX)
	return ""


def layout_regions(min_region: tuple[int, int], count: tuple[int, int]) -> list[tuple[int, int]]:
	"""Canonical order: sorted by Z, then X."""
	return [(min_region[0] + x, min_region[1] + z) for z in range(count[1]) for x in range(count[0])]


def layout_schema(layout: Layout) -> int:
	return SCHEMA_VERSION if layout == LEGACY_LAYOUT else SCHEMA_VERSION_LAYOUT


def layout_sample_range(layout: Layout) -> tuple[tuple[int, int], tuple[int, int]]:
	"""((gx_min, gx_max), (gz_min, gz_max)), both inclusive."""
	(mx, mz), (cx, cz) = layout
	return (REGION_SAMPLES * mx, REGION_SAMPLES * (mx + cx) - 1), (REGION_SAMPLES * mz, REGION_SAMPLES * (mz + cz) - 1)


def layout_extent(layout: Layout) -> tuple[float, float, float, float]:
	"""(x_min, x_max, z_min, z_max) of the bilinear-sampleable extent in metres."""
	(mx, mz), (cx, cz) = layout
	span = REGION_SAMPLES * SAMPLE_SPACING
	return (span * mx, span * (mx + cx) - SAMPLE_SPACING, span * mz, span * (mz + cz) - SAMPLE_SPACING)


def layout_to_manifest(layout: Layout) -> dict[str, list[int]]:
	return {"min_region": list(layout[0]), "region_count": list(layout[1])}


def layout_from_manifest(d: Any) -> tuple[Layout | None, str]:
	"""Parses terrain.layout (exactly min_region/region_count, integral numbers)."""
	if not isinstance(d, dict):
		return None, "terrain.layout must be an object"
	for key in sorted(d, key=str):
		if key not in ("min_region", "region_count"):
			return None, "terrain.layout has unknown field %r" % (key,)
	vals: dict[str, tuple[int, int]] = {}
	for key in ("min_region", "region_count"):
		if key not in d:
			return None, "terrain.layout missing field '%s'" % key
		v = d[key]
		if not (isinstance(v, list) and len(v) == 2 and all(_is_integral(c) for c in v)):
			return None, "terrain.layout.%s must be two integers" % key
		vals[key] = (int(v[0]), int(v[1]))
	err = validate_layout(vals["min_region"], vals["region_count"])
	if err:
		return None, "terrain.layout: " + err
	return (vals["min_region"], vals["region_count"]), ""


def _is_integral(v: Any) -> bool:
	return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v == math.floor(v) and abs(v) <= 1024


# --- Limits (world-format §11.3; mirrors app/src/document/world_limits.gd) -------------
_LIMITS_V2: dict[str, int] = {
	"max_regions": 4,
	"max_objects": 2000,
	"max_objects_bytes": 4 * 1024 * 1024,
	"max_scatter_instances": 20000,
	"max_scatter_bytes": 512 * 1024,
	"max_paths_bytes": 640 * 1024,
	"max_manifest_bytes": 64 * 1024,
	"max_total_bytes": 12 * 1024 * 1024,
	"max_archive_bytes": 20 * 1024 * 1024,
	"max_entries": 20,
}
_LIMITS_V3: dict[str, int] = {
	"max_regions": 64,
	"max_objects": 50000,
	"max_objects_bytes": 128 * 1024 * 1024,
	"max_scatter_instances": 100000,
	"max_scatter_bytes": 4 * 1024 * 1024,
	"max_paths_bytes": 640 * 1024,
	"max_manifest_bytes": 256 * 1024,
	"max_total_bytes": 256 * 1024 * 1024,
	"max_archive_bytes": 264 * 1024 * 1024,
	"max_entries": 197,
}


def limits_for_schema(schema: int) -> dict[str, int]:
	"""Admission limits of a supported schema (a copy); raises KeyError for any other."""
	return dict({SCHEMA_VERSION: _LIMITS_V2, SCHEMA_VERSION_LAYOUT: _LIMITS_V3}[schema])


# Package inspection runs before the manifest is read, so it applies the largest schema.
ZIP_ENVELOPE: dict[str, int] = limits_for_schema(SCHEMA_VERSION_LAYOUT)

# Schema 2 aliases kept for older call sites.
SCATTER_MAX_INSTANCES = _LIMITS_V2["max_scatter_instances"]
MANIFEST_MAX_BYTES = _LIMITS_V2["max_manifest_bytes"]
OBJECTS_MAX_BYTES = _LIMITS_V2["max_objects_bytes"]
SCATTER_MAX_BYTES = _LIMITS_V2["max_scatter_bytes"]
PATHS_MAX_BYTES = _LIMITS_V2["max_paths_bytes"]
MAX_OBJECTS = _LIMITS_V2["max_objects"]
QUAT_TOLERANCE = 1e-6
GROUNDING_TOLERANCE_M = 1e-3

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
HEX16_RE = re.compile(r"^[0-9a-fA-F]{16}$")

AUTHORED_MAGIC = b"WPOC-AUTHORED-V2\n"
AUTHORED_MAGIC_V3 = b"WPOC-AUTHORED-V3\n"
CATALOG_MAGIC = b"WPOC-CATALOG-V1\n"


def terrain_block(layout: Layout = LEGACY_LAYOUT) -> dict[str, Any]:
	"""Manifest terrain block with the default rules; schema 3 adds terrain.layout."""
	block = dict(TERRAIN_BLOCK)
	block["region_locations"] = [list(loc) for loc in layout_regions(*layout)]
	if layout != LEGACY_LAYOUT:
		block["layout"] = layout_to_manifest(layout)
	return block


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


def payload_paths(layout: Layout = LEGACY_LAYOUT) -> list[str]:
	"""Payload paths of a layout (3 + 3 per region), sorted byte-wise (ASCII str sort is byte-wise)."""
	locs = layout_regions(*layout)
	return sorted(["objects.json", PATHS_PATH, SCATTER_PATH] + [height_path(l) for l in locs]
		+ [control_path(l) for l in locs] + [color_path(l) for l in locs])


def generation_files(layout: Layout = LEGACY_LAYOUT) -> set[str]:
	return set(payload_paths(layout)) | {"manifest.json"}


PAYLOAD_PATHS: list[str] = payload_paths()  # legacy layout
GENERATION_FILES: set[str] = generation_files()
