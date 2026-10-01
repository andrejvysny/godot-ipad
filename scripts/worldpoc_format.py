#!/usr/bin/env python3
"""Shared World Painter PoC format library (docs/world-format.md), Python stdlib only.

Mirrors WorldConstants, ControlCodec, ObjectRecord, WorldDocument.sample_height and
CanonicalEncoder from app/src/document. Validators return lists of error strings; they never
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
	REPO,
	APP_DIR,
	FORMAT,
	SCHEMA_VERSION,
	SAMPLE_SPACING,
	REGION_SAMPLES,
	REGION_SAMPLE_COUNT,
	REGION_MAP_BYTES,
	REGION_LOCATIONS,
	GLOBAL_SAMPLE_MIN,
	GLOBAL_SAMPLE_MAX,
	WORLD_MIN,
	WORLD_MAX_SAMPLE,
	HEIGHT_MIN,
	HEIGHT_MAX,
	MATERIAL_GRASS,
	MATERIAL_DIRT,
	MATERIAL_SLOTS,
	MATERIAL_ROCK,
	MATERIAL_SAND,
	COLOR_ENCODING,
	DEFAULT_CONTROL,
	DEFAULT_COLOR,
	RULE_SPECS,
	DEFAULT_RULES,
	SCATTER_MAGIC,
	PATHS_MAGIC,
	SCATTER_MAX_INSTANCES,
	PATHS_MAX_COUNT,
	SCATTER_MAX_BYTES,
	PATHS_MAX_BYTES,
	SCATTER_PATH,
	PATHS_PATH,
	color_path,
	HEIGHT_ENCODING,
	CONTROL_ENCODING,
	CONTROL_SCHEMA,
	GROUNDINGS,
	ORIGINS,
	TERRAIN_BLOCK,
	MANIFEST_MAX_BYTES,
	OBJECTS_MAX_BYTES,
	PACKAGE_MAX_TOTAL_BYTES,
	PACKAGE_MAX_FILE_BYTES,
	MAX_OBJECTS,
	QUAT_TOLERANCE,
	GROUNDING_TOLERANCE_M,
	UUID_RE,
	SHA256_RE,
	HEX16_RE,
	AUTHORED_MAGIC,
	CATALOG_MAGIC,
	region_stem,
	height_path,
	control_path,
	PAYLOAD_PATHS,
	GENERATION_FILES,
)

from worldpoc_values import (
	f64_hex,
	f64_from_hex,
	BASE_SHIFT,
	OVERLAY_SHIFT,
	BLEND_SHIFT,
	ID_MASK,
	BLEND_MASK,
	AUTO_BIT,
	NAV_BIT,
	HOLE_BIT,
	U32,
	PAINT_OWNED_MASK,
	control_decode,
	control_encode_paint,
	control_is_supported,
	GRASS_VALUE,
	sha256_hex,
	sha256_file,
	_Stream,
	authored_hash,
	FormatError,
	show,
	_reject_constant,
	_no_duplicates,
	parse_json_bytes,
	dump_json,
	is_number,
	_as_float,
	is_finite_number,
	is_json_int,
	_res_to_path,
	catalog_geometry_paths,
	catalog_sha256,
	load_trusted_catalog,
	make_object_record,
	_exact,
	_finite_list,
	_RECORD_FIELDS,
	parse_object_record,
	check_record_against_catalog,
)

from worldpoc_scatter import (
	parse_scatter,
	parse_paths,
	check_scatter_catalog,
	write_scatter,
	write_paths,
)

from worldpoc_terrain import (
	load_region_arrays,
	height_at_sample,
	sample_height,
)

from worldpoc_package import (
	PACKAGE_ALLOWED_DIRS,
	_entry_limit,
	EOCD_SIZE,
	EOCD_SEARCH,
	SIG_EOCD,
	SIG_ZIP64_LOCATOR,
	PACKAGE_MAX_ENTRIES,
	_zip64_locator_present,
	schema_error,
	_archive_layout_error,
	_entry_uses_zip64,
	_check_entry_name,
	inspect_zip,
	safe_extract,
	write_package,
)

# --- Generation directory (world-format §2, §3, §9) ------------------------------------
class Generation:
	"""Parsed generation: manifest, exact object records, raw region bytes."""

	def __init__(self) -> None:
		self.manifest: dict[str, Any] = {}
		self.records: list[dict[str, Any]] = []
		self.heights: dict[tuple[int, int], bytes] = {}
		self.controls: dict[tuple[int, int], bytes] = {}
		self.colors: dict[tuple[int, int], bytes] = {}
		self.scatter_bytes = b""
		self.paths_bytes = b""
		self.scatter: dict[str, Any] = {}
		self.paths: list[dict[str, Any]] = []
		self.rules: dict[str, Any] = {}
		self.authored_hash = ""


def _list_files(root: Path) -> set[str]:
	return {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() or p.is_symlink()}


def read_generation_dir(gen_dir: Path) -> tuple[Generation | None, list[str]]:
	"""Loads files and checks presence/extras/JSON syntax. Content rules are in validate_generation."""
	gen = Generation()
	errors: list[str] = []
	if not gen_dir.is_dir():
		return None, ["generation directory '%s' does not exist" % gen_dir]
	present = _list_files(gen_dir)
	for name in sorted(GENERATION_FILES - present):
		errors.append("missing file '%s'" % name)
	for name in sorted(present - GENERATION_FILES):
		errors.append("unexpected file %s" % show(name))
	for name in sorted(present & GENERATION_FILES):
		if (gen_dir / name).is_symlink():
			errors.append("file '%s' is a symlink" % name)
	if errors:
		return None, _schema_first(gen_dir) + errors
	try:
		gen.manifest = parse_json_bytes((gen_dir / "manifest.json").read_bytes())
	except FormatError as e:
		return None, ["manifest.json is not valid JSON: %s" % e]
	for loc in REGION_LOCATIONS:
		gen.heights[loc] = (gen_dir / height_path(loc)).read_bytes()
		gen.controls[loc] = (gen_dir / control_path(loc)).read_bytes()
		gen.colors[loc] = (gen_dir / color_path(loc)).read_bytes()
	gen.scatter_bytes = (gen_dir / SCATTER_PATH).read_bytes()
	gen.paths_bytes = (gen_dir / PATHS_PATH).read_bytes()
	return gen, []


def _schema_first(gen_dir: Path) -> list[str]:
	"""A directory with the wrong file set but a readable manifest of another schema (e.g. schema 1)
	gets the explicit unknown-schema diagnostic before the file-set errors."""
	manifest = gen_dir / "manifest.json"
	try:
		m = parse_json_bytes(manifest.read_bytes()) if manifest.is_file() and not manifest.is_symlink() else None
	except (FormatError, OSError):
		return []
	if isinstance(m, dict) and not (is_json_int(m.get("schema_version")) and m["schema_version"] == SCHEMA_VERSION):
		return [_unknown_schema(m.get("schema_version"))]
	return []


def _unknown_schema(v: Any) -> str:
	return "unknown schema_version %s (supported: %d; older schemas are not migrated)" % (show(v), SCHEMA_VERSION)


def _check_manifest_header(m: Any, trusted: dict[str, Any]) -> list[str]:
	if not isinstance(m, dict):
		return ["manifest is not a JSON object"]
	if m.get("format") != FORMAT:
		return ["unknown format %s (expected %r)" % (show(m.get("format")), FORMAT)]
	if not is_json_int(m.get("schema_version")) or m["schema_version"] != SCHEMA_VERSION:
		return [_unknown_schema(m.get("schema_version"))]
	errors: list[str] = []
	if not isinstance(m.get("world_id"), str) or not UUID_RE.match(m["world_id"]):
		errors.append("world_id is not a lowercase UUID")
	if not is_json_int(m.get("document_revision")) or m["document_revision"] < 0:
		errors.append("document_revision must be a non-negative integer")
	cw = m.get("created_with")
	if not isinstance(cw, dict) or not all(isinstance(cw.get(k), str) and cw[k] for k in ("godot", "terrain3d", "world_painter")):
		errors.append("created_with must name godot, terrain3d and world_painter")
	cat = m.get("catalog")
	if not isinstance(cat, dict):
		errors.append("catalog block missing")
	else:
		if cat.get("id") != trusted["id"]:
			errors.append("unknown catalog id %s (trusted: %r)" % (show(cat.get("id")), trusted["id"]))
		if not is_json_int(cat.get("version")) or cat["version"] != trusted["version"]:
			errors.append("catalog version %s does not match trusted version %d" % (show(cat.get("version")), trusted["version"]))
		if cat.get("sha256") != trusted["sha256"]:
			errors.append("catalog sha256 %s does not match trusted catalog %s" % (show(cat.get("sha256")), trusted["sha256"]))
	errors += _check_terrain_block(m.get("terrain"))
	return errors


def _check_terrain_block(t: Any) -> list[str]:
	if not isinstance(t, dict):
		return ["terrain block missing"]
	errors = []
	for key in sorted(set(t) - set(TERRAIN_BLOCK)):
		errors.append("terrain block has unknown field %s" % show(key))
	for key, expected in TERRAIN_BLOCK.items():
		v = t.get(key)
		if key == "rules":
			errors += _check_rules(v)
			continue
		if key in ("sample_spacing_m", "region_samples"):
			ok = is_finite_number(v) and float(v) == float(expected)
		elif key == "region_locations":
			ok = isinstance(v, list) and len(v) == len(expected) and all(
				isinstance(a, list) and len(a) == 2 and all(is_json_int(c) for c in a) and [int(c) for c in a] == b
				for a, b in zip(v, expected))
		else:
			ok = v == expected
		if not ok:
			errors.append("terrain.%s is %s, expected %r" % (key, show(v), expected))
	return errors


def _check_rules(v: Any) -> list[str]:
	"""terrain.rules: exactly the four keys; booleans are JSON bools, integers integral and in range."""
	if not isinstance(v, dict):
		return ["terrain.rules is %s, expected an object" % show(v)]
	errors = ["terrain.rules has unknown field %s" % show(k) for k in sorted(set(v) - set(RULE_SPECS))]
	for key, (kind, lo, hi) in RULE_SPECS.items():
		if key not in v:
			errors.append("terrain.rules.%s is missing" % key)
		elif kind == "bool":
			if not isinstance(v[key], bool):
				errors.append("terrain.rules.%s is %s, expected a JSON boolean" % (key, show(v[key])))
		elif not is_json_int(v[key]) or isinstance(v[key], bool):
			errors.append("terrain.rules.%s is %s, expected an integer" % (key, show(v[key])))
		elif not (lo <= v[key] <= hi):
			errors.append("terrain.rules.%s is %s, expected [%d, %d]" % (key, show(v[key]), lo, hi))
	return errors


def _rules_of(manifest: dict[str, Any]) -> dict[str, Any]:
	"""Rule values of an already validated manifest, as plain bool/int."""
	r = manifest["terrain"]["rules"]
	return {k: (r[k] if kind == "bool" else int(r[k])) for k, (kind, _, _) in RULE_SPECS.items()}


def _is_placeholder_hash(h: Any) -> bool:
	return not isinstance(h, str) or not SHA256_RE.match(h) or len(set(h)) == 1


def _check_payload_files(m: dict[str, Any], gen_dir: Path) -> list[str]:
	pf = m.get("payload_files")
	if not isinstance(pf, list):
		return ["payload_files missing"]
	errors: list[str] = []
	paths = [e.get("path") if isinstance(e, dict) else None for e in pf]
	if sorted(p for p in paths if isinstance(p, str)) != PAYLOAD_PATHS or len(paths) != len(PAYLOAD_PATHS):
		errors.append("payload_files must list exactly %s" % PAYLOAD_PATHS)
	elif paths != PAYLOAD_PATHS:
		errors.append("payload_files are not sorted by path")
	for e in pf:
		if not isinstance(e, dict) or e.get("path") not in PAYLOAD_PATHS:
			continue
		path = gen_dir / e["path"]
		size = path.stat().st_size
		if not is_json_int(e.get("bytes")) or int(e["bytes"]) != size:
			errors.append("payload '%s' bytes %s != actual %d" % (e["path"], show(e.get("bytes")), size))
		if _is_placeholder_hash(e.get("sha256")):
			errors.append("payload '%s' has a missing or placeholder sha256 %s" % (e["path"], show(e.get("sha256"))))
		elif e["sha256"] != sha256_file(path):
			errors.append("payload '%s' sha256 mismatch" % e["path"])
	return errors


def _check_region_bytes(gen: Generation) -> list[str]:
	errors: list[str] = []
	for loc in REGION_LOCATIONS:
		h, c = gen.heights[loc], gen.controls[loc]
		if len(h) != REGION_MAP_BYTES:
			errors.append("%s has %d bytes, expected %d" % (height_path(loc), len(h), REGION_MAP_BYTES))
		else:
			hs = load_region_arrays({loc: h})[loc]
			bad = next((i for i, v in enumerate(hs) if not (math.isfinite(v) and HEIGHT_MIN <= v <= HEIGHT_MAX)), -1)
			if bad >= 0:
				errors.append("%s sample %d height %r is not finite within [%g, %g]"
					% (height_path(loc), bad, hs[bad], HEIGHT_MIN, HEIGHT_MAX))
		if len(c) != REGION_MAP_BYTES:
			errors.append("%s has %d bytes, expected %d" % (control_path(loc), len(c), REGION_MAP_BYTES))
		else:
			# Control words are raw uint32 bit patterns; a float-NaN-looking value is valid.
			cs = array("I")
			cs.frombytes(c)
			if sys.byteorder != "little":
				cs.byteswap()
			bad = next((i for i, v in enumerate(cs) if not control_is_supported(v)), -1)
			if bad >= 0:
				errors.append("%s sample %d control 0x%08x uses unsupported material ids"
					% (control_path(loc), bad, cs[bad]))
		if len(gen.colors[loc]) != REGION_MAP_BYTES:
			errors.append("%s has %d bytes, expected %d" % (color_path(loc), len(gen.colors[loc]), REGION_MAP_BYTES))
	return errors


def _check_scatter_and_paths(gen: Generation, trusted: dict[str, Any]) -> list[str]:
	errors: list[str] = []
	if len(gen.scatter_bytes) > SCATTER_MAX_BYTES:
		errors.append("scatter.bin is %d bytes (limit %d)" % (len(gen.scatter_bytes), SCATTER_MAX_BYTES))
	else:
		scatter, err = parse_scatter(gen.scatter_bytes)
		if scatter is None:
			errors.append(err)
		else:
			gen.scatter = scatter
			errors += check_scatter_catalog(scatter, trusted["assets"])
	if len(gen.paths_bytes) > PATHS_MAX_BYTES:
		errors.append("paths.bin is %d bytes (limit %d)" % (len(gen.paths_bytes), PATHS_MAX_BYTES))
	else:
		paths, err = parse_paths(gen.paths_bytes)
		if paths is None:
			errors.append(err)
		else:
			gen.paths = paths
	return errors


def _check_objects(gen_dir: Path, gen: Generation, trusted: dict[str, Any]) -> list[str]:
	try:
		doc = parse_json_bytes((gen_dir / "objects.json").read_bytes())
	except FormatError as e:
		return ["objects.json is not valid JSON: %s" % e]
	if not isinstance(doc, dict) or not is_json_int(doc.get("schema_version")) or doc["schema_version"] != SCHEMA_VERSION:
		return ["objects.json has unknown schema_version (supported: %d)" % SCHEMA_VERSION]
	objs = doc.get("objects")
	if not isinstance(objs, list):
		return ["objects.json 'objects' must be an array"]
	if len(objs) > MAX_OBJECTS:
		return ["objects.json has %d objects (max %d)" % (len(objs), MAX_OBJECTS)]
	errors: list[str] = []
	seen: set[str] = set()
	prev = b""
	for d in objs:
		rec, err = parse_object_record(d)
		if rec is None:
			errors.append(err)
			continue
		key = rec["object_id"].encode("utf-8")
		if rec["object_id"] in seen:
			errors.append("duplicate object_id %s" % rec["object_id"])
		elif key < prev:
			errors.append("objects are not sorted by object_id (%s)" % rec["object_id"])
		seen.add(rec["object_id"])
		prev = max(prev, key)
		errors += check_record_against_catalog(rec, trusted["assets"])
		gen.records.append(rec)
	return errors


def _region_digests(heights: dict[tuple[int, int], bytes], controls: dict[tuple[int, int], bytes],
		colors: dict[tuple[int, int], bytes]) -> dict[tuple[int, int], tuple[bytes, bytes, bytes]]:
	return {loc: (hashlib.sha256(heights[loc]).digest(), hashlib.sha256(controls[loc]).digest(),
		hashlib.sha256(colors[loc]).digest()) for loc in REGION_LOCATIONS}


def validate_generation(gen_dir: Path, app_dir: Path = APP_DIR) -> tuple[Generation | None, list[str]]:
	"""Every generation rule of world-format §9. Returns (generation, errors)."""
	gen_dir = Path(gen_dir)
	gen, errors = read_generation_dir(gen_dir)
	if gen is None:
		return None, errors
	trusted = load_trusted_catalog(app_dir)
	errors = _check_manifest_header(gen.manifest, trusted)
	fatal = ("manifest is not", "unknown format", "unknown schema_version")
	if any(e.startswith(fatal) for e in errors):
		return gen, errors
	errors += _check_payload_files(gen.manifest, gen_dir)
	errors += _check_region_bytes(gen)
	errors += _check_objects(gen_dir, gen, trusted)
	errors += _check_scatter_and_paths(gen, trusted)
	if not errors:
		gen.rules = _rules_of(gen.manifest)
		cat = gen.manifest["catalog"]
		gen.authored_hash = authored_hash(
			{"id": cat["id"], "version": int(cat["version"]), "sha256": cat["sha256"]}, gen.rules,
			_region_digests(gen.heights, gen.controls, gen.colors), gen.scatter_bytes, gen.paths_bytes, gen.records)
		stored = gen.manifest.get("authored_content_hash")
		if _is_placeholder_hash(stored):
			errors.append("authored_content_hash is missing or a placeholder")
		elif stored != gen.authored_hash:
			errors.append("authored_content_hash %s != computed %s" % (show(stored), gen.authored_hash))
	return gen, errors


def grounding_report(gen: Generation, tolerance: float = GROUNDING_TOLERANCE_M) -> list[str]:
	"""FOLLOW_TERRAIN consistency (warnings only; never re-snaps)."""
	regions = load_region_arrays(gen.heights)
	warnings: list[str] = []
	for r in gen.records:
		if r["grounding"] != "FOLLOW_TERRAIN":
			continue
		x, y, z = r["position"]
		terrain = sample_height(regions, x, z, gen.controls)
		if math.isnan(terrain):
			warnings.append("object %s: no terrain sample at (%r, %r)" % (r["object_id"], x, z))
		elif abs(y - (terrain + r["height_offset_m"])) > tolerance:
			warnings.append("object %s: FOLLOW_TERRAIN y=%.6f but terrain+offset=%.6f"
				% (r["object_id"], y, terrain + r["height_offset_m"]))
	return warnings


def write_generation(gen_dir: Path, doc: dict[str, Any]) -> dict[str, Any]:
	"""Writes a generation; manifest last. `doc` keys: world_id, document_revision, created_with,
	catalog {id, version, sha256}, heights/controls/colors {loc: bytes}, objects [record dicts];
	optional rules (default DEFAULT_RULES), scatter (instance dicts) and paths (path dicts)."""
	gen_dir = Path(gen_dir)
	(gen_dir / "regions").mkdir(parents=True, exist_ok=True)
	objects = sorted(doc.get("objects", []), key=lambda r: r["object_id"].encode("utf-8"))
	rules = dict(doc.get("rules", DEFAULT_RULES))
	scatter_bytes = write_scatter(doc.get("scatter", []))
	paths_bytes = write_paths(doc.get("paths", []))
	payload: dict[str, bytes] = {"objects.json": dump_json({"schema_version": SCHEMA_VERSION, "objects": objects}),
		SCATTER_PATH: scatter_bytes, PATHS_PATH: paths_bytes}
	for loc in REGION_LOCATIONS:
		payload[height_path(loc)] = doc["heights"][loc]
		payload[control_path(loc)] = doc["controls"][loc]
		payload[color_path(loc)] = doc["colors"][loc]
	for rel, data in payload.items():
		(gen_dir / rel).write_bytes(data)
	records = [parse_object_record(o)[0] for o in objects]
	digests = _region_digests(doc["heights"], doc["controls"], doc["colors"])
	terrain = dict(TERRAIN_BLOCK)
	terrain["rules"] = rules
	manifest = {
		"format": FORMAT,
		"schema_version": SCHEMA_VERSION,
		"world_id": doc["world_id"],
		"document_revision": doc["document_revision"],
		"created_with": doc["created_with"],
		"catalog": doc["catalog"],
		"terrain": terrain,
		"payload_files": [{"path": p, "bytes": len(payload[p]), "sha256": sha256_hex(payload[p])} for p in PAYLOAD_PATHS],
		"authored_content_hash": authored_hash(doc["catalog"], rules, digests, scatter_bytes, paths_bytes,
			records),  # type: ignore[arg-type]
	}
	(gen_dir / "manifest.json").write_bytes(dump_json(manifest))
	return manifest


def validate_path(path: Path, app_dir: Path = APP_DIR) -> dict[str, Any]:
	"""Validates a .worldpoc file or a generation directory. Never raises for bad content."""
	path = Path(path)
	result: dict[str, Any] = {"path": str(path), "kind": "", "valid": False, "errors": [], "warnings": [],
		"authored_content_hash": "", "object_count": 0}
	tmp: Path | None = None
	try:
		if path.is_dir():
			result["kind"] = "generation"
			gen_dir = path
		else:
			result["kind"] = "package"
			tmp, errors = safe_extract(path)
			if tmp is None:
				hint = schema_error(path)
				result["errors"] = ([hint] if hint else []) + errors
				return result
			gen_dir = tmp
		gen, errors = validate_generation(gen_dir, app_dir)
		result["errors"] = errors
		if gen is not None:
			result["object_count"] = len(gen.records)
			result["authored_content_hash"] = gen.authored_hash
			if not errors:
				result["warnings"] = grounding_report(gen)
		result["valid"] = not result["errors"]
		return result
	finally:
		if tmp is not None:
			shutil.rmtree(tmp, ignore_errors=True)
