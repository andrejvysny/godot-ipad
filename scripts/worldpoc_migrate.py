"""Schema 2/3 -> 4 migration (ADR 0014 D9): each catalog asset in use becomes a bundled binding with the default
policy of the trusted catalog entry; terrain, rules, paths, object IDs and transform bits and scatter records are
carried over unchanged. Python stdlib only."""
from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path
from typing import Any

from worldpoc_constants import APP_DIR, SCHEMA_VERSION_LOCK, layout_regions
from worldpoc_format import validate_generation, Generation
from worldpoc_locks import bundled_binding
from worldpoc_values import load_trusted_catalog, parse_json_bytes
from worldpoc_write import write_generation_v4


class MigrationError(ValueError):
	pass


def _build_doc(gen: Generation, gen_dir: Path, trusted: dict[str, Any]) -> dict[str, Any]:
	assets = sorted({r["asset_id"] for r in gen.records} | {a for a, _ in gen.scatter["assets"]})
	bindings = {a: bundled_binding(trusted, a) for a in assets}
	objects = []
	for d in parse_json_bytes((gen_dir / "objects.json").read_bytes())["objects"]:
		rec = {k: v for k, v in d.items() if k not in ("asset_id", "asset_version")}
		rec["binding_id"] = bindings[d["asset_id"]]["binding_id"]
		objects.append(rec)
	scatter = [dict(i, binding_id=bindings[i["asset_id"]]["binding_id"]) for i in gen.scatter["instances"]]
	return {
		"world_id": gen.manifest["world_id"], "document_revision": gen.manifest["document_revision"],
		"created_with": gen.manifest["created_with"], "layout": gen.layout, "rules": gen.rules,
		"heights": gen.heights, "controls": gen.controls, "colors": gen.colors,
		"bindings": list(bindings.values()), "objects": objects, "scatter": scatter, "paths": gen.paths,
	}


def migrate(src_gen_dir: Path, dest_dir: Path, app_dir: Path = APP_DIR) -> dict[str, Any]:
	"""Writes the schema 4 generation of a valid schema 2/3 generation directory to the new `dest_dir`
	(created atomically; FileExistsError when it exists). Returns the new manifest. Raises MigrationError
	when the source is invalid, not schema 2/3, or the result does not validate."""
	src_gen_dir, dest_dir = Path(src_gen_dir), Path(dest_dir)
	if dest_dir.exists():
		raise FileExistsError("destination '%s' already exists" % dest_dir)
	gen, errors = validate_generation(src_gen_dir, app_dir)
	if errors or gen is None:
		raise MigrationError("source is not a valid generation: %s" % "; ".join(errors[:5]))
	if gen.schema >= SCHEMA_VERSION_LOCK:
		raise MigrationError("source is already schema %d" % gen.schema)
	doc = _build_doc(gen, src_gen_dir, load_trusted_catalog(app_dir))
	dest_dir.parent.mkdir(parents=True, exist_ok=True)
	tmp = Path(tempfile.mkdtemp(prefix=".migrate_", dir=dest_dir.parent))
	try:
		manifest = write_generation_v4(tmp, doc)
		_, out_errors = validate_generation(tmp, app_dir)
		if out_errors:
			raise MigrationError("migrated generation does not validate: %s" % "; ".join(out_errors[:5]))
		os.chmod(tmp, 0o755)
		os.rename(tmp, dest_dir)
	except BaseException:
		shutil.rmtree(tmp, ignore_errors=True)
		raise
	return manifest
