"""World Painter source archives: deterministic build, manifests, installer safety (IP-09). No Godot needed."""
from __future__ import annotations

import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

from wp_test_support import SCRIPTS  # noqa: F401

import install_world_painter as iwp  # noqa: E402
import package_world_painter as pwp  # noqa: E402
import wp_archive as wa  # noqa: E402


class PackagingTests(unittest.TestCase):
	@classmethod
	def setUpClass(cls) -> None:
		cls.tmp = Path(tempfile.mkdtemp(prefix="wp_pkg_"))
		cls.a = cls.tmp / "a"
		cls.b = cls.tmp / "b"
		cls.addon, cls.addon_manifest = pwp.build_addon(cls.a)
		cls.catalog, cls.catalog_manifest = pwp.build_catalog(cls.a)

	@classmethod
	def tearDownClass(cls) -> None:
		shutil.rmtree(cls.tmp, ignore_errors=True)

	def test_two_builds_are_byte_identical(self) -> None:
		addon2, _ = pwp.build_addon(self.b)
		catalog2, _ = pwp.build_catalog(self.b)
		self.assertEqual(self.addon.read_bytes(), addon2.read_bytes())
		self.assertEqual(self.catalog.read_bytes(), catalog2.read_bytes())

	def test_version_and_sidecar(self) -> None:
		self.assertEqual(self.addon.name, f"world-painter-addon-{pwp.read_version()}.zip")
		self.assertFalse(pwp.read_version().endswith("-dev"))
		self.assertEqual(wa.read_sidecar(self.addon), wa.sha256_file(self.addon))
		self.assertEqual(self.addon_manifest["contract_versions"], {"world": "world-v4", "live": "live-v1"})
		self.assertEqual(wa.lock_entry(self.addon_manifest)["contract_version"], "world-v4/live-v1")

	def test_addon_contents(self) -> None:
		names = set(self.addon_manifest["files"])
		self.assertIn("addons/world_painter/plugin.cfg", names)
		self.assertIn("addons/world_painter/cli.gd", names)
		self.assertIn("addons/world_painter/contracts/world-painter/world-v4/fixtures/INDEX.json", names)
		self.assertTrue(all(n.startswith("addons/world_painter/") for n in names))
		bad = [n for n in names if "/tests/" in n or "/.godot/" in n or "__pycache__" in n or n.endswith(".pyc")]
		self.assertEqual(bad, [])

	def test_catalog_contents_are_what_the_hash_needs(self) -> None:
		names = set(self.catalog_manifest["files"])
		self.assertIn("assets/catalog.json", names)
		self.assertTrue(all(n.startswith(("assets/models/", "assets/render_assets/")) or n == "assets/catalog.json" for n in names))
		self.assertIn("assets/render_assets/index.json", names)
		cat = json.loads((pwp.ASSETS / "catalog.json").read_text())
		for asset in cat["assets"]:
			self.assertIn(asset["preview_scene"].removeprefix("res://"), names)
		self.assertEqual(self.catalog_manifest["catalog"]["sha256"], pwp.wv.catalog_sha256(pwp.ROOT / "app"))


class InstallerTests(unittest.TestCase):
	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_inst_"))
		self.addon, _ = pwp.build_addon(self.tmp / "dist")
		self.catalog, _ = pwp.build_catalog(self.tmp / "dist")
		self.project = self.tmp / "project"
		self.project.mkdir()
		(self.project / "project.godot").write_text("config_version=5\n")
		self.other = {"source_repository": "x/y", "package_version": "9"}
		(self.project / iwp.LOCK_NAME).write_text(json.dumps({"schema_version": 1, "addons": {"assetstudio": self.other}}) + "\n")

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def _install(self) -> int:
		return iwp.main(["--project", str(self.project), str(self.addon), str(self.catalog)])

	def test_install_check_and_lock(self) -> None:
		self.assertEqual(self._install(), 0)
		self.assertEqual(iwp.main(["--project", str(self.project), "--check", str(self.addon), str(self.catalog)]), 0)
		lock = json.loads((self.project / iwp.LOCK_NAME).read_text())
		self.assertEqual(lock["addons"]["assetstudio"], self.other)
		self.assertEqual(set(lock["addons"]), {"assetstudio", "world_painter", "world_painter_catalog"})
		self.assertEqual(lock["addons"]["world_painter"]["archive_sha256"], wa.sha256_file(self.addon))
		self.assertEqual(list(lock["addons"]["world_painter"]), list(wa.LOCK_ENTRY_KEYS))

	def test_check_detects_changed_extra_and_missing(self) -> None:
		self._install()
		plugin = self.project / "addons" / "world_painter" / "plugin.cfg"
		plugin.write_text(plugin.read_text() + "x")
		(self.project / "assets" / "models" / "stray.tres").write_text("x")
		(self.project / "assets" / "catalog.json").unlink()
		problems = iwp.check(self.project, self.catalog, iwp.read_lock(self.project))
		self.assertEqual(sorted(problems), ["extra assets/models/stray.tres", "missing assets/catalog.json"])
		self.assertEqual(iwp.check(self.project, self.addon, iwp.read_lock(self.project)), ["changed addons/world_painter/plugin.cfg"])

	def test_sidecar_mismatch_refused(self) -> None:
		self.addon.with_name(self.addon.name + ".sha256").write_text(f"{'0' * 64}  {self.addon.name}\n")
		self.assertEqual(self._install(), 2)
		self.assertFalse((self.project / "addons").exists())

	def _forge(self, entry_name: str) -> Path:
		zp = self.tmp / "evil" / "world-painter-addon-9.zip"
		zp.parent.mkdir()
		src = self.tmp / "payload.txt"
		src.write_text("evil")
		hashes, digest = wa.write_zip(zp, {"addons/world_painter/ok.gd": src})
		with zipfile.ZipFile(zp, "w") as zf:
			zf.writestr(entry_name, "evil")
		digest = wa.sha256_file(zp)
		zp.with_name(zp.name + ".sha256").write_text(f"{digest}  {zp.name}\n")
		m = {"package": "world_painter", "version": "9", "source": {"commit": None, "dirty": None},
			"source_repository": "x/y", "contract_versions": {}, "archive": {"name": zp.name, "sha256": digest},
			"files": {entry_name: wa.sha256_bytes(b"evil")}}
		wa.write_json(wa.manifest_path(zp), m)
		return zp

	def test_path_traversal_and_foreign_paths_refused(self) -> None:
		for name in ("addons/world_painter/../../evil.gd", "/abs/evil.gd", "addons\\world_painter\\evil.gd",
				"addons/other/evil.gd", "project.godot", "addons/world_painter/x/../../../evil.gd"):
			zp = self._forge(name)
			rc = iwp.main(["--project", str(self.project), str(zp)])
			self.assertEqual(rc, 2, name)
			shutil.rmtree(zp.parent)
		self.assertFalse((self.tmp / "evil.gd").exists())
		self.assertEqual((self.project / "project.godot").read_text(), "config_version=5\n")


if __name__ == "__main__":
	unittest.main()
