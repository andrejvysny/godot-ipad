"""Canonical surface sampling shared by fixture tools and grounding reports."""
from __future__ import annotations

from array import array
import math
import struct
import sys

from worldpoc_constants import (
	SAMPLE_SPACING,
	REGION_SAMPLES,
	LEGACY_LAYOUT,
	Layout,
	layout_extent,
	layout_sample_range,
)

# --- Terrain sampling (WorldDocument.sample_height) ------------------------------------
def load_region_arrays(heights: dict[tuple[int, int], bytes]) -> dict[tuple[int, int], array]:
	out: dict[tuple[int, int], array] = {}
	for loc, data in heights.items():
		a = array("f")
		a.frombytes(data)
		if sys.byteorder != "little":
			a.byteswap()
		out[loc] = a
	return out


def height_at_sample(regions: dict[tuple[int, int], array], gx: int, gz: int) -> float:
	r = regions.get((gx >> 8, gz >> 8))
	if r is None:
		return math.nan
	return r[(gz & 255) * REGION_SAMPLES + (gx & 255)]


def sample_height(regions: dict[tuple[int, int], array], x: float, z: float,
		controls: dict[tuple[int, int], bytes] | None = None, layout: Layout = LEGACY_LAYOUT) -> float:
	"""Bilinear, identical to WorldDocument.sample_height; NaN outside the layout's extent
	(legacy: [-128, 127.5])."""
	x_min, x_max, z_min, z_max = layout_extent(layout)
	if not (x_min <= x <= x_max and z_min <= z <= z_max):
		return math.nan
	fx = x / SAMPLE_SPACING
	fz = z / SAMPLE_SPACING
	gx = math.floor(fx)
	gz = math.floor(fz)
	tx = fx - gx
	tz = fz - gz
	if controls is not None:
		control = controls.get((gx >> 8, gz >> 8))
		index = ((gz & 255) * REGION_SAMPLES + (gx & 255)) * 4
		if control is None or struct.unpack_from("<I", control, index)[0] & 4:
			return math.nan
	h00 = height_at_sample(regions, gx, gz)
	if tx == 0.0 and tz == 0.0:
		return h00
	(_, gx_max), (_, gz_max) = layout_sample_range(layout)
	gx1 = min(gx + 1, gx_max)
	gz1 = min(gz + 1, gz_max)
	h10 = height_at_sample(regions, gx1, gz)
	h01 = height_at_sample(regions, gx, gz1)
	h11 = height_at_sample(regions, gx1, gz1)
	a = h00 + tx * (h10 - h00)
	b = h01 + tx * (h11 - h01)
	return a + tz * (b - a)
