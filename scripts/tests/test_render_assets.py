"""Render-asset registry validator (docs/render-assets.md), stdlib unittest."""
from __future__ import annotations

import copy
import hashlib
import json
import shutil
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from typing import Any, Callable

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import render_asset_format as raf  # noqa: E402
import validate_render_assets as vra  # noqa: E402

# Shared with app/tests/unit/test_render_asset_descriptor.gd: both sides must produce these hex values.
VECTOR_SOURCE_HASH = "964a07c16f495345ab854358837f5be1d46082436febc868489dd903fa2d7be2"
VECTOR_DERIVATIVE_HASH = "2d2e133ad1b476248bd99428c6f8b10fd52299648ca90bda4346bdda39414e79"


def sha(data: bytes) -> str:
	return hashlib.sha256(data).hexdigest()


def png_bytes(w: int, h: int) -> bytes:
	def chunk(kind: bytes, body: bytes) -> bytes:
		return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
	raw = b"".join(b"\x00" + b"\x80\x80\x80\xff" * w for _ in range(h))
	return vra.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) \
		+ chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def vector_descriptor() -> dict[str, Any]:
	def dep(key: str, typ: str, path: str, size: int, fill: str, gpu: int = 0, staging: int = 0) -> dict[str, Any]:
		return {"key": key, "type": typ, "path": path, "bytes": size, "sha256": fill * 64, "gpu_bytes": gpu,
			"staging_bytes": staging}
	aabb = {"aabb_min_m": [-1.0, 0.0, -1.0], "aabb_max_m": [1.0, 4.0, 1.0]}
	return {
		"format": "world-painter-render-asset", "schema_version": 1, "asset_id": "vec.asset", "asset_version": 3,
		"source_content_hash": "ab" * 32, "derivative_hash": "cd" * 32, "category": "tree",
		"vegetation": True, "decorative": False,
		"anchor_local_m": [0.0, 0.0, 0.0], "bounds_min_m": [-1.0, 0.0, -1.0], "bounds_max_m": [1.0, 4.0, 1.0],
		"footprint_radius_m": 1.0,
		"representations": {
			"selected": {"mesh": "mesh_sel", "triangles": 1536, "surfaces": 2, **aabb},
			"near": {"alias": "selected"}, "mid": {"alias": "selected"},
			"far": {"mesh": "mesh_far", "triangles": 44, "surfaces": 1, **aabb},
			"ghost": {"alias": "far"}},
		"overview": {"kind": "canopy", "shape": "cone", "base_y_m": 1.0, "height_m": 3.0, "radius_m": 1.0,
			"color": [0.1, 0.3, 0.2]},
		"materials": {"leaf": {"dependency": "mat_a", "alpha_mode": "cutout", "texture": "leaf_tex"}},
		"textures": {"leaf_tex": {
			"low": {"dependency": "tex_low", "width": 256, "height": 128, "mipmaps": True},
			"preview": {"dependency": "tex_prev", "width": 1024, "height": 512, "mipmaps": True}}},
		"dependencies": [
			dep("mat_a", "material", "a.tres", 10, "1"),
			dep("mesh_far", "mesh", "far.tres", 20, "2", 600, 600),
			dep("mesh_sel", "mesh", "sel.tres", 30, "3", 90000, 90000),
			dep("tex_low", "texture", "low.png", 40, "4", 43690, 131072),
			dep("tex_prev", "texture", "prev.png", 50, "5", 699050, 2097152)],
		"provenance": "vector", "license": "CC0-1.0"}


class HashVectorTest(unittest.TestCase):
	def test_source_hash_vector(self) -> None:
		got = raf.source_content_hash("vec.asset", 3, hashlib.sha256(b"preview").digest(), hashlib.sha256(b"scatter").digest())
		self.assertEqual(got, VECTOR_SOURCE_HASH)
		self.assertNotEqual(got, raf.source_content_hash("vec.asset", 3, hashlib.sha256(b"preview").digest()))

	def test_derivative_hash_vector(self) -> None:
		desc, err = raf.parse_descriptor(vector_descriptor())
		self.assertEqual(err, "")
		assert desc is not None
		self.assertEqual(raf.derivative_hash(desc), VECTOR_DERIVATIVE_HASH)


class RegistryBuilder:
	"""Writes a tiny app dir: catalog with one asset, its sources, one descriptor and its dependencies."""

	def __init__(self, root: Path) -> None:
		self.app = root / "app"
		self.assets = self.app / "assets"
		self.rdir = self.assets / "render_assets"
		(self.assets / "models").mkdir(parents=True)
		(self.rdir / "pine").mkdir(parents=True)
		(self.app / "project.godot").write_text("")
		self.preview = b"[gd_scene]\nscene"
		self.scatter = b"[gd_resource]\nscatter"
		(self.assets / "models" / "pine.tscn").write_bytes(self.preview)
		(self.assets / "models" / "pine_scatter.tres").write_bytes(self.scatter)
		self.catalog: dict[str, Any] = {"catalog_id": "test_cat", "catalog_version": 2, "assets": [{
			"asset_id": "nature.tree.pine", "version": 1, "preview_scene": "res://assets/models/pine.tscn",
			"scatter_mesh": "res://assets/models/pine_scatter.tres",
			"bounds_min": [-1.0, 0.0, -1.0], "bounds_max": [1.0, 4.0, 1.0],
			"placement_anchor_local": [0.0, 0.1, 0.0], "footprint_radius_m": 1.0}]}
		self.files = {"sel.tres": b"mesh-sel", "far.tres": b"mesh-far", "mat.tres": b"material",
			"low.png": png_bytes(8, 4), "prev.png": png_bytes(16, 8)}
		self.imports = {"low.png", "prev.png"}
		self.import_text = "[params]\ncompress/mode=2\nmipmaps/generate=true\ncompress/normal_map=2\n"
		self.index_extra: dict[str, Any] = {}

	def descriptor(self) -> dict[str, Any]:
		d = vector_descriptor()
		d["asset_id"], d["asset_version"] = "nature.tree.pine", 1
		d["anchor_local_m"] = [0.0, 0.1, 0.0]
		src = raf.source_content_hash("nature.tree.pine", 1, hashlib.sha256(self.preview).digest(),
			hashlib.sha256(self.scatter).digest())
		d["source_content_hash"] = src
		names = {"mat_a": "mat.tres", "mesh_far": "far.tres", "mesh_sel": "sel.tres", "tex_low": "low.png", "tex_prev": "prev.png"}
		for dep in d["dependencies"]:
			dep["path"] = names[dep["key"]]
			dep["bytes"] = len(self.files[dep["path"]])
			dep["sha256"] = sha(self.files[dep["path"]])
		d["textures"]["leaf_tex"]["low"].update(width=8, height=4)
		d["textures"]["leaf_tex"]["preview"].update(width=16, height=8)
		return d

	def write(self, mutate_descriptor: Callable[[dict[str, Any]], None] | None = None,
			mutate_index: Callable[[dict[str, Any]], None] | None = None, fix_hashes: bool = True) -> Path:
		d = self.descriptor()
		if mutate_descriptor:
			mutate_descriptor(d)
		if fix_hashes:
			parsed, err = raf.parse_descriptor(d)
			if parsed is not None:
				d["derivative_hash"] = raf.derivative_hash(parsed)
		raw = json.dumps(d, indent="\t").encode()
		(self.rdir / "pine" / "descriptor.json").write_bytes(raw)
		for name, data in self.files.items():
			(self.rdir / "pine" / name).write_bytes(data)
			imp = self.rdir / "pine" / (name + ".import")
			imp.unlink(missing_ok=True)
			if name.endswith(".png") and name in self.imports:
				imp.write_text(self.import_text)
		index = {"format": "world-painter-render-assets", "schema_version": 1, "catalog_id": "test_cat",
			"catalog_version": 2, "prepared_for": {"godot": "4.7.2", "renderer": "mobile", "texture_formats": ["etc2_astc"]},
			"assets": [{"asset_id": "nature.tree.pine", "asset_version": 1, "descriptor": "pine/descriptor.json",
				"descriptor_sha256": sha(raw)}]}
		if mutate_index:
			mutate_index(index)
		(self.assets / "catalog.json").write_text(json.dumps(self.catalog))
		(self.rdir / "index.json").write_text(json.dumps(index))
		return self.rdir / "index.json"

	def validate(self, **kw: Any) -> tuple[str, str]:
		index = self.write(**kw)
		report = vra.validate_registry(index, self.assets)
		return report.assets["nature.tree.pine"]


class ValidatorTest(unittest.TestCase):
	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_render_assets_"))
		self.b = RegistryBuilder(self.tmp)

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def reason(self, **kw: Any) -> str:
		return self.b.validate(**kw)[0]

	def test_valid_registry_is_ready(self) -> None:
		self.assertEqual(self.b.validate(), ("", ""))
		report = vra.validate_registry(self.tmp / "app/assets/render_assets/index.json", self.b.assets)
		self.assertFalse(report.failed())
		self.assertEqual(report.lines(), ["nature.tree.pine READY"])
		self.assertEqual(vra.main(["--index", str(self.b.rdir / "index.json"), "--catalog-dir", str(self.b.assets)]), 0)

	def test_catalog_asset_without_entry_is_reported_not_failed(self) -> None:
		index = self.b.write(mutate_index=lambda i: i.update(assets=[]))
		report = vra.validate_registry(index, self.b.assets)
		self.assertEqual(report.assets["nature.tree.pine"][0], "no_derivative")
		self.assertFalse(report.failed())
		self.assertIn("NOT_READY no_derivative", report.lines()[0])

	def test_invalid_listed_asset_exits_nonzero(self) -> None:
		self.b.write(mutate_descriptor=lambda d: d["dependencies"][0].update(sha256="0" * 64), fix_hashes=True)
		self.assertEqual(vra.main(["--index", str(self.b.rdir / "index.json"), "--catalog-dir", str(self.b.assets)]), 1)

	def test_descriptor_failures(self) -> None:
		cases: dict[str, Callable[[dict[str, Any]], None]] = {
			"unsupported_version": lambda d: d.update(schema_version=2),
			"descriptor_invalid": lambda d: d.update(surprise=1),
			"path_rejected": lambda d: d["dependencies"][0].update(path="../x.tres"),
		}
		for want, mutate in cases.items():
			with self.subTest(want):
				self.assertEqual(self.reason(mutate_descriptor=mutate), want)

	def test_path_rules(self) -> None:
		for bad in ("../x.tres", "/abs/x.tres", "res://x.tres", "a\\b.tres", "a//b.tres", "./x.tres", "x.tscn", "a:b.tres"):
			with self.subTest(bad):
				self.assertEqual(self.reason(mutate_descriptor=lambda d, b=bad: d["dependencies"][0].update(path=b)), "path_rejected")
		self.assertEqual(self.reason(mutate_descriptor=lambda d: d["dependencies"][0].update(type="mesh", path="x.tscn")), "path_rejected")

	def test_role_and_dependency_rules(self) -> None:
		def alias_cycle(d: dict[str, Any]) -> None:
			d["representations"]["selected"] = {"alias": "near"}
			d["representations"]["near"] = {"alias": "selected"}

		def alias_chain(d: dict[str, Any]) -> None:
			d["representations"]["ghost"] = {"alias": "mid"}
			d["representations"]["mid"] = {"alias": "near"}
			d["representations"]["near"] = {"alias": "far"}

		def missing_role(d: dict[str, Any]) -> None:
			del d["representations"]["mid"]

		def unknown_key(d: dict[str, Any]) -> None:
			d["representations"]["far"]["mesh"] = "nope"

		for name, mutate in {"alias_cycle": alias_cycle, "alias_chain": alias_chain, "missing_role": missing_role,
				"unknown_key": unknown_key,
				"zero_triangles": lambda d: d["representations"]["far"].update(triangles=0),
				"bad_surfaces": lambda d: d["representations"]["far"].update(surfaces=9),
				"npot": lambda d: d["textures"]["leaf_tex"]["low"].update(width=100),
				"huge_bound": lambda d: d.update(bounds_max_m=[1.0, "inf", 1.0])}.items():
			with self.subTest(name):
				self.assertEqual(self.reason(mutate_descriptor=mutate), "descriptor_invalid")

	def test_identity_failures(self) -> None:
		self.assertEqual(self.reason(mutate_descriptor=lambda d: d.update(anchor_local_m=[0.0, 0.101, 0.0])), "logical_mismatch")
		self.assertEqual(self.reason(mutate_descriptor=lambda d: d.update(footprint_radius_m=1.5)), "logical_mismatch")
		self.assertEqual(self.reason(mutate_descriptor=lambda d: d.update(source_content_hash="0" * 64)), "source_changed")
		self.assertEqual(self.reason(mutate_descriptor=lambda d: d.update(derivative_hash="0" * 64), fix_hashes=False),
			"derivative_hash_mismatch")
		self.b.catalog["assets"][0]["version"] = 2
		self.assertEqual(self.reason(), "logical_mismatch")

	def test_source_change_makes_not_ready(self) -> None:
		self.b.write()
		(self.b.assets / "models" / "pine.tscn").write_bytes(b"changed")
		report = vra.validate_registry(self.b.rdir / "index.json", self.b.assets)
		self.assertEqual(report.assets["nature.tree.pine"][0], "source_changed")

	def test_index_failures(self) -> None:
		self.assertEqual(self.reason(mutate_index=lambda i: i.update(catalog_version=3)), "catalog_mismatch")
		self.assertEqual(self.reason(mutate_index=lambda i: i.update(schema_version=2)), "unsupported_version")
		self.assertEqual(self.reason(mutate_index=lambda i: i.update(extra=1)), "no_registry")
		self.assertEqual(self.reason(mutate_index=lambda i: i["assets"][0].update(descriptor="../d.json")), "path_rejected")
		self.assertEqual(self.reason(mutate_index=lambda i: i["assets"][0].update(descriptor_sha256="0" * 64)),
			"descriptor_hash_mismatch")
		self.assertEqual(self.reason(mutate_index=lambda i: i["assets"].append(copy.deepcopy(i["assets"][0]))), "no_registry")
		index = self.b.write()
		index.unlink()
		report = vra.validate_registry(index, self.b.assets)
		self.assertEqual(report.assets["nature.tree.pine"][0], "no_registry")
		self.assertTrue(report.failed())

	def test_dependency_failures(self) -> None:
		self.b.write()
		(self.b.rdir / "pine" / "far.tres").write_bytes(b"tampered")
		self.assertEqual(vra.validate_registry(self.b.rdir / "index.json", self.b.assets).assets["nature.tree.pine"][0],
			"dependency_hash_mismatch")
		self.b.write()
		(self.b.rdir / "pine" / "far.tres").unlink()
		self.assertEqual(vra.validate_registry(self.b.rdir / "index.json", self.b.assets).assets["nature.tree.pine"][0],
			"dependency_missing")

	def test_png_header_and_import_checks(self) -> None:
		self.b.files["low.png"] = png_bytes(16, 4)  # descriptor says 8x4
		reason, detail = self.b.validate()
		self.assertEqual(reason, "descriptor_invalid")
		self.assertIn("PNG size", detail)
		self.b.files["low.png"] = png_bytes(8, 4)
		self.b.import_text = "[params]\ncompress/mode=0\nmipmaps/generate=true\ncompress/normal_map=2\n"
		reason, detail = self.b.validate()
		self.assertEqual(reason, "descriptor_invalid")
		self.assertIn("compress/mode", detail)
		self.b.import_text = "[params]\ncompress/mode=2\nmipmaps/generate=false\ncompress/normal_map=2\n"
		self.assertIn("mipmaps/generate", self.b.validate()[1])
		self.b.import_text = "[params]\ncompress/mode=2\nmipmaps/generate=true\ncompress/normal_map=0\n"
		self.assertIn("normal_map", self.b.validate()[1])
		self.b.import_text = "[params]\ncompress/mode=2\nmipmaps/generate=true\ncompress/normal_map=2\n"
		self.b.imports = {"prev.png"}
		self.assertEqual(self.b.validate()[0], "dependency_missing")


if __name__ == "__main__":
	unittest.main()
