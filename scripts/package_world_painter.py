#!/usr/bin/env python3
"""Build the World Painter source archives for consumer projects (IP-09, spec 00 §3 and §9.2).

Usage: python3 scripts/package_world_painter.py [--out-dir dist]
Writes, each with a `.sha256` sidecar (`<hex>  <name>`) and a `.manifest.json` (version, source commit + dirty flag,
contract versions, per-file sha256):
  world-painter-addon-<version>.zip          addons/world_painter/** + addons/world_painter/contracts/** (no tests/caches)
  world-painter-catalog-<id>-<ver>.zip       assets/catalog.json, assets/models/**, assets/render_assets/**
and world-painter-pins.json: the integration.lock.json entries (`world_painter`, `world_painter_catalog`) for both.
The catalog archive holds exactly what the catalog content hash (world-format §8: catalog.json + preview/scatter
models) and the render-asset registry (render_assets/index.json) read. Thumbnails are editor UI only (the catalog
checks their path prefix, never their bytes) and are NOT packaged; a consumer needs only a catalog and models.
Version source of truth: addons/world_painter/plugin.cfg `version`. Deterministic: sorted entries, fixed
timestamps and modes; two builds of the same tree give byte-identical archives.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wp_archive as wa  # noqa: E402
import worldpoc_values as wv  # noqa: E402

ROOT = wa.REPO
ADDON = ROOT / "app" / "addons" / "world_painter"
ASSETS = ROOT / "app" / "assets"
CONTRACTS = ROOT / "contracts" / "world-painter"
ADDON_PREFIX = "addons/world_painter"
CONTRACT_VERSIONS = {"world": "world-v4", "live": "live-v1"}
REQUIRES = {"assetstudio": {"contract_version": 1}, "terrain_3d": "1.0.2-stable", "godot": "4.7"}
CATALOG_DIRS = ("models", "render_assets")
SKIP_NAMES = {".DS_Store", ".env"}
SKIP_SUFFIXES = (".tmp", ".pyc", ".token", ".secret", ".key", ".pem", ".partial")
SKIP_DIRS = {".godot", ".claude", ".git", "__pycache__", "tests", "test", ".pytest_cache", "secrets", "build"}


def read_version() -> str:
	m = re.search(r'^version="([0-9A-Za-z._+-]+)"$', (ADDON / "plugin.cfg").read_text(), re.M)
	if not m:
		raise SystemExit(f"cannot read version from {ADDON / 'plugin.cfg'}")
	return m.group(1)


def _skipped(p: Path, base: Path) -> bool:
	rel = p.relative_to(base)
	return any(part in SKIP_DIRS for part in rel.parts[:-1]) or p.name in SKIP_NAMES or p.name.endswith(SKIP_SUFFIXES)


def _tree(base: Path, prefix: str) -> dict[str, Path]:
	return {f"{prefix}/{p.relative_to(base).as_posix()}": p
		for p in sorted(base.rglob("*")) if p.is_file() and not _skipped(p, base)}


def collect_addon() -> dict[str, Path]:
	entries = _tree(ADDON, ADDON_PREFIX)
	entries.update(_tree(CONTRACTS, f"{ADDON_PREFIX}/contracts/world-painter"))
	return entries


def collect_catalog() -> dict[str, Path]:
	entries = {"assets/catalog.json": ASSETS / "catalog.json"}
	for d in CATALOG_DIRS:
		entries.update(_tree(ASSETS / d, f"assets/{d}"))
	return entries


def _manifest(package: str, version: str, files: dict[str, str], zip_name: str, digest: str,
		inputs: list[Path], extra: dict[str, Any]) -> dict[str, Any]:
	m: dict[str, Any] = {"schema_version": 1, "package": package, "version": version,
		"source_repository": wa.SOURCE_REPOSITORY, "source": wa.source_state(inputs + [Path(__file__).resolve()]),
		"contract_versions": CONTRACT_VERSIONS, "archive": {"name": zip_name, "sha256": digest}, "files": files}
	m.update(extra)
	return m


def build_addon(out_dir: Path) -> tuple[Path, dict[str, Any]]:
	version = read_version()
	zip_path = out_dir / f"world-painter-addon-{version}.zip"
	hashes, digest = wa.write_zip(zip_path, collect_addon())
	m = _manifest("world_painter", version, hashes, zip_path.name, digest, [ADDON, CONTRACTS], {"requires": REQUIRES})
	wa.write_json(wa.manifest_path(zip_path), m)
	return zip_path, m


def build_catalog(out_dir: Path) -> tuple[Path, dict[str, Any]]:
	cat = json.loads((ASSETS / "catalog.json").read_text())
	cid, cver = cat["catalog_id"], int(cat["catalog_version"])
	zip_path = out_dir / f"world-painter-catalog-{cid}-{cver}.zip"
	hashes, digest = wa.write_zip(zip_path, collect_catalog())
	extra = {"catalog": {"id": cid, "version": cver, "sha256": wv.catalog_sha256(ROOT / "app")},
		"requires": {"world_painter": {"contract_versions": CONTRACT_VERSIONS}}}
	m = _manifest("world_painter_catalog", str(cver), hashes, zip_path.name, digest, [ASSETS], extra)
	wa.write_json(wa.manifest_path(zip_path), m)
	return zip_path, m


def main() -> int:
	ap = argparse.ArgumentParser(description="Build the World Painter addon and catalog archives.")
	ap.add_argument("--out-dir", type=Path, default=ROOT / "dist")
	args = ap.parse_args()
	pins: dict[str, Any] = {}
	for build in (build_addon, build_catalog):
		path, m = build(args.out_dir)
		pins[m["package"]] = wa.lock_entry(m)
		print(f"{m['archive']['sha256']}  {path}")
	wa.write_json(args.out_dir / "world-painter-pins.json", {"schema_version": 1, "addons": pins})
	return 0


if __name__ == "__main__":
	sys.exit(main())
