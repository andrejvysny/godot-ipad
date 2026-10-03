"""Generation writers (docs/world-format.md §2, §12): schema 2/3 `write_generation` and the schema 4
`write_generation_v4` / `seal_generation_v4`. Python stdlib only."""
from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from worldpoc_constants import (
	DEFAULT_RULES,
	FORMAT,
	LEGACY_LAYOUT,
	LOCK_PATH,
	PATHS_PATH,
	SCATTER_PATH,
	SCHEMA_VERSION_LOCK,
	Layout,
	color_path,
	control_path,
	height_path,
	layout_from_manifest,
	layout_regions,
	layout_schema,
	payload_paths,
	terrain_block,
	validate_layout,
)
from worldpoc_locks import canonical_v1
from worldpoc_scatter import write_paths, write_scatter
from worldpoc_v4 import authored_hash_v4, write_scatter_v2
from worldpoc_values import authored_hash, dump_json, parse_json_bytes, parse_object_record, sha256_hex


def _region_digests(heights: dict[tuple[int, int], bytes], controls: dict[tuple[int, int], bytes],
		colors: dict[tuple[int, int], bytes]) -> dict[tuple[int, int], tuple[bytes, bytes, bytes]]:
	return {loc: (hashlib.sha256(heights[loc]).digest(), hashlib.sha256(controls[loc]).digest(),
		hashlib.sha256(colors[loc]).digest()) for loc in heights}


def write_generation(gen_dir: Path, doc: dict[str, Any]) -> dict[str, Any]:
	"""Writes a generation; manifest last. `doc` keys: world_id, document_revision, created_with,
	catalog {id, version, sha256}, heights/controls/colors {loc: bytes}, objects [record dicts];
	optional rules (default DEFAULT_RULES), scatter (instance dicts), paths (path dicts) and layout
	(default legacy; any other valid layout writes schema 3)."""
	gen_dir = Path(gen_dir)
	layout: Layout = doc.get("layout", LEGACY_LAYOUT)
	layout_error = validate_layout(*layout)
	if layout_error:
		raise ValueError("invalid layout: " + layout_error)
	schema = layout_schema(layout)
	(gen_dir / "regions").mkdir(parents=True, exist_ok=True)
	objects = sorted(doc.get("objects", []), key=lambda r: r["object_id"].encode("utf-8"))
	rules = dict(doc.get("rules", DEFAULT_RULES))
	scatter_bytes = write_scatter(doc.get("scatter", []))
	paths_bytes = write_paths(doc.get("paths", []))
	payload: dict[str, bytes] = {"objects.json": dump_json({"schema_version": schema, "objects": objects}),
		SCATTER_PATH: scatter_bytes, PATHS_PATH: paths_bytes}
	for loc in layout_regions(*layout):
		payload[height_path(loc)] = doc["heights"][loc]
		payload[control_path(loc)] = doc["controls"][loc]
		payload[color_path(loc)] = doc["colors"][loc]
	for rel, data in payload.items():
		(gen_dir / rel).write_bytes(data)
	records = [parse_object_record(o)[0] for o in objects]
	digests = _region_digests(doc["heights"], doc["controls"], doc["colors"])
	terrain = terrain_block(layout)
	terrain["rules"] = rules
	manifest = {
		"format": FORMAT,
		"schema_version": schema,
		"world_id": doc["world_id"],
		"document_revision": doc["document_revision"],
		"created_with": doc["created_with"],
		"catalog": doc["catalog"],
		"terrain": terrain,
		"payload_files": [{"path": p, "bytes": len(payload[p]), "sha256": sha256_hex(payload[p])} for p in payload_paths(layout)],
		"authored_content_hash": authored_hash(doc["catalog"], rules, digests, scatter_bytes, paths_bytes,
			records, layout),  # type: ignore[arg-type]
	}
	(gen_dir / "manifest.json").write_bytes(dump_json(manifest))
	return manifest


# --- schema 4 ---------------------------------------------------------------------------------
def derive_dependencies(bindings: list[dict[str, Any]]) -> dict[str, Any]:
	"""Closure entries of the AssetStudio bindings (no `requires`), deliveries merged per asset_key."""
	deps: dict[str, Any] = {}
	for b in bindings:
		if b["provider"] != "assetstudio":
			continue
		e = deps.setdefault(b["asset_key"], {"asset_ref": b["asset_ref"], "descriptor_sha256": b["descriptor_sha256"],
			"deliveries": {}, "requires": []})
		for name, pin in b["deliveries"].items():
			if e["deliveries"].setdefault(name, pin) != pin:
				raise ValueError("binding %s pins a different %s than another binding of the same asset" % (b["binding_id"], name))
	return deps


def lock_bytes_of(bindings: list[dict[str, Any]], dependencies: dict[str, Any] | None = None) -> bytes:
	ordered = sorted(bindings, key=lambda b: b["binding_id"].encode("utf-8"))
	deps = derive_dependencies(ordered) if dependencies is None else dependencies
	return canonical_v1({"schema_version": 1, "bindings": ordered, "dependencies": deps})


def write_generation_v4(gen_dir: Path, doc: dict[str, Any]) -> dict[str, Any]:
	"""Writes a schema 4 generation (any valid layout, legacy included); manifest last. `doc` keys: world_id,
	document_revision, created_with, heights/controls/colors {loc: bytes}, bindings (binding dicts with ids),
	objects (v4 record dicts), optional layout (default legacy), rules, scatter (instances with binding_id),
	paths, dependencies (default: derived), lock_bytes (raw override, for hostile fixtures). Only bindings
	referenced by an object or scatter instance are written (ADR 0014 D2)."""
	gen_dir = Path(gen_dir)
	layout: Layout = doc.get("layout", LEGACY_LAYOUT)
	layout_error = validate_layout(*layout)
	if layout_error:
		raise ValueError("invalid layout: " + layout_error)
	(gen_dir / "regions").mkdir(parents=True, exist_ok=True)
	objects = sorted(doc.get("objects", []), key=lambda r: r["object_id"].encode("utf-8"))
	scatter = doc.get("scatter", [])
	used = {o["binding_id"] for o in objects} | {i["binding_id"] for i in scatter}
	bindings = [b for b in doc.get("bindings", []) if b["binding_id"] in used]
	payload: dict[str, bytes] = {
		LOCK_PATH: doc.get("lock_bytes") or lock_bytes_of(bindings, doc.get("dependencies")),
		"objects.json": dump_json({"schema_version": SCHEMA_VERSION_LOCK, "objects": objects}),
		SCATTER_PATH: write_scatter_v2(scatter), PATHS_PATH: write_paths(doc.get("paths", []))}
	for loc in layout_regions(*layout):
		payload[height_path(loc)] = doc["heights"][loc]
		payload[control_path(loc)] = doc["controls"][loc]
		payload[color_path(loc)] = doc["colors"][loc]
	for rel, data in payload.items():
		(gen_dir / rel).write_bytes(data)
	meta = {"world_id": doc["world_id"], "document_revision": doc["document_revision"],
		"created_with": doc["created_with"], "layout": layout, "rules": dict(doc.get("rules", DEFAULT_RULES))}
	return seal_generation_v4(gen_dir, meta)


def _meta_of_manifest(gen_dir: Path) -> dict[str, Any]:
	m = parse_json_bytes((gen_dir / "manifest.json").read_bytes())
	layout, err = layout_from_manifest(m["terrain"].get("layout"))
	if layout is None:
		raise ValueError(err)
	return {"world_id": m["world_id"], "document_revision": m["document_revision"], "created_with": m["created_with"],
		"layout": layout, "rules": m["terrain"]["rules"]}


def seal_generation_v4(gen_dir: Path, meta: dict[str, Any] | None = None) -> dict[str, Any]:
	"""Recomputes payload sizes/hashes, the asset_lock hash and the authored hash from the files in `gen_dir`
	and rewrites manifest.json. Works on semantically invalid content (hostile fixtures): an authored hash is
	only computed when every object record parses, else it is the all-zero placeholder."""
	gen_dir = Path(gen_dir)
	meta = meta or _meta_of_manifest(gen_dir)
	layout: Layout = meta["layout"]
	paths = payload_paths(layout, SCHEMA_VERSION_LOCK)
	payload = {p: (gen_dir / p).read_bytes() for p in paths}
	terrain = terrain_block(layout, True)
	terrain["rules"] = dict(meta["rules"])
	manifest = {
		"format": FORMAT,
		"schema_version": SCHEMA_VERSION_LOCK,
		"world_id": meta["world_id"],
		"document_revision": meta["document_revision"],
		"created_with": meta["created_with"],
		"asset_lock": {"path": LOCK_PATH, "sha256": sha256_hex(payload[LOCK_PATH])},
		"terrain": terrain,
		"payload_files": [{"path": p, "bytes": len(payload[p]), "sha256": sha256_hex(payload[p])} for p in paths],
		"authored_content_hash": "0" * 64,
	}
	try:
		objs = parse_json_bytes(payload["objects.json"])["objects"]
		records = [parse_object_record(o, True)[0] for o in objs]
		if all(r is not None for r in records):
			digests = _region_digests({l: payload[height_path(l)] for l in layout_regions(*layout)},
				{l: payload[control_path(l)] for l in layout_regions(*layout)},
				{l: payload[color_path(l)] for l in layout_regions(*layout)})
			manifest["authored_content_hash"] = authored_hash_v4(payload[LOCK_PATH], meta["rules"], digests,
				payload[SCATTER_PATH], payload[PATHS_PATH], records, layout)  # type: ignore[arg-type]
	except (ValueError, KeyError, TypeError):
		pass
	(gen_dir / "manifest.json").write_bytes(dump_json(manifest))
	return manifest
