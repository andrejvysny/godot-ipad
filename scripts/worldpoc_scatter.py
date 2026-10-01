"""scatter.bin and paths.bin parsers/writers (docs/world-format.md §5, §6), Python stdlib only.

Parsers are strict and return (value, error): the first structural problem stops the parse.
Instances and paths are plain dicts holding the exact float32 values widened to float64, so a
parse followed by a write reproduces the input bytes.
"""
from __future__ import annotations

import math
import struct
from typing import Any

from worldpoc_constants import (
	WORLD_MIN,
	WORLD_MAX_SAMPLE,
	UUID_RE,
	SCATTER_MAGIC,
	PATHS_MAGIC,
	SCATTER_VERSION,
	PATHS_VERSION,
	SCATTER_INSTANCE_BYTES,
	SCATTER_MAX_INSTANCES,
	SCATTER_FLAG_TILT,
	YAW_MAX,
	PATHS_MAX_COUNT,
	PATH_MIN_POINTS,
	PATH_MAX_POINTS,
	PATH_WIDTH_MIN,
	PATH_WIDTH_MAX,
)
from worldpoc_values import show


class _Reader:
	"""Bounds-checked little-endian reader; raises ValueError (caught by the parsers)."""

	def __init__(self, data: bytes) -> None:
		self.data = data
		self.pos = 0

	def take(self, n: int) -> bytes:
		if n < 0 or self.pos + n > len(self.data):
			raise ValueError("truncated data at byte %d (need %d more)" % (self.pos, n))
		out = self.data[self.pos:self.pos + n]
		self.pos += n
		return out

	def u32(self) -> int:
		return struct.unpack("<I", self.take(4))[0]

	def f32(self) -> float:
		return struct.unpack("<f", self.take(4))[0]

	def str_(self) -> str:
		raw = self.take(self.u32())
		try:
			return raw.decode("utf-8")
		except UnicodeDecodeError as e:
			raise ValueError("string is not valid UTF-8") from e

	def remaining(self) -> int:
		return len(self.data) - self.pos


def _header(r: _Reader, magic: bytes, version: int, name: str) -> None:
	if r.take(4) != magic:
		raise ValueError("%s has a bad magic (expected %r)" % (name, magic))
	v = r.u32()
	if v != version:
		raise ValueError("%s version %d is not supported (expected %d)" % (name, v, version))


def _in_extent(v: float) -> bool:
	return WORLD_MIN <= v <= WORLD_MAX_SAMPLE


def _pack_str(s: str) -> bytes:
	b = s.encode("utf-8")
	return struct.pack("<I", len(b)) + b


# --- scatter.bin (§5) ------------------------------------------------------------------
def parse_scatter(data: bytes) -> tuple[dict[str, Any] | None, str]:
	"""Returns ({"assets": [(asset_id, version)], "instances": [instance dict]}, "")."""
	try:
		return _parse_scatter(data), ""
	except ValueError as e:
		return None, "scatter.bin: %s" % e


def _parse_scatter(data: bytes) -> dict[str, Any]:
	r = _Reader(data)
	_header(r, SCATTER_MAGIC, SCATTER_VERSION, "scatter.bin")
	asset_count = r.u32()
	assets: list[tuple[str, int]] = []
	prev = b""
	for i in range(asset_count):
		asset_id = r.str_()
		key = asset_id.encode("utf-8")
		if asset_id == "":
			raise ValueError("asset table entry %d has an empty asset_id" % i)
		if i > 0 and key == prev:
			raise ValueError("duplicate asset_id %s in the asset table" % show(asset_id))
		if key < prev:
			raise ValueError("asset table is not sorted by asset_id (%s)" % show(asset_id))
		prev = key
		assets.append((asset_id, r.u32()))
	count = r.u32()
	if count > SCATTER_MAX_INSTANCES:
		raise ValueError("%d instances exceed the limit of %d" % (count, SCATTER_MAX_INSTANCES))
	if r.remaining() < count * SCATTER_INSTANCE_BYTES:
		raise ValueError("truncated data: %d instances need %d bytes, %d remain"
			% (count, count * SCATTER_INSTANCE_BYTES, r.remaining()))
	if r.remaining() > count * SCATTER_INSTANCE_BYTES:
		raise ValueError("%d trailing bytes after the last instance" % (r.remaining() - count * SCATTER_INSTANCE_BYTES))
	instances: list[dict[str, Any]] = []
	used = [False] * asset_count
	for i in range(count):
		index, flags, x, z, yaw, scale = struct.unpack("<HHffff", r.take(SCATTER_INSTANCE_BYTES))
		tag = "instance %d" % i
		if index >= asset_count:
			raise ValueError("%s asset_index %d is out of range (asset_count %d)" % (tag, index, asset_count))
		if flags & ~SCATTER_FLAG_TILT:
			raise ValueError("%s has unknown flag bits 0x%04x" % (tag, flags))
		if not all(math.isfinite(v) for v in (x, z, yaw, scale)):
			raise ValueError("%s has a non-finite value" % tag)
		if not (_in_extent(x) and _in_extent(z)):
			raise ValueError("%s position (%r, %r) is outside the world extent" % (tag, x, z))
		if abs(yaw) > YAW_MAX:
			raise ValueError("%s yaw %r is outside +-%r" % (tag, yaw, YAW_MAX))
		used[index] = True
		instances.append({"asset_id": assets[index][0], "asset_version": assets[index][1], "flags": flags,
			"x": x, "z": z, "yaw_rad": yaw, "scale": scale})
	for i, u in enumerate(used):
		if not u:
			raise ValueError("asset table entry %s is not referenced by any instance" % show(assets[i][0]))
	return {"assets": assets, "instances": instances}


def check_scatter_catalog(scatter: dict[str, Any], assets: dict[str, Any]) -> list[str]:
	"""Catalog rules of §5: asset exists with that version, scatter_allowed, scatter_mesh, scale range."""
	errors: list[str] = []
	for asset_id, version in scatter["assets"]:
		asset = assets.get(asset_id)
		if asset is None:
			errors.append("scatter asset %s is not in the trusted catalog" % show(asset_id))
		elif int(asset["version"]) != version:
			errors.append("scatter asset %s version %d does not match catalog version %d"
				% (show(asset_id), version, int(asset["version"])))
		elif not asset.get("scatter_allowed") or asset.get("scatter_mesh") is None:
			errors.append("scatter asset %s is not scatter-allowed (scatter_allowed and scatter_mesh required)"
				% show(asset_id))
	if errors:
		return errors
	for i, inst in enumerate(scatter["instances"]):
		asset = assets[inst["asset_id"]]
		if not (0.0 < inst["scale"] and asset["scale_min"] <= inst["scale"] <= asset["scale_max"]):
			errors.append("scatter instance %d scale %r outside [%r, %r] of asset %s"
				% (i, inst["scale"], asset["scale_min"], asset["scale_max"], show(inst["asset_id"])))
			break
	return errors


def write_scatter(instances: list[dict[str, Any]]) -> bytes:
	"""Canonical scatter.bin: minimal asset table sorted byte-wise; instance order preserved.
	Instances need asset_id, asset_version, x, z, yaw_rad, scale and optionally flags."""
	versions: dict[str, int] = {}
	for inst in instances:
		if versions.setdefault(inst["asset_id"], inst["asset_version"]) != inst["asset_version"]:
			raise ValueError("asset %s used with two versions" % show(inst["asset_id"]))
	table = sorted(versions, key=lambda a: a.encode("utf-8"))
	index = {a: i for i, a in enumerate(table)}
	out = [SCATTER_MAGIC, struct.pack("<II", SCATTER_VERSION, len(table))]
	for a in table:
		out += [_pack_str(a), struct.pack("<I", versions[a])]
	out.append(struct.pack("<I", len(instances)))
	for inst in instances:
		out.append(struct.pack("<HHffff", index[inst["asset_id"]], inst.get("flags", 0), inst["x"], inst["z"],
			inst["yaw_rad"], inst["scale"]))
	return b"".join(out)


# --- paths.bin (§6) --------------------------------------------------------------------
def parse_paths(data: bytes) -> tuple[list[dict[str, Any]] | None, str]:
	"""Returns ([{"path_id", "width_m", "points": [(x, z)]}], "")."""
	try:
		return _parse_paths(data), ""
	except ValueError as e:
		return None, "paths.bin: %s" % e


def _parse_paths(data: bytes) -> list[dict[str, Any]]:
	r = _Reader(data)
	_header(r, PATHS_MAGIC, PATHS_VERSION, "paths.bin")
	count = r.u32()
	if count > PATHS_MAX_COUNT:
		raise ValueError("%d paths exceed the limit of %d" % (count, PATHS_MAX_COUNT))
	paths: list[dict[str, Any]] = []
	prev = b""
	for i in range(count):
		path_id = r.str_()
		if not UUID_RE.match(path_id):
			raise ValueError("path %d id %s is not a lowercase UUID" % (i, show(path_id)))
		key = path_id.encode("utf-8")
		if i > 0 and key == prev:
			raise ValueError("duplicate path_id %s" % path_id)
		if key < prev:
			raise ValueError("paths are not sorted by path_id (%s)" % path_id)
		prev = key
		width = r.f32()
		if not (math.isfinite(width) and PATH_WIDTH_MIN <= width <= PATH_WIDTH_MAX):
			raise ValueError("path %s width %r is outside [%g, %g]" % (path_id, width, PATH_WIDTH_MIN, PATH_WIDTH_MAX))
		n = r.u32()
		if not (PATH_MIN_POINTS <= n <= PATH_MAX_POINTS):
			raise ValueError("path %s has %d points (allowed %d..%d)" % (path_id, n, PATH_MIN_POINTS, PATH_MAX_POINTS))
		points: list[tuple[float, float]] = []
		for j in range(n):
			x, z = struct.unpack("<ff", r.take(8))
			if not (math.isfinite(x) and math.isfinite(z)):
				raise ValueError("path %s point %d is not finite" % (path_id, j))
			if not (_in_extent(x) and _in_extent(z)):
				raise ValueError("path %s point %d (%r, %r) is outside the world extent" % (path_id, j, x, z))
			points.append((x, z))
		paths.append({"path_id": path_id, "width_m": width, "points": points})
	if r.remaining():
		raise ValueError("%d trailing bytes after the last path" % r.remaining())
	return paths


def write_paths(paths: list[dict[str, Any]]) -> bytes:
	"""Canonical paths.bin: paths sorted by path_id byte-wise."""
	ordered = sorted(paths, key=lambda p: p["path_id"].encode("utf-8"))
	out = [PATHS_MAGIC, struct.pack("<II", PATHS_VERSION, len(ordered))]
	for p in ordered:
		out += [_pack_str(p["path_id"]), struct.pack("<fI", p["width_m"], len(p["points"]))]
		for x, z in p["points"]:
			out.append(struct.pack("<ff", x, z))
	return b"".join(out)
