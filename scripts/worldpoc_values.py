#!/usr/bin/env python3
"""Shared World Painter PoC format library (docs/world-format.md), Python stdlib only.

Mirrors WorldConstants, ControlCodec, ObjectRecord, WorldDocument.sample_height and
CanonicalEncoder from app/addons/world_painter/core/document. Validators return lists of error strings; they never
raise for invalid content.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import shutil
import struct
import sys
import tempfile
import zipfile
import zlib
from array import array
from pathlib import Path
from typing import Any

from worldpoc_constants import (
	APP_DIR,
	SAMPLE_SPACING,
	REGION_SAMPLES,
	LEGACY_LAYOUT,
	Layout,
	layout_extent,
	layout_schema,
	MATERIAL_GRASS,
	MATERIAL_DIRT,
	MATERIAL_SLOTS,
	DEFAULT_CONTROL,
	GROUNDINGS,
	ORIGINS,
	QUAT_TOLERANCE,
	UUID_RE,
	HEX16_RE,
	BINDING_ID_RE,
	AUTHORED_MAGIC,
	AUTHORED_MAGIC_V3,
	CATALOG_MAGIC,
)

# --- f64le exact floats (ADR 0003) -----------------------------------------------------
def f64_hex(v: float) -> str:
	return struct.pack("<d", v).hex()


def f64_from_hex(h: Any) -> float:
	"""NaN for malformed input; callers reject non-finite values anyway."""
	if not isinstance(h, str) or not HEX16_RE.match(h):
		return math.nan
	return struct.unpack("<d", bytes.fromhex(h))[0]


# --- ControlCodec ----------------------------------------------------------------------
BASE_SHIFT = 27
OVERLAY_SHIFT = 22
BLEND_SHIFT = 14
ID_MASK = 0x1F
BLEND_MASK = 0xFF
AUTO_BIT = 0x1
NAV_BIT = 0x2
HOLE_BIT = 0x4
U32 = 0xFFFFFFFF
PAINT_OWNED_MASK = (ID_MASK << BASE_SHIFT) | (ID_MASK << OVERLAY_SHIFT) | (BLEND_MASK << BLEND_SHIFT) | AUTO_BIT


def control_decode(value: int) -> dict[str, Any]:
	v = value & U32
	return {
		"base_id": (v >> BASE_SHIFT) & ID_MASK,
		"overlay_id": (v >> OVERLAY_SHIFT) & ID_MASK,
		"blend": (v >> BLEND_SHIFT) & BLEND_MASK,
		"auto": (v & AUTO_BIT) != 0,
		"hole": (v & HOLE_BIT) != 0,
		"other_bits": v & ~PAINT_OWNED_MASK & U32,
	}


def control_encode_paint(existing: int, dirt_blend_u8: int) -> int:
	v = (existing & U32) & ~PAINT_OWNED_MASK
	v |= MATERIAL_GRASS << BASE_SHIFT
	v |= MATERIAL_DIRT << OVERLAY_SHIFT
	v |= (max(0, min(255, dirt_blend_u8)) & BLEND_MASK) << BLEND_SHIFT
	return v & U32


def control_is_supported(value: int) -> bool:
	v = value & U32
	return ((v >> BASE_SHIFT) & ID_MASK) < len(MATERIAL_SLOTS) and ((v >> OVERLAY_SHIFT) & ID_MASK) < len(MATERIAL_SLOTS)


# New worlds and fixtures: rule layer only (auto bit set, base 0, overlay 0, blend 0).
GRASS_VALUE = DEFAULT_CONTROL


# --- Hash helpers ----------------------------------------------------------------------
def sha256_hex(data: bytes) -> str:
	return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
	h = hashlib.sha256()
	with open(path, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


class _Stream:
	def __init__(self) -> None:
		self.parts: list[bytes] = []

	def u8(self, v: int) -> None:
		self.parts.append(struct.pack("<B", v))

	def u32(self, v: int) -> None:
		self.parts.append(struct.pack("<I", v))

	def i32(self, v: int) -> None:
		self.parts.append(struct.pack("<i", v))

	def f64(self, v: float) -> None:
		self.parts.append(struct.pack("<d", 0.0 if v == 0.0 else v))

	def str_(self, s: str) -> None:
		b = s.encode("utf-8")
		self.u32(len(b))
		self.parts.append(b)

	def raw(self, b: bytes) -> None:
		self.parts.append(b)

	def digest_hex(self) -> str:
		return hashlib.sha256(b"".join(self.parts)).hexdigest()


def authored_hash(catalog: dict[str, Any], rules: dict[str, Any],
		region_digests: dict[tuple[int, int], tuple[bytes, bytes, bytes]], scatter_bytes: bytes,
		paths_bytes: bytes, records: list[dict[str, Any]], layout: Layout = LEGACY_LAYOUT) -> str:
	"""world-format §7 (legacy layout, V2 stream) and §11.4 (any other layout, V3 stream).
	`region_digests[loc] = (sha256(height), sha256(control), sha256(color))` as raw 32-byte digests;
	`rules` holds the four manifest rule values; `records` hold exact float64 values (from f64le bits)."""
	s = _Stream()
	legacy = layout == LEGACY_LAYOUT
	s.raw(AUTHORED_MAGIC if legacy else AUTHORED_MAGIC_V3)
	s.u32(layout_schema(layout))
	s.str_(catalog["id"])
	s.u32(catalog["version"])
	s.str_(catalog["sha256"])
	s.f64(SAMPLE_SPACING)
	s.u32(REGION_SAMPLES)
	if not legacy:
		s.i32(layout[0][0])
		s.i32(layout[0][1])
		s.u32(layout[1][0])
		s.u32(layout[1][1])
	s.u8(1 if rules["rock_enabled"] else 0)
	s.i32(int(rules["rock_slope_deg"]))
	s.u8(1 if rules["sand_enabled"] else 0)
	s.i32(int(rules["sand_height_dm"]))
	locs = sorted(region_digests, key=lambda l: (l[1], l[0]))
	s.u32(len(locs))
	for loc in locs:
		s.i32(loc[0])
		s.i32(loc[1])
		for digest in region_digests[loc]:
			s.raw(digest)
	s.raw(hashlib.sha256(scatter_bytes).digest())
	s.raw(hashlib.sha256(paths_bytes).digest())
	ordered = sorted(records, key=lambda r: r["object_id"].encode("utf-8"))
	s.u32(len(ordered))
	for r in ordered:
		s.str_(r["object_id"])
		s.str_(r["asset_id"])
		s.u32(r["asset_version"])
		for v in r["position"]:
			s.f64(v)
		for v in r["rotation_xyzw"]:
			s.f64(v)
		s.f64(r["uniform_scale"])
		s.str_(r["grounding"])
		s.f64(r["height_offset_m"])
		s.str_(r["origin"])
		s.str_(r["scatter_operation_id"] or "")
	return s.digest_hex()


# --- JSON ------------------------------------------------------------------------------
class FormatError(ValueError):
	pass


def show(v: Any, limit: int = 80) -> str:
	"""ASCII-only, bounded rendering of an untrusted value for diagnostics (lone surrogates and
	control characters are escaped, so reports can always be printed)."""
	try:
		s = ascii(v)
	except (ValueError, RecursionError):
		s = "<%s>" % type(v).__name__
	return s if len(s) <= limit else s[:limit - 3] + "..."


def _reject_constant(name: str) -> Any:
	raise FormatError("non-standard JSON constant %s" % name)


def _no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
	out: dict[str, Any] = {}
	for k, v in pairs:
		if k in out:
			raise FormatError("duplicate JSON key %s" % show(k))
		out[k] = v
	return out


def parse_json_bytes(data: bytes) -> Any:
	"""Strict parse: UTF-8, no NaN/Infinity literals, no duplicate keys."""
	try:
		return json.loads(data.decode("utf-8"), parse_constant=_reject_constant, object_pairs_hook=_no_duplicates)
	except (ValueError, RecursionError) as e:  # incl. JSONDecodeError and Python's int-digit limit
		raise FormatError(str(e)[:200].encode("ascii", "backslashreplace").decode("ascii")) from e


def dump_json(obj: Any) -> bytes:
	return (json.dumps(obj, indent="\t", sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n").encode("utf-8")


def is_number(v: Any) -> bool:
	return isinstance(v, (int, float)) and not isinstance(v, bool)


def _as_float(v: int | float) -> float:
	"""Godot reads every JSON number as a double; an int too large for one becomes inf."""
	try:
		return float(v)
	except OverflowError:
		return math.inf


def is_finite_number(v: Any) -> bool:
	return is_number(v) and math.isfinite(_as_float(v))


def is_json_int(v: Any) -> bool:
	"""Godot parses every JSON number as float, so an integral float is an int."""
	if not is_finite_number(v):
		return False
	f = _as_float(v)
	return f == math.floor(f)


# --- Catalog (world-format §8) ---------------------------------------------------------
def _res_to_path(app_dir: Path, res: str) -> Path:
	if not res.startswith("res://"):
		raise FormatError("catalog path '%s' is not a res:// path" % res)
	rel = res[len("res://"):]
	if rel.startswith("/") or ".." in rel.split("/") or "\\" in rel:
		raise FormatError("catalog path '%s' escapes the project" % res)
	return app_dir / rel


def catalog_geometry_paths(catalog: dict[str, Any]) -> list[str]:
	paths: set[str] = set()
	for asset in catalog.get("assets", []):
		for key in ("preview_scene", "scatter_mesh"):
			if asset.get(key) is not None:
				paths.add(asset[key])
	return sorted(paths)


def catalog_sha256(app_dir: Path = APP_DIR) -> str:
	raw = (app_dir / "assets" / "catalog.json").read_bytes()
	catalog = parse_json_bytes(raw)
	s = _Stream()
	s.raw(CATALOG_MAGIC)
	s.str_("catalog.json")
	s.raw(hashlib.sha256(raw).digest())
	paths = catalog_geometry_paths(catalog)
	s.u32(len(paths))
	for res in paths:
		s.str_(res)
		s.raw(hashlib.sha256(_res_to_path(app_dir, res).read_bytes()).digest())
	return s.digest_hex()


def load_trusted_catalog(app_dir: Path = APP_DIR) -> dict[str, Any]:
	raw = (app_dir / "assets" / "catalog.json").read_bytes()
	catalog = parse_json_bytes(raw)
	return {
		"id": catalog["catalog_id"],
		"version": int(catalog["catalog_version"]),
		"sha256": catalog_sha256(app_dir),
		"assets": {a["asset_id"]: a for a in catalog["assets"]},
	}


# --- Object records (world-format §4) --------------------------------------------------
def make_object_record(object_id: str, asset_id: str, asset_version: int, position: list[float],
		rotation_xyzw: list[float], uniform_scale: float, grounding: str, height_offset_m: float,
		origin: str = "MANUAL", scatter_operation_id: str | None = None) -> dict[str, Any]:
	return {
		"object_id": object_id,
		"asset_id": asset_id,
		"asset_version": asset_version,
		"position": list(position),
		"rotation_xyzw": list(rotation_xyzw),
		"uniform_scale": uniform_scale,
		"grounding": grounding,
		"height_offset_m": height_offset_m,
		"origin": origin,
		"scatter_operation_id": scatter_operation_id,
		"f64le": {
			"position": [f64_hex(v) for v in position],
			"rotation_xyzw": [f64_hex(v) for v in rotation_xyzw],
			"uniform_scale": f64_hex(uniform_scale),
			"height_offset_m": f64_hex(height_offset_m),
		},
	}


def _exact(decimal: float, bits: Any) -> float:
	v = f64_from_hex(bits)
	if not math.isfinite(v) or abs(v - decimal) > 1e-9 * max(1.0, abs(decimal)):
		return math.nan
	return v


def _finite_list(v: Any, n: int) -> list[float] | None:
	if not isinstance(v, list) or len(v) != n or not all(is_finite_number(x) for x in v):
		return None
	return [float(x) for x in v]


_RECORD_FIELDS = ("object_id", "asset_id", "asset_version", "position", "rotation_xyzw",
	"uniform_scale", "grounding", "height_offset_m", "origin", "scatter_operation_id")


_RECORD_FIELDS_V4 = ("binding_id",) + tuple(k for k in _RECORD_FIELDS if k not in ("asset_id", "asset_version"))


def parse_object_record(d: Any, binding: bool = False) -> tuple[dict[str, Any] | None, str]:
	"""Structural parse mirroring ObjectRecord.from_dict; returns exact float64 values. `binding` selects
	the schema 4 record (binding_id instead of asset_id/asset_version)."""
	if not isinstance(d, dict):
		return None, "object record is not an object"
	for key in (_RECORD_FIELDS_V4 if binding else _RECORD_FIELDS):
		if key not in d:
			return None, "object record missing field '%s'" % key
	oid = d["object_id"]
	if not isinstance(oid, str) or not UUID_RE.match(oid):
		return None, "object_id is not a lowercase UUID"
	tag = " (object %s)" % oid
	if binding:
		if not isinstance(d["binding_id"], str) or not BINDING_ID_RE.match(d["binding_id"]):
			return None, "binding_id must match ^b[0-9a-f]{32}$" + tag
	elif not isinstance(d["asset_id"], str) or d["asset_id"] == "":
		return None, "asset_id must be a non-empty string" + tag
	elif not is_json_int(d["asset_version"]) or d["asset_version"] < 1:
		return None, "asset_version must be a positive integer" + tag
	pos = _finite_list(d["position"], 3)
	if pos is None:
		return None, "position must be 3 finite numbers" + tag
	rot = _finite_list(d["rotation_xyzw"], 4)
	if rot is None:
		return None, "rotation_xyzw must be 4 finite numbers" + tag
	if abs(math.sqrt(sum(c * c for c in rot)) - 1.0) > QUAT_TOLERANCE:
		return None, "rotation_xyzw is not a unit quaternion" + tag
	if not is_finite_number(d["uniform_scale"]) or d["uniform_scale"] <= 0.0:
		return None, "uniform_scale must be a positive finite number" + tag
	if d["grounding"] not in GROUNDINGS:
		return None, "grounding %s is not allowed%s" % (show(d["grounding"]), tag)
	if not is_finite_number(d["height_offset_m"]):
		return None, "height_offset_m must be finite" + tag
	if d["origin"] not in ORIGINS:
		return None, "origin %s is not allowed%s" % (show(d["origin"]), tag)
	sop = d["scatter_operation_id"]
	if sop is not None and not (isinstance(sop, str) and UUID_RE.match(sop)):
		return None, "scatter_operation_id must be null or a UUID" + tag
	bits = d.get("f64le")
	if not isinstance(bits, dict):
		return None, "f64le exact-value block missing" + tag
	if not isinstance(bits.get("position"), list) or len(bits["position"]) != 3 \
			or not isinstance(bits.get("rotation_xyzw"), list) or len(bits["rotation_xyzw"]) != 4:
		return None, "f64le arrays malformed" + tag
	rec = {
		"object_id": oid,
		"position": [_exact(pos[i], bits["position"][i]) for i in range(3)],
		"rotation_xyzw": [_exact(rot[i], bits["rotation_xyzw"][i]) for i in range(4)],
		"uniform_scale": _exact(float(d["uniform_scale"]), bits.get("uniform_scale")),
		"grounding": d["grounding"],
		"height_offset_m": _exact(float(d["height_offset_m"]), bits.get("height_offset_m")),
		"origin": d["origin"], "scatter_operation_id": sop,
	}
	if binding:
		rec["binding_id"] = d["binding_id"]
	else:
		rec["asset_id"], rec["asset_version"] = d["asset_id"], int(d["asset_version"])
	values = rec["position"] + rec["rotation_xyzw"] + [rec["uniform_scale"], rec["height_offset_m"]]
	if not all(math.isfinite(v) for v in values):
		return None, "f64le exact bits missing or disagree with decimal fields" + tag
	return rec, ""


def check_record_against_catalog(rec: dict[str, Any], assets: dict[str, Any], layout: Layout = LEGACY_LAYOUT) -> list[str]:
	tag = " (object %s)" % rec["object_id"]
	asset = assets.get(rec["asset_id"])
	if asset is None:
		return ["asset %s is not in the trusted catalog%s" % (show(rec["asset_id"]), tag)]
	errors: list[str] = []
	if int(asset["version"]) != rec["asset_version"]:
		errors.append("asset %s version %s does not match catalog version %d%s"
			% (show(rec["asset_id"]), show(rec["asset_version"]), int(asset["version"]), tag))
	s = rec["uniform_scale"]
	if not (asset["scale_min"] <= s <= asset["scale_max"]):
		errors.append("uniform_scale %r outside [%r, %r]%s" % (s, asset["scale_min"], asset["scale_max"], tag))
	h = rec["height_offset_m"]
	if not (asset["height_offset_min_m"] <= h <= asset["height_offset_max_m"]):
		errors.append("height_offset_m %r outside [%r, %r]%s"
			% (h, asset["height_offset_min_m"], asset["height_offset_max_m"], tag))
	x, _, z = rec["position"]
	x_min, x_max, z_min, z_max = layout_extent(layout)
	if not (x_min <= x <= x_max and z_min <= z <= z_max):
		errors.append("position X/Z (%r, %r) outside the world extent%s" % (x, z, tag))
	return errors
