"""Shared helpers for the World Painter source archives (IP-09): deterministic zip, sha256 sidecar, pin entries.

Stdlib only. Used by package_world_painter.py, install_world_painter.py and make_minimal_consumer.py.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import zipfile
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
SOURCE_REPOSITORY = "andrejvysny/godot-ipad"
KNOWN_REPOSITORIES = {"assetstudio": "andrejvysny/asset-studio"}
LOCK_ENTRY_KEYS = ("source_repository", "source_commit", "source_dirty", "package_version", "contract_version",
	"archive", "archive_sha256")


def sha256_bytes(data: bytes) -> str:
	return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
	return sha256_bytes(path.read_bytes())


def git(*args: str) -> str | None:
	try:
		r = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, check=True)
	except (OSError, subprocess.CalledProcessError):
		return None
	return r.stdout


def source_state(paths: list[Path]) -> dict[str, Any]:
	"""HEAD commit and whether the packaged inputs differ from it (None when git is unavailable)."""
	head = git("rev-parse", "HEAD")
	status = git("status", "--porcelain", "--", *[str(p) for p in paths])
	return {"commit": head.strip() if head else None, "dirty": None if status is None else bool(status.strip())}


def write_zip(zip_path: Path, entries: dict[str, Path]) -> tuple[dict[str, str], str]:
	"""Deterministic zip (sorted names, fixed timestamp and mode). Returns ({name: sha256}, archive sha256)."""
	zip_path.parent.mkdir(parents=True, exist_ok=True)
	hashes: dict[str, str] = {}
	with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
		for name in sorted(entries):
			data = entries[name].read_bytes()
			hashes[name] = sha256_bytes(data)
			info = zipfile.ZipInfo(name, FIXED_TIME)
			info.compress_type = zipfile.ZIP_DEFLATED
			info.external_attr = 0o644 << 16
			info.create_system = 3
			zf.writestr(info, data)
	digest = sha256_file(zip_path)
	zip_path.with_name(zip_path.name + ".sha256").write_text(f"{digest}  {zip_path.name}\n")
	return hashes, digest


def write_json(path: Path, data: Any) -> None:
	path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def manifest_path(zip_path: Path) -> Path:
	return zip_path.with_name(zip_path.name.removesuffix(".zip") + ".manifest.json")


def read_sidecar(zip_path: Path) -> str:
	text = zip_path.with_name(zip_path.name + ".sha256").read_text().split()
	if len(text) != 2 or text[1] != zip_path.name or len(text[0]) != 64:
		raise ValueError(f"malformed sha256 sidecar for {zip_path.name}")
	return text[0]


def package_key(manifest: dict[str, Any]) -> str:
	"""Lock entry name: `package` (world_painter, world_painter_catalog) or the AssetStudio `addon` name."""
	key = manifest.get("package") or manifest.get("addon")
	if not isinstance(key, str) or not key:
		raise ValueError("manifest names neither 'package' nor 'addon'")
	return key


def lock_entry(manifest: dict[str, Any]) -> dict[str, Any]:
	"""integration.lock.json entry (field names of the assetstudio entry) for one archive manifest."""
	key = package_key(manifest)
	repo = manifest.get("source_repository") or KNOWN_REPOSITORIES.get(key)
	if not repo:
		raise ValueError(f"no source repository known for '{key}'")
	src = manifest["source"]
	contract = manifest.get("contract_version", manifest.get("contract_versions"))
	if isinstance(contract, dict):
		contract = "/".join(str(contract[k]) for k in ("world", "live") if k in contract)
	return {"source_repository": repo, "source_commit": src["commit"], "source_dirty": src["dirty"],
		"package_version": manifest["version"], "contract_version": contract,
		"archive": manifest["archive"]["name"], "archive_sha256": manifest["archive"]["sha256"]}
