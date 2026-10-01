#!/usr/bin/env python3
"""Deterministic bundled fixtures (spec §3.2): app/fixtures/{flat,gentle_hills,stress_100}.

Heights are computed in float64 at world (x, z) = (g * 0.5) and packed as float32. The committed
bytes are the reference; --check regenerates into a temp dir and byte-compares.

Usage: python3 scripts/generate_fixtures.py [--check] [--out DIR]
"""
from __future__ import annotations

import argparse
import filecmp
import math
import struct
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixture_hills_content as hills  # noqa: E402
import worldpoc_format as wf  # noqa: E402

FIXTURES_DIR = wf.APP_DIR / "fixtures"
CREATED_WITH = {
	"godot": "4.7.2.stable.official.ed1daf0bf",
	"terrain3d": "1.0.2-stable@0077405b52e353c5e5dc3a094e7ede49833ba6fe",
	"world_painter": "fixture-generator-v1",
}
WORLD_IDS = {
	"flat": "0f1a7000-0000-4000-8000-000000000001",
	"gentle_hills": "0e111150-0000-4000-8000-000000000002",
	"stress_100": "57e55100-0000-4000-8000-000000000003",
}
STRESS_GRID = 10
STRESS_SPACING_M = 20.0
STRESS_ORIGIN_M = -90.0
# (cx, cz, amplitude m, sigma m)
BUMPS = [(-60.0, -50.0, 11.5, 28.0), (55.0, -40.0, 9.0, 22.0), (-45.0, 60.0, 8.0, 25.0),
	(40.0, 55.0, 7.0, 30.0), (0.0, 0.0, 3.0, 40.0), (85.0, -85.0, 8.0, 9.0), (-90.0, 10.0, -3.0, 18.0)]
LODGE_CENTER = (20.0, 20.0)
LODGE_INNER_M = 12.0
LODGE_OUTER_M = 20.0
FLAT_CHECK_RADIUS_M = 10.0


def smoothstep(e0: float, e1: float, v: float) -> float:
	t = min(max((v - e0) / (e1 - e0), 0.0), 1.0)
	return t * t * (3.0 - 2.0 * t)


def _bumps(x: float, z: float) -> float:
	return sum(a * math.exp(-((x - cx) ** 2 + (z - cz) ** 2) / (2.0 * s * s)) for cx, cz, a, s in BUMPS)


H_CENTER = _bumps(*LODGE_CENTER)  # pre-flatten height at the lodge centre


def hills_height(x: float, z: float) -> float:
	d = math.hypot(x - LODGE_CENTER[0], z - LODGE_CENTER[1])
	m = 1.0 - smoothstep(LODGE_INNER_M, LODGE_OUTER_M, d)
	h = _bumps(x, z) * (1.0 - m) + H_CENTER * m
	return min(max(h, wf.HEIGHT_MIN), wf.HEIGHT_MAX)


def flat_height(x: float, z: float) -> float:
	return 0.0


def region_height_bytes(loc: tuple[int, int], fn: Callable[[float, float], float]) -> bytes:
	n = wf.REGION_SAMPLES
	values = []
	for lz in range(n):
		z = (loc[1] * n + lz) * wf.SAMPLE_SPACING
		for lx in range(n):
			values.append(fn((loc[0] * n + lx) * wf.SAMPLE_SPACING, z))
	return struct.pack("<%df" % len(values), *values)


def stress_objects(heights: dict[tuple[int, int], bytes], catalog: dict[str, Any]) -> list[dict[str, Any]]:
	"""100 manual proxy objects on a 10x10 grid; y comes from the canonical float32 sampler."""
	regions = wf.load_region_arrays(heights)
	kinds = ["built.lodge.cabin_a"] + ["nature.rock.boulder_a"] * 4 + ["nature.tree.spruce_a"] * 5
	records = []
	for i in range(STRESS_GRID * STRESS_GRID):
		asset = catalog["assets"][kinds[i % 10]]
		x = STRESS_ORIGIN_M + STRESS_SPACING_M * (i % STRESS_GRID)
		z = STRESS_ORIGIN_M + STRESS_SPACING_M * (i // STRESS_GRID)
		if i % 10 == 0:
			scale = 1.0
		elif i % 10 < 5:
			scale = 0.5 + 0.25 * (i % 4)
		else:
			scale = 0.75 + 0.25 * (i % 3)
		half = math.radians((i * 37) % 360) / 2.0
		offset = 0.0
		y = wf.sample_height(regions, x, z) + offset
		records.append(wf.make_object_record("57e55100-0000-4000-8000-%012x" % (i + 1), asset["asset_id"],
			int(asset["version"]), [x, y, z], [0.0, math.sin(half), 0.0, math.cos(half)], scale,
			asset["default_grounding"], offset))
	return records


def build_doc(name: str, catalog: dict[str, Any]) -> dict[str, Any]:
	fn = flat_height if name == "flat" else hills_height
	control = struct.pack("<I", wf.DEFAULT_CONTROL) * wf.REGION_SAMPLE_COUNT
	color = wf.DEFAULT_COLOR * wf.REGION_SAMPLE_COUNT
	heights = {loc: region_height_bytes(loc, fn) for loc in wf.REGION_LOCATIONS}
	controls = {loc: control for loc in wf.REGION_LOCATIONS}
	colors = {loc: color for loc in wf.REGION_LOCATIONS}
	scatter: list[dict[str, Any]] = []
	paths: list[dict[str, Any]] = []
	if name == "gentle_hills":
		controls = hills.paint_dirt(controls)
		colors = hills.tint_autumn(colors)
		scatter = hills.scatter_instances(hills_height, catalog)
		paths = hills.path_records()
	return {
		"world_id": WORLD_IDS[name],
		"document_revision": 0,
		"created_with": CREATED_WITH,
		"catalog": {"id": catalog["id"], "version": catalog["version"], "sha256": catalog["sha256"]},
		"heights": heights,
		"controls": controls,
		"colors": colors,
		"rules": dict(wf.DEFAULT_RULES),
		"scatter": scatter,
		"paths": paths,
		"objects": stress_objects(heights, catalog) if name == "stress_100" else [],
	}


FLAT_LAYOUT_WORLD_ID = "0f1a7000-0000-4000-8000-0000000000f1"


def flat_layout_doc(layout: wf.Layout, catalog: dict[str, Any], world_id: str = FLAT_LAYOUT_WORLD_ID) -> dict[str, Any]:
	"""Document for a flat world (height 0, default control and tint, no content) on any layout.
	All regions share the same bytes objects, so a 64-region world costs three 256 KiB buffers."""
	height = struct.pack("<f", 0.0) * wf.REGION_SAMPLE_COUNT
	control = struct.pack("<I", wf.DEFAULT_CONTROL) * wf.REGION_SAMPLE_COUNT
	color = wf.DEFAULT_COLOR * wf.REGION_SAMPLE_COUNT
	locs = wf.layout_regions(*layout)
	return {
		"world_id": world_id,
		"document_revision": 0,
		"created_with": CREATED_WITH,
		"catalog": {"id": catalog["id"], "version": catalog["version"], "sha256": catalog["sha256"]},
		"layout": layout,
		"heights": {loc: height for loc in locs},
		"controls": {loc: control for loc in locs},
		"colors": {loc: color for loc in locs},
		"rules": dict(wf.DEFAULT_RULES),
		"scatter": [],
		"paths": [],
		"objects": [],
	}


def write_flat_world(out_dir: Path, layout: wf.Layout = wf.LEGACY_LAYOUT, world_id: str = FLAT_LAYOUT_WORLD_ID) -> dict[str, Any]:
	"""Writes a flat world for `layout` as a generation directory (tests only: a km1 world is 48 MiB
	of region files, so it is never committed). Returns the manifest."""
	out_dir.mkdir(parents=True, exist_ok=True)
	return wf.write_generation(out_dir, flat_layout_doc(layout, wf.load_trusted_catalog(), world_id))


def generate(out_dir: Path) -> dict[str, dict[str, Any]]:
	catalog = wf.load_trusted_catalog()
	manifests = {}
	for name in WORLD_IDS:
		gen_dir = out_dir / name
		gen_dir.mkdir(parents=True, exist_ok=True)
		manifests[name] = wf.write_generation(gen_dir, build_doc(name, catalog))
	return manifests


# --- Reported properties ---------------------------------------------------------------
def fixture_stats(gen_dir: Path) -> dict[str, Any]:
	gen, errors = wf.read_generation_dir(gen_dir)
	if gen is None:
		raise RuntimeError("; ".join(errors))
	regions = wf.load_region_arrays(gen.heights)

	def h(gx: int, gz: int) -> float:
		return wf.height_at_sample(regions, gx, gz)

	lo, hi = wf.GLOBAL_SAMPLE_MIN, wf.GLOBAL_SAMPLE_MAX
	all_h = [v for r in regions.values() for v in r]
	max_slope = 0.0
	for gz in range(lo + 1, hi):
		for gx in range(lo + 1, hi):
			dx = (h(gx + 1, gz) - h(gx - 1, gz)) / (2.0 * wf.SAMPLE_SPACING)
			dz = (h(gx, gz + 1) - h(gx, gz - 1)) / (2.0 * wf.SAMPLE_SPACING)
			max_slope = max(max_slope, math.hypot(dx, dz))
	flat = []
	for gz in range(lo, hi + 1):
		for gx in range(lo, hi + 1):
			if math.hypot(gx * 0.5 - LODGE_CENTER[0], gz * 0.5 - LODGE_CENTER[1]) <= FLAT_CHECK_RADIUS_M:
				flat.append(h(gx, gz))
	mean = sum(flat) / len(flat)
	return {
		"max_height_m": max(all_h),
		"min_height_m": min(all_h),
		"max_slope_deg": math.degrees(math.atan(max_slope)),
		"flat_area_samples": len(flat),
		"flat_area_stddev_m": math.sqrt(sum((v - mean) ** 2 for v in flat) / len(flat)),
		"flat_area_height_m": mean,
		"seam_ranges_m": seam_ranges(h),
	}


def seam_ranges(h: Callable[[int, int], float]) -> dict[str, float]:
	"""Height range along both sides of the x=0 and z=0 seams, split per quadrant half."""
	out = {}
	for label, gs in (("neg", range(-256, 0)), ("pos", range(0, 256))):
		for side, gx in (("x=-0.5", -1), ("x=0", 0)):
			col = [h(gx, g) for g in gs]
			out["%s z_%s" % (side, label)] = max(col) - min(col)
		for side, gz in (("z=-0.5", -1), ("z=0", 0)):
			row = [h(g, gz) for g in gs]
			out["%s x_%s" % (side, label)] = max(row) - min(row)
	return out


def check(out: Path | None = None) -> list[str]:
	"""Regenerates to a temp dir and byte-compares with committed fixtures. Returns mismatches."""
	committed = out or FIXTURES_DIR
	mismatches: list[str] = []
	with tempfile.TemporaryDirectory(prefix="fixtures_check_") as tmp:
		generate(Path(tmp))
		for name in WORLD_IDS:
			for rel in sorted(wf.GENERATION_FILES):
				a, b = Path(tmp) / name / rel, committed / name / rel
				if not b.is_file() or not filecmp.cmp(a, b, shallow=False):
					mismatches.append("%s/%s" % (name, rel))
	return mismatches


def main(argv: list[str] | None = None) -> int:
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("--check", action="store_true", help="byte-compare regenerated fixtures with committed ones")
	p.add_argument("--out", type=Path, default=None, help="output directory (default app/fixtures)")
	p.add_argument("--stats", action="store_true", help="print terrain statistics after generating")
	a = p.parse_args(argv)
	if a.check:
		bad = check(a.out)
		if bad:
			print("fixtures --check FAILED: %d file(s) differ: %s" % (len(bad), ", ".join(bad)))
			return 1
		print("fixtures --check OK (%d fixtures byte-identical)" % len(WORLD_IDS))
		return 0
	out = a.out or FIXTURES_DIR
	for name, m in generate(out).items():
		print("%s: authored_content_hash %s" % (name, m["authored_content_hash"]))
	if a.stats:
		for name in WORLD_IDS:
			print(name, fixture_stats(out / name))
	return 0


if __name__ == "__main__":
	sys.exit(main())
