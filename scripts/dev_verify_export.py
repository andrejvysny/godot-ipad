"""`dev.py verify-export`: checks that an exported PCK ships every file the renderer needs (spec §17).

The required list is derived from the committed registries and catalogs (no export needed to compute it);
app/devtools/verify_export.gd mounts the PCK in a fresh headless process whose project is an empty temporary
one, so only pack contents (never the working tree) can satisfy a check.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import godot_test

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "app"
DEFAULT_PCK = REPO / "build" / "ios" / "WorldPainter.pck"
VERIFY_SCRIPT = APP / "devtools" / "verify_export.gd"
VERIFY_TIMEOUT_S = 180
GODOT = godot_test.GODOT
REGISTRIES = (
	(APP / "assets" / "render_assets" / "index.json", "editor"),
	(APP / "assets" / "bench" / "render_assets" / "index.json", "bench"),
)
CATALOGS = (APP / "assets" / "catalog.json", APP / "assets" / "bench" / "catalog.json")
FIXED_FILES = (
	"res://addons/world_painter/terrain/world_terrain.gdshader",
	"res://config/rendering_profiles.json",
	"res://config/poc_defaults.json",
)
# Directories excluded by the iOS preset's exclude_filter; any entry under them is unexpected.
FORBIDDEN_DIRS = ("res://devtools", "res://tests")
IMPORTED_SUFFIXES = (".png", ".svg", ".jpg", ".jpeg", ".webp")
IMPORT_PATH_RE = re.compile(r'^path(?:\.[a-z0-9_]+)?="(res://[^"]+)"$', re.M)


def res_path(path: Path) -> str:
	return "res://" + path.relative_to(APP).as_posix()


def imported_candidates(path: Path) -> list[str]:
	"""res:// paths of the imported (.ctex etc.) files named by `<path>.import`; [] when there is no import file."""
	import_file = path.with_name(path.name + ".import")
	if not import_file.is_file():
		return []
	return sorted(set(IMPORT_PATH_RE.findall(import_file.read_text())))


def entry(label: str, path: Path | str) -> dict:
	"""Source files are checked as they are; imported textures through their import outputs."""
	if isinstance(path, str):
		return {"label": label, "any_of": [path]}
	if path.suffix.lower() in IMPORTED_SUFFIXES:
		candidates = imported_candidates(path)
		if not candidates:
			raise ValueError("%s has no .import outputs (run the import)" % path.relative_to(REPO))
		return {"label": label + " (imported)", "any_of": candidates}
	return {"label": label, "any_of": [res_path(path)]}


def _registry_entries(index: Path, name: str) -> list[dict]:
	out = [entry("%s registry index" % name, index)]
	data = json.loads(index.read_text())
	for asset in data.get("assets", []):
		descriptor = index.parent / asset["descriptor"]
		out.append(entry("%s descriptor %s" % (name, asset["asset_id"]), descriptor))
		for dep in json.loads(descriptor.read_text()).get("dependencies", []):
			out.append(entry("%s %s %s" % (name, asset["asset_id"], dep["key"]), descriptor.parent / dep["path"]))
	return out


def _catalog_entries(catalog: Path) -> list[dict]:
	out = [entry("catalog %s" % catalog.relative_to(APP).as_posix(), catalog)]
	for asset in json.loads(catalog.read_text()).get("assets", []):
		for key in ("preview_scene", "scatter_mesh", "thumbnail"):
			value = asset.get(key)
			if value:
				out.append(entry("%s %s" % (asset["asset_id"], key), APP / value.removeprefix("res://")))
	return out


def required_entries() -> list[dict]:
	"""[{"label", "any_of": [res:// paths]}] in a stable order; each entry passes when any alternative is in the pack."""
	out = [entry(Path(p).name, p) for p in FIXED_FILES]
	for index, name in REGISTRIES:
		out.extend(_registry_entries(index, name))
	for catalog in CATALOGS:
		out.extend(_catalog_entries(catalog))
	for texture in sorted((APP / "assets" / "terrain" / "preview").glob("*.png")):
		out.append(entry("terrain preview %s" % texture.name, texture))
	seen: set[tuple[str, ...]] = set()
	unique = []
	for e in out:
		key = tuple(e["any_of"])
		if key not in seen:
			seen.add(key)
			unique.append(e)
	return unique


def cmd_verify_export(a) -> int:
	pck = Path(a.pck) if a.pck else DEFAULT_PCK
	if not pck.is_file():
		print("error: %s does not exist (run `dev.py export-ios --project-only` first)" % pck, file=sys.stderr)
		return 2
	try:
		entries = required_entries()
	except (OSError, ValueError, KeyError) as e:
		print("error: cannot derive the required file list: %s" % e, file=sys.stderr)
		return 2
	with tempfile.TemporaryDirectory(prefix="wp-verify-export-") as tmp:
		project = Path(tmp) / "project"
		project.mkdir()
		(project / "project.godot").write_text("config_version=5\n\n[application]\nconfig/name=\"verify-export\"\n")
		required = Path(tmp) / "required.json"
		required.write_text(json.dumps({"required": entries, "forbidden_dirs": list(FORBIDDEN_DIRS)}))
		cmd = [GODOT, "--headless", "--path", str(project), "--script", str(VERIFY_SCRIPT), "--",
			str(pck.resolve()), str(required)]
		try:
			r = subprocess.run(cmd, capture_output=True, text=True, timeout=VERIFY_TIMEOUT_S, stdin=subprocess.DEVNULL)
		except subprocess.TimeoutExpired:
			print("error: verify-export timed out after %ds" % VERIFY_TIMEOUT_S, file=sys.stderr)
			return 124
	lines = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith("VERIFY_EXPORT")]
	print("\n".join(lines) if lines else (r.stdout + r.stderr))
	return r.returncode
