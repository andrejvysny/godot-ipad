#!/usr/bin/env python3
"""Validate a render-asset registry against its logical catalog (docs/render-assets.md).

Usage: python3 scripts/validate_render_assets.py [--index PATH] [--catalog-dir PATH] [--app-dir DIR]
Prints one line per catalog asset: READY or NOT_READY <reason>. Exit 0 when the index and every
asset listed in it are valid (catalog assets absent from the index are reported, not failures),
1 otherwise, 2 for usage errors. Same checks and stable reasons as the runtime
(app/addons/world_painter/presentation/rendering/render_asset_registry.gd) plus sha256 of every dependency incl. .png, PNG
IHDR sizes vs the descriptor, and the .png.import compression settings.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_asset_format as raf  # noqa: E402
from worldpoc_constants import APP_DIR  # noqa: E402
from worldpoc_values import FormatError, parse_json_bytes  # noqa: E402

DEFAULT_INDEX = APP_DIR / "assets" / "render_assets" / "index.json"
DEFAULT_CATALOG_DIR = APP_DIR / "assets"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
TOLERANCE = 1e-6
INDEX_KEYS = ("format", "schema_version", "catalog_id", "catalog_version", "prepared_for", "assets")
PREPARED_KEYS = ("godot", "renderer", "texture_formats")
ENTRY_KEYS = ("asset_id", "asset_version", "descriptor", "descriptor_sha256")
IMPORT_REQUIRED = {"compress/mode": "2", "mipmaps/generate": "true", "compress/normal_map": "2"}


class Report:
	def __init__(self) -> None:
		self.index_error = ""
		self.index_reason = ""
		self.assets: dict[str, tuple[str, str]] = {}  # asset id -> (reason, detail); reason "" = READY
		self.listed: set[str] = set()

	def failed(self) -> bool:
		return bool(self.index_error) or any(self.assets[i][0] for i in self.listed)

	def lines(self) -> list[str]:
		out = []
		if self.index_error:
			out.append("INDEX %s: %s" % (self.index_reason, self.index_error))
		for aid in sorted(self.assets):
			reason, detail = self.assets[aid]
			out.append("%s READY" % aid if not reason else "%s NOT_READY %s%s" % (aid, reason, " (%s)" % detail if detail else ""))
		return out


def find_app_dir(catalog_dir: Path) -> Path:
	for p in [catalog_dir.resolve(), *catalog_dir.resolve().parents]:
		if (p / "project.godot").is_file():
			return p
	return APP_DIR


def _res_path(app_dir: Path, res: str) -> Path | None:
	if not res.startswith("res://") or raf.path_error(res[len("res://"):]):
		return None
	return app_dir / res[len("res://"):]


def _load_json(path: Path) -> tuple[Any, str]:
	try:
		return parse_json_bytes(path.read_bytes()), ""
	except OSError as e:
		return None, "cannot read '%s' (%s)" % (path, e.strerror)
	except FormatError as e:
		return None, "'%s' is not valid JSON (%s)" % (path.name, e)


def _check_index(data: Any, catalog: dict[str, Any]) -> tuple[str, str]:
	"""Returns (reason, detail); reason '' when acceptable."""
	if not isinstance(data, dict):
		return "no_registry", "index root is not an object"
	sv = data.get("schema_version")
	if raf.is_number(sv) and float(sv) != 1:
		return "unsupported_version", "index schema_version %s is not supported" % sv
	err = raf.check_keys(data, INDEX_KEYS, "index")
	if not err:
		err = _index_fields(data)
	if err:
		return "no_registry", err
	if data["catalog_id"] != catalog["catalog_id"] or int(data["catalog_version"]) != int(catalog["catalog_version"]):
		return "catalog_mismatch", "index is for catalog %s v%s, expected %s v%s" % (
			data["catalog_id"], data["catalog_version"], catalog["catalog_id"], catalog["catalog_version"])
	return "", ""


def _index_fields(d: dict[str, Any]) -> str:
	if d["format"] != "world-painter-render-assets" or not raf.is_int(d["schema_version"]):
		return "index format must be 'world-painter-render-assets'"
	if not raf.is_str(d["catalog_id"]) or not raf.is_int_in(d["catalog_version"], 1, raf.MAX_U32):
		return "catalog_id/catalog_version are invalid"
	p = d["prepared_for"]
	if not isinstance(p, dict):
		return "prepared_for must be an object"
	err = raf.check_keys(p, PREPARED_KEYS, "prepared_for")
	if err:
		return err
	if not raf.is_str(p["godot"]) or not raf.is_str(p["renderer"]) or not isinstance(p["texture_formats"], list):
		return "prepared_for fields are invalid"
	if not isinstance(d["assets"], list):
		return "assets must be an array"
	prev = ""
	for e in d["assets"]:
		if not isinstance(e, dict):
			return "asset entry is not an object"
		err = raf.check_keys(e, ENTRY_KEYS, "asset entry")
		if err:
			return err
		if not raf.is_str(e["asset_id"]) or not raf.is_int_in(e["asset_version"], 1, raf.MAX_U32) \
				or not raf.is_hex64(e["descriptor_sha256"]) or not isinstance(e["descriptor"], str):
			return "asset entry fields are invalid"
		if e["asset_id"].encode("utf-8") <= prev.encode("utf-8"):
			return "assets must be sorted by asset_id with unique ids ('%s')" % e["asset_id"]
		prev = e["asset_id"]
	return ""


def _sha_file(path: Path, cache: dict[Path, bytes]) -> bytes:
	"""Raw sha256 of a file; b'' when unreadable."""
	if path not in cache:
		try:
			cache[path] = hashlib.sha256(path.read_bytes()).digest()
		except OSError:
			cache[path] = b""
	return cache[path]


def _source_hash(asset: dict[str, Any], app_dir: Path, cache: dict[Path, bytes]) -> str:
	preview = _res_path(app_dir, asset["preview_scene"])
	scatter_res = asset.get("scatter_mesh")
	scatter = _res_path(app_dir, scatter_res) if scatter_res else None
	p_sha = _sha_file(preview, cache) if preview else b""
	s_sha = _sha_file(scatter, cache) if scatter else b""
	if not p_sha or (scatter_res and not s_sha):
		return ""
	return raf.source_content_hash(asset["asset_id"], int(asset["version"]), p_sha, s_sha)


def _close(a: tuple[float, ...], b: list[Any]) -> bool:
	return all(abs(x - float(y)) <= TOLERANCE for x, y in zip(a, b))


def _check_identity(desc: dict[str, Any], entry: dict[str, Any], catalog: dict[str, dict[str, Any]],
		app_dir: Path, cache: dict[Path, bytes]) -> tuple[str, str]:
	if desc["asset_id"] != entry["asset_id"] or desc["asset_version"] != int(entry["asset_version"]):
		return "logical_mismatch", "descriptor identity differs from its index entry"
	a = catalog.get(desc["asset_id"])
	if a is None or int(a["version"]) != desc["asset_version"]:
		return "logical_mismatch", "asset %s v%d is not in the catalog" % (desc["asset_id"], desc["asset_version"])
	src = _source_hash(a, app_dir, cache)
	if src != desc["source_content_hash"]:
		return "source_changed", "source files changed since the derivative was prepared" if src else "source files unreadable"
	if not _close(desc["anchor"], a["placement_anchor_local"]):
		return "logical_mismatch", "anchor differs from the catalog"
	if not _close(desc["bounds_min"], a["bounds_min"]) or not _close(desc["bounds_max"], a["bounds_max"]):
		return "logical_mismatch", "bounds differ from the catalog"
	if abs(desc["footprint_radius_m"] - float(a["footprint_radius_m"])) > TOLERANCE:
		return "logical_mismatch", "footprint_radius_m differs from the catalog"
	if raf.derivative_hash(desc) != desc["derivative_hash"]:
		return "derivative_hash_mismatch", "derivative_hash does not match the descriptor content"
	return "", ""


def png_size(data: bytes) -> tuple[int, int] | None:
	if len(data) < 24 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
		return None
	w, h = struct.unpack(">II", data[16:24])
	return w, h


def import_error(png: Path) -> str:
	"""'' when <png>.import carries the compression settings of docs/render-assets.md §4."""
	imp = png.with_name(png.name + ".import")
	try:
		text = imp.read_text(encoding="utf-8")
	except OSError:
		return "%s.import is missing" % png.name
	values = {}
	for line in text.splitlines():
		if "=" in line and not line.startswith(("#", ";", "[")):
			k, v = line.split("=", 1)
			values[k.strip()] = v.strip()
	for k, want in IMPORT_REQUIRED.items():
		if values.get(k) != want:
			return "%s.import needs %s=%s (found %s)" % (png.name, k, want, values.get(k))
	return ""


def _texture_sizes(desc: dict[str, Any]) -> dict[str, tuple[int, int]]:
	sizes: dict[str, tuple[int, int]] = {}
	for t in desc["textures"].values():
		for tier in (t["low"], t["preview"]):
			if tier:
				sizes[tier["dependency"]] = (tier["width"], tier["height"])
	return sizes


def _check_dependencies(desc: dict[str, Any], desc_dir: Path) -> tuple[str, str]:
	sizes = _texture_sizes(desc)
	for dep in desc["dependencies"]:
		path = desc_dir / dep["path"]
		try:
			raw = path.read_bytes()
		except OSError:
			return "dependency_missing", "dependency '%s' (%s) does not exist" % (dep["key"], dep["path"])
		if len(raw) != dep["bytes"] or hashlib.sha256(raw).hexdigest() != dep["sha256"]:
			return "dependency_hash_mismatch", "dependency '%s' (%s) does not match its descriptor entry" % (dep["key"], dep["path"])
		if dep["type"] != "texture":
			continue
		if dep["key"] in sizes and png_size(raw) != sizes[dep["key"]]:
			return "descriptor_invalid", "texture '%s' PNG size %s differs from the descriptor %s" % (
				dep["key"], png_size(raw), sizes[dep["key"]])
		err = import_error(path)
		if err:
			return "dependency_missing" if err.endswith("missing") else "descriptor_invalid", err
	return "", ""


def _check_asset(entry: dict[str, Any], index_dir: Path, catalog: dict[str, dict[str, Any]], app_dir: Path,
		cache: dict[Path, bytes]) -> tuple[str, str]:
	perr = raf.path_error(entry["descriptor"])
	if perr:
		return "path_rejected", perr
	dpath = index_dir / entry["descriptor"]
	try:
		raw = dpath.read_bytes()
	except OSError:
		return "no_derivative", "cannot read '%s'" % entry["descriptor"]
	if hashlib.sha256(raw).hexdigest() != entry["descriptor_sha256"]:
		return "descriptor_hash_mismatch", "descriptor %s does not match descriptor_sha256" % entry["descriptor"]
	try:
		data = parse_json_bytes(raw)
	except FormatError:
		return "descriptor_invalid", "descriptor %s is not valid JSON" % entry["descriptor"]
	desc, err = raf.parse_descriptor(data)
	if desc is None:
		return raf.error_reason(err), err.split(": ", 1)[1]
	bad = _check_identity(desc, entry, catalog, app_dir, cache)
	return bad if bad[0] else _check_dependencies(desc, dpath.parent)


def validate_registry(index_path: Path, catalog_dir: Path, app_dir: Path | None = None) -> Report:
	report = Report()
	app_dir = app_dir or find_app_dir(catalog_dir)
	cat_data, err = _load_json(catalog_dir / "catalog.json")
	if err or not isinstance(cat_data, dict) or not isinstance(cat_data.get("assets"), list):
		report.index_error, report.index_reason = err or "catalog is malformed", "no_registry"
		return report
	catalog = {a["asset_id"]: a for a in cat_data["assets"]}
	for aid in catalog:
		report.assets[aid] = ("no_derivative", "no index entry")
	idx, err = _load_json(index_path)
	reason, detail = ("no_registry", err) if err else _check_index(idx, cat_data)
	if reason:
		report.index_error, report.index_reason = detail, reason
		report.assets = {aid: (reason, detail) for aid in catalog}
		return report
	cache: dict[Path, bytes] = {}
	for entry in idx["assets"]:
		report.listed.add(entry["asset_id"])
		report.assets[entry["asset_id"]] = _check_asset(entry, index_path.parent, catalog, app_dir, cache)
	return report


def main(argv: list[str] | None = None) -> int:
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("--index", type=Path, default=DEFAULT_INDEX)
	p.add_argument("--catalog-dir", type=Path, default=DEFAULT_CATALOG_DIR)
	p.add_argument("--app-dir", type=Path, default=None, help="project dir that res:// maps to (default: found from the catalog dir)")
	a = p.parse_args(argv)
	report = validate_registry(a.index, a.catalog_dir, a.app_dir)
	print("\n".join(report.lines()))
	return 1 if report.failed() else 0


if __name__ == "__main__":
	sys.exit(main())
