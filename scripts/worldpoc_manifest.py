"""Manifest header, terrain block, rules and payload-file checks of a generation directory
(docs/world-format.md §2, §3, §9). Validators return lists of error strings; they never raise."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from worldpoc_constants import (
	FORMAT,
	SCHEMA_VERSION,
	RULE_SPECS,
	TERRAIN_BLOCK,
	PAYLOAD_PATHS,
	SHA256_RE,
	UUID_RE,
)
from worldpoc_values import is_finite_number, is_json_int, sha256_file, show


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
