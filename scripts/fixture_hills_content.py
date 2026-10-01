"""Authored content of the gentle_hills fixture: scatter patches, one path, a dirt paint patch and a
tint patch. Deterministic (seeded random.Random, float64 maths); the committed bytes are the
reference. Used by generate_fixtures.py; see app/fixtures/README.md for the layout."""
from __future__ import annotations

import math
import random
import struct
from typing import Any, Callable

import worldpoc_format as wf

HeightFn = Callable[[float, float], float]

SEED = 20261001
MAX_SLOPE_DEG = 14.0
MIN_HEIGHT_M = 0.2  # keeps scatter out of the sand/hollow band
PATH_ID = "0e111150-0000-4000-8000-0000000000a1"
PATH_WIDTH_M = 2.4
PATH_POINTS = [(-120.0, -75.0), (-92.5, -48.0), (-64.0, -12.5), (-30.0, 6.0), (4.0, 22.5), (40.0, 30.0),
	(76.5, 52.0), (118.0, 74.0)]
# (centre x, centre z, radius m)
FOREST_PATCH = (-52.0, 28.0, 30.0)
MEADOW_PATCH = (58.0, 4.0, 30.0)
DIRT_PATCH = (30.0, 12.0, 7.0)
TINT_PATCH = (-44.0, 34.0, 18.0)
TINT_COLOR = (192, 110, 48)
TINT_MAX_ALPHA = 200
DIRT_OVERLAY_ID = 1
# (asset_id, count, scale lo, scale hi, tilt probability); scale ranges sit inside the catalog ranges.
FOREST_MIX = [("nature.tree.spruce_a", 90, 0.8, 1.7, 0.0), ("nature.cover.fern_a", 40, 0.8, 1.2, 0.2),
	("nature.rock.boulder_a", 20, 0.5, 1.5, 0.3)]
MEADOW_MIX = [("nature.cover.grass_tuft_a", 200, 0.8, 1.2, 0.2), ("nature.cover.wildflowers_a", 120, 0.8, 1.1, 0.1),
	("nature.rock.pebbles_a", 80, 0.7, 1.3, 0.3)]


def _smoothstep(e0: float, e1: float, v: float) -> float:
	t = min(max((v - e0) / (e1 - e0), 0.0), 1.0)
	return t * t * (3.0 - 2.0 * t)


def _slope_deg(fn: HeightFn, x: float, z: float) -> float:
	dx = (fn(x + 1.0, z) - fn(x - 1.0, z)) / 2.0
	dz = (fn(x, z + 1.0) - fn(x, z - 1.0)) / 2.0
	return math.degrees(math.atan(math.hypot(dx, dz)))


def _segment_distance(px: float, pz: float, a: tuple[float, float], b: tuple[float, float]) -> float:
	vx, vz = b[0] - a[0], b[1] - a[1]
	t = ((px - a[0]) * vx + (pz - a[1]) * vz) / (vx * vx + vz * vz)
	t = min(max(t, 0.0), 1.0)
	return math.hypot(px - (a[0] + t * vx), pz - (a[1] + t * vz))


def _blocked(x: float, z: float) -> bool:
	"""Keeps scatter off the path and the dirt patch."""
	if any(_segment_distance(x, z, a, b) < PATH_WIDTH_M / 2.0 + 1.0 for a, b in zip(PATH_POINTS, PATH_POINTS[1:])):
		return True
	return math.hypot(x - DIRT_PATCH[0], z - DIRT_PATCH[1]) < DIRT_PATCH[2] + 1.0


def _patch(rng: random.Random, fn: HeightFn, catalog: dict[str, Any], centre: tuple[float, float, float],
		mix: list[tuple[str, int, float, float, float]]) -> list[dict[str, Any]]:
	"""Rejection-sampled instances inside a disc: gentle slope, above the hollow, off the path, and
	separated by half the summed footprints. The mix is interleaved so rare assets spread over the patch."""
	cx, cz, radius = centre
	todo = [(a, lo, hi, tilt) for a, n, lo, hi, tilt in mix for _ in range(n)]
	rng.shuffle(todo)
	placed: list[dict[str, Any]] = []
	cells: dict[tuple[int, int], list[tuple[float, float, float]]] = {}
	for asset_id, lo, hi, tilt in todo:
		asset = catalog["assets"][asset_id]
		for _ in range(500):
			r = radius * math.sqrt(rng.random())
			a = rng.uniform(0.0, 2.0 * math.pi)
			x, z = cx + r * math.cos(a), cz + r * math.sin(a)
			if _blocked(x, z) or fn(x, z) < MIN_HEIGHT_M or _slope_deg(fn, x, z) > MAX_SLOPE_DEG:
				continue
			scale = rng.uniform(lo, hi)
			reach = asset["footprint_radius_m"] * scale
			key = (int(x // 4.0), int(z // 4.0))
			near = [c for dx in (-1, 0, 1) for dz in (-1, 0, 1) for c in cells.get((key[0] + dx, key[1] + dz), [])]
			if any(math.hypot(x - ox, z - oz) < 0.5 * (reach + orr) for ox, oz, orr in near):
				continue
			cells.setdefault(key, []).append((x, z, reach))
			placed.append({"asset_id": asset_id, "asset_version": int(asset["version"]), "x": x, "z": z,
				"yaw_rad": rng.uniform(-math.pi, math.pi), "scale": scale, "flags": 1 if rng.random() < tilt else 0})
			break
		else:
			raise RuntimeError("could not place %s in the patch" % asset_id)
	return placed


def scatter_instances(fn: HeightFn, catalog: dict[str, Any]) -> list[dict[str, Any]]:
	rng = random.Random(SEED)
	return _patch(rng, fn, catalog, FOREST_PATCH, FOREST_MIX) + _patch(rng, fn, catalog, MEADOW_PATCH, MEADOW_MIX)


def path_records() -> list[dict[str, Any]]:
	return [{"path_id": PATH_ID, "width_m": PATH_WIDTH_M, "points": list(PATH_POINTS)}]


def _paint_disc(maps: dict[tuple[int, int], bytearray], stride: int, patch: tuple[float, float, float],
		weight: Callable[[float], int], write: Callable[[bytearray, int, int], None]) -> None:
	"""Calls write(map, byte_offset, weight) for every sample with weight > 0 inside the disc."""
	cx, cz, radius = patch
	n = wf.REGION_SAMPLES
	for gz in range(math.floor((cz - radius) / wf.SAMPLE_SPACING), math.ceil((cz + radius) / wf.SAMPLE_SPACING) + 1):
		for gx in range(math.floor((cx - radius) / wf.SAMPLE_SPACING), math.ceil((cx + radius) / wf.SAMPLE_SPACING) + 1):
			d = math.hypot(gx * wf.SAMPLE_SPACING - cx, gz * wf.SAMPLE_SPACING - cz)
			w = weight(d / radius)
			if w > 0:
				write(maps[(gx >> 8, gz >> 8)], ((gz & 255) * n + (gx & 255)) * stride, w)


def paint_dirt(controls: dict[tuple[int, int], bytes]) -> dict[tuple[int, int], bytes]:
	"""Dirt overlay (id 1) with a blend ramp 255 -> 0 over the outer half; the auto bit stays set."""
	maps = {loc: bytearray(b) for loc, b in controls.items()}

	def write(m: bytearray, off: int, w: int) -> None:
		word = wf.DEFAULT_CONTROL | (DIRT_OVERLAY_ID << wf.OVERLAY_SHIFT) | (w << wf.BLEND_SHIFT)
		struct.pack_into("<I", m, off, word)

	_paint_disc(maps, 4, DIRT_PATCH, lambda t: round(255.0 * (1.0 - _smoothstep(0.45, 1.0, t))), write)
	return {loc: bytes(m) for loc, m in maps.items()}


def tint_autumn(colors: dict[tuple[int, int], bytes]) -> dict[tuple[int, int], bytes]:
	"""Autumn tint (RGB 192,110,48) with an alpha ramp TINT_MAX_ALPHA -> 0."""
	maps = {loc: bytearray(b) for loc, b in colors.items()}

	def write(m: bytearray, off: int, w: int) -> None:
		m[off:off + 4] = bytes(TINT_COLOR) + bytes([w])

	_paint_disc(maps, 4, TINT_PATCH, lambda t: round(TINT_MAX_ALPHA * (1.0 - _smoothstep(0.3, 1.0, t))), write)
	return {loc: bytes(m) for loc, m in maps.items()}
