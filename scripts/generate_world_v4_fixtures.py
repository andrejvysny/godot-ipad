#!/usr/bin/env python3
"""Golden schema 4 fixtures and vectors: contracts/world-painter/world-v4/fixtures/ (INDEX.json, .worldpoc
packages, canonical-lock-vectors.json). Deterministic; the committed bytes are the reference.

Usage: python3 scripts/generate_world_v4_fixtures.py [--check]   (--check regenerates in memory and compares)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import worldpoc_format as wf  # noqa: E402
import worldpoc_migrate as wm  # noqa: E402
import world_v4_builders as B  # noqa: E402
import world_v4_hostile as H  # noqa: E402
import world_v4_generation_vectors as GV  # noqa: E402
import world_v4_vectors as V  # noqa: E402
from worldpoc_locks import bundled_binding  # noqa: E402
from worldpoc_v4 import authored_hash_v4, write_scatter_v2  # noqa: E402
from worldpoc_write import lock_bytes_of  # noqa: E402

TRUSTED = wf.load_trusted_catalog()
BOULDER, CABIN, SPRUCE, GRASS = ("nature.rock.boulder_a", "built.lodge.cabin_a", "nature.tree.spruce_a",
	"nature.cover.grass_tuft_a")
def bb(asset_id: str) -> dict[str, Any]:
	return bundled_binding(TRUSTED, asset_id)


def km1_flat_empty_hash() -> str:
	h = hashlib.sha256(struct.pack("<f", 0.0) * wf.REGION_SAMPLE_COUNT).digest()
	c = hashlib.sha256(struct.pack("<I", wf.DEFAULT_CONTROL) * wf.REGION_SAMPLE_COUNT).digest()
	t = hashlib.sha256(wf.DEFAULT_COLOR * wf.REGION_SAMPLE_COUNT).digest()
	digests = {loc: (h, c, t) for loc in wf.layout_regions(*wf.KM1_LAYOUT)}
	return authored_hash_v4(lock_bytes_of([]), wf.DEFAULT_RULES, digests, write_scatter_v2([]), wf.write_paths([]), [],
		wf.KM1_LAYOUT)


def valid_docs() -> dict[str, dict[str, Any]]:
	text1, text2 = B.descriptor_text("primitive_prop.json"), B.descriptor_text("primitive_prop_v2.json")
	ref1, ref2 = B.ref(), B.ref(version_id="ver_00000000000000v2")
	rb1, rb2 = B.remote_binding(text1, ref1), B.remote_binding(text2, ref2, static=True)
	scat = B.remote_binding(text1, ref1, scatter=True)
	text3, ref3 = B.non_ascii_descriptor()
	r3 = B.remote_binding(text3, ref3)
	L = B.ONE_REGION
	return {
		"legacy_flat_empty": B.v4_doc(1, wf.LEGACY_LAYOUT, [], []),
		"one_bundled_object": B.v4_doc(2, L, [bb(BOULDER)], [B.obj(1, bb(BOULDER)["binding_id"], 10.5, 20.25, 1.3)]),
		"one_remote_object": B.v4_doc(3, L, [rb1], [B.obj(1, rb1["binding_id"], 33.0, 41.5, 1.25, 0.25)]),
		"two_versions": B.v4_doc(4, L, [rb1, rb2], [B.obj(1, rb1["binding_id"], 5.0, 5.0), B.obj(2, rb2["binding_id"], 6.0, 5.0, 1.5)]),
		"remote_scatter": B.v4_doc(5, L, [scat], [], [B.scatter_inst(scat["binding_id"], 12.5, 14.0, 0.5, 1.0, 1),
			B.scatter_inst(scat["binding_id"], 60.25, 70.75, -1.25, 1.5), B.scatter_inst(scat["binding_id"], 100.0, 3.5, 3.1, 0.75)]),
		"non_ascii_ids": B.v4_doc(6, L, [r3], [B.obj(1, r3["binding_id"], 64.0, 64.0)]),
		"holes": B.v4_doc(7, L, [], [], controls=B.holes_controls(L)),
	}


def migration_sources() -> dict[str, tuple[wf.Layout, int]]:
	return {"migrate_v2_source": (wf.LEGACY_LAYOUT, 8), "migrate_v3_source": (B.ONE_REGION, 9)}


def build_source(gen_dir: Path, layout: wf.Layout, n: int) -> None:
	"""Small schema 2 (legacy layout) or schema 3 generation with objects, scatter, a path and painted terrain."""
	arrays = B.flat_arrays(layout, step=True)
	locs = wf.layout_regions(*layout)
	words = [wf.DEFAULT_CONTROL] * wf.REGION_SAMPLE_COUNT
	for i in range(256):
		words[i] = wf.control_encode_paint(wf.DEFAULT_CONTROL, i)
	arrays["controls"][locs[0]] = struct.pack("<%dI" % len(words), *words)
	regions = wf.load_region_arrays(arrays["heights"])
	x0 = -100.0 if layout == wf.LEGACY_LAYOUT else 10.0
	objects = []
	for i, (asset, dx, dz, scale) in enumerate(((BOULDER, 0.0, 0.0, 1.3), (SPRUCE, 7.5, 3.25, 1.0), (CABIN, 20.0, 9.0, 1.0))):
		x, z = x0 + dx, x0 + dz
		y = wf.sample_height(regions, x, z, None, layout)
		objects.append(wf.make_object_record(B.object_id(i + 1), asset, 1, [x, y, z], B.QUAT, scale,
			"WORLD_FIXED" if asset == CABIN else "FOLLOW_TERRAIN", 0.0))
	scatter = [{"asset_id": a, "asset_version": 1, "flags": f, "x": x0 + dx, "z": x0 + dz, "yaw_rad": yaw, "scale": s}
		for a, f, dx, dz, yaw, s in ((SPRUCE, 1, 1.5, 30.0, 0.25, 1.0), (GRASS, 0, 3.5, 31.0, -2.0, 1.0),
			(BOULDER, 0, 9.0, 33.5, 3.0, 2.0), (SPRUCE, 0, 12.0, 35.0, 1.0, 0.5))]
	paths = [{"path_id": "11111111-1111-4111-8111-111111111111", "width_m": 2.5,
		"points": [(x0, x0 + 40.0), (x0 + 15.0, x0 + 44.0), (x0 + 30.0, x0 + 41.0)]}]
	doc = {"world_id": B.world_id(n), "document_revision": 0, "created_with": B.CREATED_WITH,
		"catalog": {"id": TRUSTED["id"], "version": TRUSTED["version"], "sha256": TRUSTED["sha256"]},
		"layout": layout, "objects": objects, "scatter": scatter, "paths": paths, **arrays}
	wf.write_generation(gen_dir, doc)


def migration_outputs() -> dict[str, tuple[bytes, str, dict[str, Any]]]:
	"""name -> (package bytes, authored hash, extra INDEX fields) for sources, migrations and procedurals."""
	out: dict[str, tuple[bytes, str, dict[str, Any]]] = {}
	for name, (layout, n) in migration_sources().items():
		with B.Workdir() as tmp:
			build_source(tmp / "src", layout, n)
			wf.write_package(tmp / "src", tmp / "s.worldpoc")
			src_hash = json.loads((tmp / "src" / "manifest.json").read_text())["authored_content_hash"]
			out[name] = ((tmp / "s.worldpoc").read_bytes(), src_hash, {"kind": "world"})
			manifest = wm.migrate(tmp / "src", tmp / "dst")
			wf.write_package(tmp / "dst", tmp / "d.worldpoc")
			dest = name.replace("_source", "")
			out[dest] = ((tmp / "d.worldpoc").read_bytes(), manifest["authored_content_hash"],
				{"kind": "migration", "source": name + ".worldpoc", "source_authored_hash": src_hash})
	return out


def procedural_entries() -> list[dict[str, Any]]:
	entries: list[dict[str, Any]] = [{
		"name": "km1_flat_empty", "path": None, "kind": "procedural", "expected": "valid", "sha256": None,
		"authored_hash": km1_flat_empty_hash(),
		"recipe": "layout km1 (min_region [-4,-4], region_count [8,8]); every height 0.0 (f32le); every control 0x00000001; "
			"every tint FF FF FF 00; default rules; asset_locks.json = canonical {bindings:[],dependencies:{},schema_version:1}; "
			"objects.json empty; scatter.bin v2 empty (16 bytes); paths.bin empty; hash per authored-hash-v4.md"}]
	for name, gen in (("migrate_v2_app_flat", "flat"), ("migrate_v2_app_gentle_hills", "gentle_hills")):
		with B.Workdir() as tmp:
			manifest = wm.migrate(wf.APP_DIR / "fixtures" / gen, tmp / "dst")
		entries.append({"name": name, "path": None, "kind": "migration_procedural", "expected": "valid", "sha256": None,
			"source": "app/fixtures/" + gen, "authored_hash": manifest["authored_content_hash"],
			"recipe": "python3 scripts/validate_world.py migrate app/fixtures/%s DEST" % gen})
	return entries


def generate() -> dict[str, bytes]:
	"""relative path -> bytes of every generated file."""
	files: dict[str, bytes] = {}
	entries: list[dict[str, Any]] = procedural_entries()
	for name, doc in valid_docs().items():
		data, h = B.package_bytes(doc)
		files[name + ".worldpoc"] = data
		entries.append({"name": name, "path": name + ".worldpoc", "kind": "world", "expected": "valid", "authored_hash": h})
	for name, (data, h, extra) in migration_outputs().items():
		files[name + ".worldpoc"] = data
		entries.append(dict({"name": name, "path": name + ".worldpoc", "expected": "valid", "authored_hash": h}, **extra))
	for name, (data, substring) in H.hostile_packages(valid_docs()).items():
		files["invalid/" + name + ".worldpoc"] = data
		entries.append({"name": name, "path": "invalid/" + name + ".worldpoc", "kind": "world", "expected": "invalid",
			"error_substring": substring})
	for e in entries:
		if e["path"]:
			e["sha256"] = hashlib.sha256(files[e["path"]]).hexdigest()
	entries.sort(key=lambda e: e["name"])
	vectors = GV.vectors_json(files)
	files["generation-vectors.json"] = vectors
	entries.append({"name": "generation_vectors", "path": "generation-vectors.json", "kind": "vectors", "expected": "valid",
		"sha256": hashlib.sha256(vectors).hexdigest(),
		"note": "Apply identities: source_snapshot_hash, consumer-profile hash, generation_id (ADR 0017 A2)"})
	entries.sort(key=lambda e: e["name"])
	index = {"schema": "world-painter/world-v4/fixture-index", "fixtures": entries}
	files["INDEX.json"] = (json.dumps(index, indent=2, ensure_ascii=True) + "\n").encode()
	files["canonical-lock-vectors.json"] = V.vectors_json()
	return files


def main(argv: list[str] | None = None) -> int:
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("--check", action="store_true", help="compare with the committed files instead of writing")
	a = p.parse_args(argv)
	files = generate()
	if a.check:
		bad = [n for n, d in files.items() if not (B.FIXTURES_V4 / n).is_file() or (B.FIXTURES_V4 / n).read_bytes() != d]
		for n in bad:
			print("MISMATCH %s" % n, file=sys.stderr)
		print("OK: %d files match" % len(files) if not bad else "FAILED")
		return 1 if bad else 0
	for n, d in files.items():
		path = B.FIXTURES_V4 / n
		path.parent.mkdir(parents=True, exist_ok=True)
		path.write_bytes(d)
	print("wrote %d files to %s" % (len(files), B.FIXTURES_V4))
	return 0


if __name__ == "__main__":
	sys.exit(main())
