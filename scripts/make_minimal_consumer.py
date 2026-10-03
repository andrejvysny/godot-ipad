#!/usr/bin/env python3
"""Build and exercise the minimal consumer from the published archives only (IP-09).

Usage: python3 scripts/make_minimal_consumer.py [--work-dir DIR] [--asset-studio-repo DIR]
Steps (all under one work dir): build the World Painter addon + catalog archives; build the AssetStudio archive with
that repo's scripts/package_addon.py (read-only use, output into the work dir); copy examples/minimal_consumer
and the pinned Terrain3D package (app/addons/terrain_3d); install the three archives with install_world_painter.py;
import headless; `--check` the installation; run `cli.gd validate` and the `validate` of an invalid fixture; load a
fixture world through WorldLoader from the example's main scene. Exit 0 when every step passes.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import godot_test  # noqa: E402
import install_world_painter as iwp  # noqa: E402
import package_world_painter as pwp  # noqa: E402

REPO = pwp.ROOT
EXAMPLE = REPO / "examples" / "minimal_consumer"
TERRAIN3D = REPO / "app" / "addons" / "terrain_3d"
FIXTURES = REPO / "contracts" / "world-painter" / "world-v4" / "fixtures"
DEFAULT_ASSET_STUDIO = Path(os.environ.get("ASSET_STUDIO_REPO", "/Users/andrejvysny/workspace/godot/asset-studio"))
CLI = "res://addons/world_painter/cli.gd"
REPORT_PREFIX = "MINIMAL_CONSUMER "
RUN_TIMEOUT_S = 300


class StepError(Exception):
	pass


def _run(args: list[str], cwd: Path | None = None) -> str:
	try:
		r = subprocess.run(args, capture_output=True, text=True, timeout=RUN_TIMEOUT_S, stdin=subprocess.DEVNULL, cwd=cwd)
	except subprocess.TimeoutExpired as e:
		raise StepError(f"timeout: {' '.join(args)}") from e
	if r.returncode != 0:
		raise StepError(f"{' '.join(args)} -> {r.returncode}\n{r.stdout[-1500:]}{r.stderr[-1500:]}")
	return r.stdout


def _godot(project: Path, extra: list[str], expect_rc: int = 0) -> str:
	args = [godot_test.GODOT, "--headless", "--path", str(project)] + extra
	r = subprocess.run(args, capture_output=True, text=True, timeout=RUN_TIMEOUT_S, stdin=subprocess.DEVNULL)
	if r.returncode != expect_rc:
		raise StepError(f"{' '.join(args)} -> {r.returncode} (expected {expect_rc})\n{r.stdout[-1500:]}{r.stderr[-1500:]}")
	return r.stdout


def _json_line(out: str, prefix: str = "") -> dict:
	lines = [x for x in out.splitlines() if x.startswith(prefix + "{" if not prefix else prefix)]
	if len(lines) != 1:
		raise StepError(f"expected one JSON line, got {len(lines)}:\n{out[-1500:]}")
	return json.loads(lines[0][len(prefix):])


def build_archives(work: Path, asset_studio: Path) -> list[Path]:
	dist = work / "dist"
	wp_addon, _ = pwp.build_addon(dist)
	wp_catalog, _ = pwp.build_catalog(dist)
	script = asset_studio / "scripts" / "package_addon.py"
	if not script.is_file():
		raise StepError(f"AssetStudio packager not found: {script}")
	as_dir = work / "dist_assetstudio"
	_run([sys.executable, str(script), "--out-dir", str(as_dir)])
	zips = sorted(as_dir.glob("assetstudio-addon-*.zip"))
	if len(zips) != 1:
		raise StepError(f"expected one AssetStudio archive in {as_dir}")
	return [zips[0], wp_addon, wp_catalog]


def prepare_project(work: Path, archives: list[Path]) -> Path:
	project = work / "project"
	shutil.copytree(EXAMPLE, project, ignore=shutil.ignore_patterns(".godot", "addons", "assets", "integration.lock.json"))
	shutil.copytree(TERRAIN3D, project / "addons" / "terrain_3d")
	for z in archives:
		iwp.install(project, z)
	lock = iwp.read_lock(project)
	for z in archives:
		manifest, _ = iwp.load_archive(z)
		lock["addons"][iwp.wa.package_key(manifest)] = iwp.wa.lock_entry(manifest)
	iwp.write_lock(project, lock)
	return project


def verify(project: Path, archives: list[Path]) -> dict[str, object]:
	"""Import, --check, CLI validate (valid + invalid fixture), world load from the main scene."""
	rc, out = godot_test.godot_import(project)
	if rc != 0 or godot_test.import_errors(out):
		raise StepError("import failed:\n" + "\n".join(godot_test.import_errors(out)) + out[-1000:])
	if iwp.main(["--project", str(project), "--check", *map(str, archives)]) != 0:
		raise StepError("install --check failed")
	bad_src = [p for p in project.rglob("*.gd") if "res://src" in p.read_text() and "addons/world_painter" not in p.as_posix()]
	if bad_src or (project / "src").exists():
		raise StepError(f"consumer references an app src tree: {bad_src}")
	index = {f["name"]: f for f in json.loads((FIXTURES / "INDEX.json").read_text())["fixtures"]}
	good = FIXTURES / index["one_bundled_object"]["path"]
	validated = _json_line(_godot(project, ["--script", CLI, "--", "validate", "--world", str(good)]))
	if not validated["ok"] or validated["authored_hash"] != index["one_bundled_object"]["authored_hash"]:
		raise StepError(f"validate disagrees with INDEX: {validated}")
	bad = FIXTURES / index["bad_lock_hash"]["path"]
	rejected = _json_line(_godot(project, ["--script", CLI, "--", "validate", "--world", str(bad)], expect_rc=1))
	if rejected["ok"] or index["bad_lock_hash"]["error_substring"] not in " ".join(rejected["errors"]):
		raise StepError(f"invalid fixture not rejected as expected: {rejected}")
	report = _json_line(_godot(project, ["--", f"--world={good}"]), REPORT_PREFIX)
	if not report["ok"] or report["authored_hash"] != validated["authored_hash"]:
		raise StepError(f"main scene load disagrees with validate: {report}")
	return {"validate": validated, "scene_report_hash": report["authored_hash"], "lock": iwp.read_lock(project)}


def run(work: Path, asset_studio: Path = DEFAULT_ASSET_STUDIO) -> dict[str, object]:
	archives = build_archives(work, asset_studio)
	project = prepare_project(work, archives)
	return verify(project, archives)


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--work-dir", type=Path, help="keep everything here (must be empty or absent)")
	ap.add_argument("--asset-studio-repo", type=Path, default=DEFAULT_ASSET_STUDIO)
	a = ap.parse_args()
	work = a.work_dir or Path(tempfile.mkdtemp(prefix="wp_minimal_consumer_"))
	work.mkdir(parents=True, exist_ok=True)
	try:
		result = run(work, a.asset_studio_repo)
	except (StepError, OSError) as e:
		print(f"FAILED: {e}", file=sys.stderr)
		return 1
	print(f"minimal consumer OK ({work}); authored_hash {result['scene_report_hash']}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
