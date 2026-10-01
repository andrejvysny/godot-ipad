#!/usr/bin/env python3
"""Render-asset descriptor format (docs/render-assets.md), Python stdlib only.

Mirrors app/src/rendering/render_asset_descriptor.gd and render_asset_json.gd: the same strict
schema, path rules and the §3 hashes. parse_descriptor never raises for invalid content; errors
are "<reason>: detail" strings with a stable snake_case reason.
"""
from __future__ import annotations

import hashlib
import math
import struct
from typing import Any

FORMAT = "world-painter-render-asset"
SCHEMA_VERSION = 1
SOURCE_MAGIC = b"WPRA-SOURCE-V1\n"
DERIVATIVE_MAGIC = b"WPRA-DERIVATIVE-V1\n"
ROLES = ("selected", "near", "mid", "far", "ghost")
CATEGORIES = ("tree", "shrub", "rock", "structure", "ground_cover", "prop")
REASONS = ("descriptor_invalid", "unsupported_version", "path_rejected")
TOP_KEYS = ("format", "schema_version", "asset_id", "asset_version", "source_content_hash", "derivative_hash",
	"category", "vegetation", "decorative", "anchor_local_m", "bounds_min_m", "bounds_max_m",
	"footprint_radius_m", "representations", "overview", "materials", "textures", "dependencies",
	"provenance", "license")
MESH_KEYS = ("mesh", "triangles", "surfaces", "aabb_min_m", "aabb_max_m")
OVERVIEW_KEYS = ("kind", "shape", "base_y_m", "height_m", "radius_m", "color")
DEP_KEYS = ("key", "type", "path", "bytes", "sha256", "gpu_bytes", "staging_bytes")
DEP_TYPES = ("mesh", "material", "texture")
TIER_KEYS = ("dependency", "width", "height", "mipmaps")
MAX_DEP_BYTES = 64 * 1024 * 1024
MAX_U32 = 4294967295
LOW_MAX_DIM = 512
PREVIEW_MAX_DIM = 2048
MAX_PATH_LENGTH = 256
HEX = frozenset("0123456789abcdef")


# --- strict field helpers --------------------------------------------------------------
def is_number(v: Any) -> bool:
	return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_int(v: Any) -> bool:
	return is_number(v) and abs(v) <= 9007199254740992 and float(v) == math.floor(v)


def is_int_in(v: Any, lo: int, hi: int) -> bool:
	return is_int(v) and lo <= v <= hi


def is_str(v: Any) -> bool:
	return isinstance(v, str) and v != ""


def is_hex64(v: Any) -> bool:
	return isinstance(v, str) and len(v) == 64 and all(c in HEX for c in v)


def vec3(v: Any) -> tuple[float, float, float] | None:
	if not isinstance(v, list) or len(v) != 3 or not all(is_number(x) for x in v):
		return None
	return (float(v[0]), float(v[1]), float(v[2]))


def check_keys(d: dict[str, Any], keys: tuple[str, ...], what: str) -> str:
	for k in keys:
		if k not in d:
			return "%s missing field '%s'" % (what, k)
	for k in d:
		if k not in keys:
			return "%s has unknown field '%s'" % (what, k)
	return ""


def path_error(rel: Any) -> str:
	"""docs/render-assets.md §4 path rules for a relative path; '' when acceptable."""
	if not isinstance(rel, str) or rel == "":
		return "path must be a non-empty string"
	if len(rel) > MAX_PATH_LENGTH:
		return "path is too long"
	if "\\" in rel or rel.startswith("/") or ":" in rel:
		return "path '%s' must be relative with '/' separators" % rel
	if any(ord(c) < 32 for c in rel):
		return "path contains control characters"
	if any(seg in ("", ".", "..") for seg in rel.split("/")):
		return "path '%s' has an empty or traversal segment" % rel
	return ""


def has_reason(err: str) -> bool:
	return any(err.startswith(r + ": ") for r in REASONS)


def error_reason(err: str) -> str:
	return err.split(": ", 1)[0] if has_reason(err) else "descriptor_invalid"


# --- hashes ----------------------------------------------------------------------------
class _Stream:
	def __init__(self) -> None:
		self.parts: list[bytes] = []

	def u8(self, v: int) -> None:
		self.parts.append(struct.pack("<B", v))

	def u32(self, v: int) -> None:
		self.parts.append(struct.pack("<I", v))

	def u64(self, v: int) -> None:
		self.parts.append(struct.pack("<Q", v))

	def str_(self, s: str) -> None:
		b = s.encode("utf-8")
		self.u32(len(b))
		self.parts.append(b)

	def raw(self, b: bytes) -> None:
		self.parts.append(b)

	def hex(self) -> str:
		return hashlib.sha256(b"".join(self.parts)).hexdigest()


def source_content_hash(asset_id: str, version: int, preview_scene_sha_raw: bytes, scatter_sha_raw: bytes = b"") -> str:
	"""§3.1; scatter_sha_raw is empty when the catalog asset has no scatter mesh."""
	s = _Stream()
	s.raw(SOURCE_MAGIC)
	s.str_(asset_id)
	s.u32(version)
	s.raw(preview_scene_sha_raw)
	s.u8(0 if not scatter_sha_raw else 1)
	s.raw(scatter_sha_raw)
	return s.hex()


def derivative_hash(d: dict[str, Any]) -> str:
	"""§3.2 over a parsed descriptor (the dict returned by parse_descriptor)."""
	s = _Stream()
	s.raw(DERIVATIVE_MAGIC)
	s.str_(d["asset_id"])
	s.u32(d["asset_version"])
	s.raw(bytes.fromhex(d["source_content_hash"]))
	s.str_(d["category"])
	s.u8(1 if d["vegetation"] else 0)
	s.u8(1 if d["decorative"] else 0)
	for role in ROLES:
		alias = d["aliases"][role]
		s.str_(role)
		s.u8(1 if alias else 0)
		s.str_(alias if alias else d["roles"][role]["mesh"])
		s.u32(0 if alias else d["roles"][role]["triangles"])
		s.u32(0 if alias else d["roles"][role]["surfaces"])
	s.u32(len(d["dependencies"]))
	for dep in d["dependencies"]:
		s.str_(dep["key"])
		s.str_(dep["type"])
		s.str_(dep["path"])
		s.u64(dep["bytes"])
		s.raw(bytes.fromhex(dep["sha256"]))
	s.u32(len(d["materials"]))
	for k in sorted(d["materials"], key=lambda x: x.encode("utf-8")):
		m = d["materials"][k]
		s.str_(k)
		s.str_(m["dependency"])
		s.str_(m["alpha_mode"])
		s.str_(m["texture"])
	s.u32(len(d["textures"]))
	for k in sorted(d["textures"], key=lambda x: x.encode("utf-8")):
		low, prev = d["textures"][k]["low"], d["textures"][k]["preview"]
		s.str_(k)
		s.str_(low["dependency"])
		s.u32(low["width"])
		s.u32(low["height"])
		s.str_(prev["dependency"] if prev else "")
		s.u32(prev["width"] if prev else 0)
		s.u32(prev["height"] if prev else 0)
	return s.hex()


# --- parsing ---------------------------------------------------------------------------
def parse_descriptor(data: Any) -> tuple[dict[str, Any] | None, str]:
	"""Returns (descriptor, "") or (None, "<reason>: detail"). Dependency paths stay relative."""
	if not isinstance(data, dict):
		return None, "descriptor_invalid: root is not an object"
	sv = data.get("schema_version")
	if is_number(sv) and float(sv) != SCHEMA_VERSION:
		return None, "unsupported_version: schema_version %s is not supported (expected %d)" % (sv, SCHEMA_VERSION)
	out: dict[str, Any] = {"aliases": {}, "roles": {}, "materials": {}, "textures": {}, "dependencies": []}
	err = check_keys(data, TOP_KEYS, "descriptor")
	for step in (_scalars, _geometry, _dependencies, _roles, _overview, _materials_textures):
		if err:
			break
		err = step(data, out)
	if err:
		return None, err if has_reason(err) else "descriptor_invalid: " + err
	return out, ""


def _below(a: tuple[float, float, float], b: tuple[float, float, float]) -> bool:
	return all(x < y for x, y in zip(a, b))


def _scalars(d: dict[str, Any], out: dict[str, Any]) -> str:
	if d["format"] != FORMAT:
		return "format must be '%s'" % FORMAT
	if not is_int(d["schema_version"]):
		return "schema_version must be an integer"
	if not is_str(d["asset_id"]):
		return "asset_id must be a non-empty string"
	if not is_int_in(d["asset_version"], 1, MAX_U32):
		return "asset_version must be a positive integer"
	for key in ("source_content_hash", "derivative_hash"):
		if not is_hex64(d[key]):
			return "%s must be 64 lowercase hex characters" % key
	if not isinstance(d["category"], str) or d["category"] not in CATEGORIES:
		return "category '%s' is not allowed" % (d["category"],)
	if not isinstance(d["vegetation"], bool) or not isinstance(d["decorative"], bool):
		return "vegetation and decorative must be booleans"
	for key in ("provenance", "license"):
		if not is_str(d[key]):
			return "%s must be a non-empty string" % key
	for key in ("asset_id", "source_content_hash", "derivative_hash", "category", "vegetation", "decorative",
			"provenance", "license"):
		out[key] = d[key]
	out["asset_version"] = int(d["asset_version"])
	return ""


def _geometry(d: dict[str, Any], out: dict[str, Any]) -> str:
	anchor, bmin, bmax = vec3(d["anchor_local_m"]), vec3(d["bounds_min_m"]), vec3(d["bounds_max_m"])
	if anchor is None or bmin is None or bmax is None:
		return "anchor_local_m/bounds_min_m/bounds_max_m must be 3 finite numbers"
	if not _below(bmin, bmax):
		return "bounds_min_m must be below bounds_max_m on every axis"
	if not is_number(d["footprint_radius_m"]) or float(d["footprint_radius_m"]) <= 0.0:
		return "footprint_radius_m must be a positive finite number"
	out.update(anchor=anchor, bounds_min=bmin, bounds_max=bmax, footprint_radius_m=float(d["footprint_radius_m"]))
	return ""


def _check_dependency(e: dict[str, Any], prev_key: str) -> str:
	if not is_str(e["key"]):
		return "dependency key must be a non-empty string"
	if e["key"].encode("utf-8") <= prev_key.encode("utf-8"):
		return "dependencies must be sorted by key with unique keys ('%s')" % e["key"]
	if not isinstance(e["type"], str) or e["type"] not in DEP_TYPES:
		return "dependency '%s' type '%s' is not allowed" % (e["key"], e["type"])
	perr = path_error(e["path"])
	if perr:
		return "path_rejected: dependency '%s': %s" % (e["key"], perr)
	ext = ".png" if e["type"] == "texture" else ".tres"
	if not e["path"].endswith(ext):
		return "path_rejected: dependency '%s' (%s) must be a %s file" % (e["key"], e["type"], ext)
	if not is_int_in(e["bytes"], 1, MAX_DEP_BYTES):
		return "dependency '%s' bytes must be 1..%d" % (e["key"], MAX_DEP_BYTES)
	if not is_hex64(e["sha256"]):
		return "dependency '%s' sha256 must be 64 lowercase hex characters" % e["key"]
	for k in ("gpu_bytes", "staging_bytes"):
		if not is_int_in(e[k], 0, MAX_U32):
			return "dependency '%s' %s must be an integer 0..%d" % (e["key"], k, MAX_U32)
	return ""


def _dependencies(d: dict[str, Any], out: dict[str, Any]) -> str:
	deps = d["dependencies"]
	if not isinstance(deps, list):
		return "dependencies must be an array"
	seen: set[str] = set()
	prev = ""
	for e in deps:
		if not isinstance(e, dict):
			return "dependency entry is not an object"
		err = check_keys(e, DEP_KEYS, "dependency") or _check_dependency(e, prev)
		if err:
			return err
		if e["path"] in seen:
			return "duplicate dependency path '%s'" % e["path"]
		seen.add(e["path"])
		prev = e["key"]
		out["dependencies"].append({"key": e["key"], "type": e["type"], "path": e["path"], "bytes": int(e["bytes"]),
			"sha256": e["sha256"], "gpu_bytes": int(e["gpu_bytes"]), "staging_bytes": int(e["staging_bytes"])})
	return ""


def _dep_type(out: dict[str, Any], key: Any) -> str:
	if isinstance(key, str):
		for dep in out["dependencies"]:
			if dep["key"] == key:
				return dep["type"]
	return ""


def _mesh_entry(role: str, e: dict[str, Any], out: dict[str, Any]) -> str:
	err = check_keys(e, MESH_KEYS, "role '%s'" % role)
	if err:
		return err
	if _dep_type(out, e["mesh"]) != "mesh":
		return "role '%s' mesh '%s' is not a mesh dependency" % (role, e["mesh"])
	if not is_int_in(e["triangles"], 1, MAX_U32):
		return "role '%s' triangles must be an integer >= 1" % role
	if not is_int_in(e["surfaces"], 1, 8):
		return "role '%s' surfaces must be an integer 1..8" % role
	amin, amax = vec3(e["aabb_min_m"]), vec3(e["aabb_max_m"])
	if amin is None or amax is None or not _below(amin, amax):
		return "role '%s' aabb must be finite with min below max" % role
	out["roles"][role] = {"mesh": e["mesh"], "triangles": int(e["triangles"]), "surfaces": int(e["surfaces"]),
		"aabb_min": amin, "aabb_max": amax}
	return ""


def _roles(d: dict[str, Any], out: dict[str, Any]) -> str:
	reps = d["representations"]
	if not isinstance(reps, dict):
		return "representations must be an object"
	err = check_keys(reps, ROLES, "representations")
	if err:
		return err
	for role in ROLES:
		e = reps[role]
		if not isinstance(e, dict):
			return "role '%s' is not an object" % role
		if "alias" in e:
			err = check_keys(e, ("alias",), "role '%s'" % role)
			if not err and (not isinstance(e["alias"], str) or e["alias"] not in ROLES):
				err = "role '%s' alias '%s' is not a role" % (role, e["alias"])
			out["aliases"][role] = e["alias"] if not err else ""
		else:
			err = _mesh_entry(role, e, out)
			out["aliases"][role] = ""
		if err:
			return err
	for role in ROLES:
		cur, steps = role, 0
		while out["aliases"][cur]:
			cur = out["aliases"][cur]
			steps += 1
			if steps > 2:
				return "role '%s' alias chain is cyclic or longer than 2 steps" % role
		out["roles"][role] = dict(out["roles"][cur])
	return ""


def _overview(d: dict[str, Any], out: dict[str, Any]) -> str:
	o = d["overview"]
	if not isinstance(o, dict):
		return "overview must be an object"
	err = check_keys(o, OVERVIEW_KEYS, "overview")
	if err:
		return err
	if o["kind"] not in ("canopy", "solid", "none") or not isinstance(o["kind"], str):
		return "overview kind '%s' is not allowed" % (o["kind"],)
	if o["shape"] not in ("cone", "ellipsoid", "box") or not isinstance(o["shape"], str):
		return "overview shape '%s' is not allowed" % (o["shape"],)
	if not is_number(o["base_y_m"]):
		return "overview base_y_m must be finite"
	for k in ("height_m", "radius_m"):
		if not is_number(o[k]) or float(o[k]) <= 0.0:
			return "overview %s must be a positive finite number" % k
	c = vec3(o["color"])
	if c is None or any(x < 0.0 or x > 1.0 for x in c):
		return "overview color must be 3 numbers in [0, 1]"
	out["overview"] = dict(o)
	return ""


def _tier(key: str, name: str, t: Any, max_dim: int, out: dict[str, Any]) -> Any:
	"""Returns the tier dict or an error string."""
	what = "texture '%s' %s" % (key, name)
	if not isinstance(t, dict):
		return "%s is not an object" % what
	err = check_keys(t, TIER_KEYS, what)
	if err:
		return err
	if _dep_type(out, t["dependency"]) != "texture":
		return "%s dependency '%s' is not a texture dependency" % (what, t["dependency"])
	for k in ("width", "height"):
		if not is_int_in(t[k], 1, max_dim) or int(t[k]) & (int(t[k]) - 1) != 0:
			return "%s %s must be a power of two <= %d" % (what, k, max_dim)
	if t["mipmaps"] is not True:
		return "%s must have mipmaps" % what
	return {"dependency": t["dependency"], "width": int(t["width"]), "height": int(t["height"])}


def _materials_textures(d: dict[str, Any], out: dict[str, Any]) -> str:
	mats, texs = d["materials"], d["textures"]
	if not isinstance(mats, dict) or not isinstance(texs, dict):
		return "materials and textures must be objects"
	for key, t in texs.items():
		if key == "" or not isinstance(t, dict):
			return "texture entry '%s' is invalid" % key
		err = check_keys(t, ("low", "preview"), "texture '%s'" % key)
		if err:
			return err
		low = _tier(key, "low", t["low"], LOW_MAX_DIM, out)
		prev = None if t["preview"] is None else _tier(key, "preview", t["preview"], PREVIEW_MAX_DIM, out)
		for tier in (low, prev):
			if isinstance(tier, str):
				return tier
		out["textures"][key] = {"low": low, "preview": prev}
	for key, m in mats.items():
		if key == "" or not isinstance(m, dict):
			return "material entry '%s' is invalid" % key
		err = check_keys(m, ("dependency", "alpha_mode", "texture"), "material '%s'" % key)
		if err:
			return err
		if _dep_type(out, m["dependency"]) != "material":
			return "material '%s' dependency '%s' is not a material dependency" % (key, m["dependency"])
		if m["alpha_mode"] not in ("opaque", "cutout") or not isinstance(m["alpha_mode"], str):
			return "material '%s' alpha_mode '%s' is not allowed" % (key, m["alpha_mode"])
		if m["texture"] is not None and (not isinstance(m["texture"], str) or m["texture"] not in out["textures"]):
			return "material '%s' texture '%s' is not a texture key" % (key, m["texture"])
		out["materials"][key] = {"dependency": m["dependency"], "alpha_mode": m["alpha_mode"],
			"texture": m["texture"] or ""}
	listed = {m["dependency"] for m in out["materials"].values()}
	for dep in out["dependencies"]:
		if dep["type"] == "material" and dep["key"] not in listed:
			return "material dependency '%s' is not listed in materials" % dep["key"]
	return ""

