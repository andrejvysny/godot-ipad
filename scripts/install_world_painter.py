#!/usr/bin/env python3
"""Install World Painter source archives into a Godot project and pin them in integration.lock.json (IP-09).

Usage: python3 scripts/install_world_painter.py --project DIR ARCHIVE.zip [ARCHIVE.zip ...]
       python3 scripts/install_world_painter.py --project DIR --check ARCHIVE.zip [ARCHIVE.zip ...]
Each archive needs its `.sha256` sidecar and `.manifest.json` beside it (as built by package_world_painter.py or
the AssetStudio package_addon.py). Install verifies the sidecar, the manifest and every entry (no absolute paths,
`..`, backslashes or links; only addons/<name>/** or assets/**; file set and hashes equal the manifest), replaces
the package's own paths in the project and sets only that package's entry in DIR/integration.lock.json.
--check verifies the installed files against the manifests (missing, changed or extra files; Godot's .uid/.import files are ignored) and the lock entry.
Exit: 0 ok, 1 verification failed, 2 usage or I/O error. Re-import the project afterwards (godot --headless --import).
"""
from __future__ import annotations

import argparse
import json
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wp_archive as wa  # noqa: E402

LOCK_NAME = "integration.lock.json"
# Written by Godot's import next to sources (an archive may ship without them); not an extra file.
GENERATED_SUFFIXES = (".uid", ".import")


class InstallError(Exception):
	pass


def load_archive(zip_path: Path) -> tuple[dict[str, Any], dict[str, bytes]]:
	"""Verified manifest and entry bytes of one archive; raises InstallError on any mismatch."""
	try:
		manifest = json.loads(wa.manifest_path(zip_path).read_text())
		sidecar = wa.read_sidecar(zip_path)
		key = wa.package_key(manifest)
	except (OSError, ValueError, KeyError) as e:
		raise InstallError(f"{zip_path.name}: cannot read sidecar or manifest: {e}") from e
	if wa.sha256_file(zip_path) != sidecar or manifest.get("archive", {}).get("sha256") != sidecar:
		raise InstallError(f"{zip_path.name}: sha256 differs from the sidecar or manifest")
	data: dict[str, bytes] = {}
	with zipfile.ZipFile(zip_path) as zf:
		for info in zf.infolist():
			name = info.filename
			_check_entry(zip_path.name, info, key)
			if name in data:
				raise InstallError(f"{zip_path.name}: duplicate entry '{name}'")
			data[name] = zf.read(info)
	files = manifest["files"]
	if set(data) != set(files):
		raise InstallError(f"{zip_path.name}: entries differ from the manifest file list")
	for name, digest in files.items():
		if wa.sha256_bytes(data[name]) != digest:
			raise InstallError(f"{zip_path.name}: '{name}' differs from the manifest sha256")
	return manifest, data


def _check_entry(archive: str, info: zipfile.ZipInfo, key: str) -> None:
	name = info.filename
	parts = PurePosixPath(name).parts
	if (not name or name.startswith("/") or "\\" in name or ".." in parts or "." in parts or name.endswith("/")
			or any(ord(c) < 32 for c in name)):
		raise InstallError(f"{archive}: unsafe entry name {name!r}")
	mode = info.external_attr >> 16
	if stat.S_IFMT(mode) not in (0, stat.S_IFREG):
		raise InstallError(f"{archive}: entry '{name}' is not a regular file")
	if parts[0] == "assets" and len(parts) > 1 and key == "world_painter_catalog":
		return
	if len(parts) > 2 and parts[0] == "addons" and parts[1] == key:
		return
	raise InstallError(f"{archive}: entry '{name}' is outside this package's paths")


def owned_roots(files: dict[str, Any]) -> list[str]:
	"""Paths the package owns: addons/<name> as a tree; for assets/ each top-level file or directory."""
	roots = set()
	for name in files:
		parts = name.split("/")
		roots.add("/".join(parts[:2]))
	return sorted(roots)


def _resolve(project: Path, rel: str) -> Path:
	target = (project / rel).resolve()
	if project.resolve() not in target.parents:
		raise InstallError(f"path '{rel}' escapes the project")
	return target


def install(project: Path, zip_path: Path) -> tuple[str, dict[str, Any]]:
	manifest, data = load_archive(zip_path)
	with tempfile.TemporaryDirectory(prefix=".wp_install_", dir=project) as tmp:
		stage = Path(tmp)
		for name, blob in data.items():
			dest = stage / name
			dest.parent.mkdir(parents=True, exist_ok=True)
			dest.write_bytes(blob)
		for root in owned_roots(manifest["files"]):
			target = _resolve(project, root)
			if target.is_dir():
				shutil.rmtree(target)
			elif target.exists():
				target.unlink()
			target.parent.mkdir(parents=True, exist_ok=True)
			shutil.move(str(stage / root), str(target))
	return wa.package_key(manifest), wa.lock_entry(manifest)


def read_lock(project: Path) -> dict[str, Any]:
	path = project / LOCK_NAME
	if not path.exists():
		return {"schema_version": 1, "addons": {}}
	lock = json.loads(path.read_text())
	if not isinstance(lock, dict) or lock.get("schema_version") != 1 or not isinstance(lock.get("addons"), dict):
		raise InstallError(f"{LOCK_NAME} is not a schema_version 1 lock")
	return lock


def write_lock(project: Path, lock: dict[str, Any]) -> None:
	(project / LOCK_NAME).write_text(json.dumps(lock, separators=(",", ":"), ensure_ascii=False) + "\n")


def check(project: Path, zip_path: Path, lock: dict[str, Any]) -> list[str]:
	manifest, _ = load_archive(zip_path)
	problems: list[str] = []
	files: dict[str, str] = manifest["files"]
	for name, digest in files.items():
		f = project / name
		if not f.is_file():
			problems.append(f"missing {name}")
		elif wa.sha256_file(f) != digest:
			problems.append(f"changed {name}")
	for root in owned_roots(files):
		base = project / root
		found = [base] if base.is_file() else sorted(p for p in base.rglob("*") if p.is_file()) if base.is_dir() else []
		problems += [f"extra {p.relative_to(project).as_posix()}" for p in found
			if p.relative_to(project).as_posix() not in files and not p.name.endswith(GENERATED_SUFFIXES)]
	key = wa.package_key(manifest)
	if lock["addons"].get(key) != wa.lock_entry(manifest):
		problems.append(f"{LOCK_NAME} entry '{key}' does not match the archive")
	return problems


def main(argv: list[str] | None = None) -> int:
	ap = argparse.ArgumentParser(description="Install World Painter archives into a Godot project.")
	ap.add_argument("--project", type=Path, required=True, help="Godot project directory (contains project.godot)")
	ap.add_argument("--check", action="store_true", help="verify installed files and lock instead of installing")
	ap.add_argument("archives", nargs="+", type=Path)
	a = ap.parse_args(argv)
	try:
		if not (a.project / "project.godot").is_file():
			raise InstallError(f"{a.project} has no project.godot")
		lock = read_lock(a.project)
		if a.check:
			bad = {z.name: check(a.project, z, lock) for z in a.archives}
			for name, problems in bad.items():
				print(f"{name}: " + ("ok" if not problems else "FAILED"))
				for p in problems:
					print(f"  {p}")
			return 1 if any(bad.values()) else 0
		for z in a.archives:
			key, entry = install(a.project, z)
			lock["addons"][key] = entry
			print(f"installed {key} {entry['package_version']} ({entry['archive_sha256'][:12]})")
		write_lock(a.project, lock)
	except (InstallError, OSError, zipfile.BadZipFile, json.JSONDecodeError) as e:
		print(f"error: {e}", file=sys.stderr)
		return 2
	return 0


if __name__ == "__main__":
	sys.exit(main())
