"""`dev.py verify-export`: the required-file list is derived from the committed registries (no export needed)."""
from __future__ import annotations

import json
import unittest

from wp_test_support import SCRIPTS  # noqa: F401
import dev_verify_export as v


class RequiredEntriesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.entries = v.required_entries()
        cls.alternatives = {path for e in cls.entries for path in e["any_of"]}

    def test_entries_are_well_formed_and_unique(self) -> None:
        keys = [tuple(e["any_of"]) for e in self.entries]
        self.assertEqual(len(keys), len(set(keys)))
        for e in self.entries:
            self.assertTrue(e["label"])
            self.assertTrue(e["any_of"], e["label"])
            for path in e["any_of"]:
                self.assertTrue(path.startswith("res://"), path)

    def test_fixed_files_are_required(self) -> None:
        for path in v.FIXED_FILES:
            self.assertIn(path, self.alternatives)
        self.assertIn("res://addons/world_painter/terrain/world_terrain.gdshader", self.alternatives)

    def test_every_registry_dependency_is_required(self) -> None:
        for index, _name in v.REGISTRIES:
            self.assertIn(v.res_path(index), self.alternatives)
            for asset in json.loads(index.read_text())["assets"]:
                descriptor = index.parent / asset["descriptor"]
                self.assertIn(v.res_path(descriptor), self.alternatives)
                for dep in json.loads(descriptor.read_text())["dependencies"]:
                    path = descriptor.parent / dep["path"]
                    if path.suffix == ".png":
                        self.assertTrue(any(c.endswith(".ctex") for c in v.imported_candidates(path)), str(path))
                        for c in v.imported_candidates(path):
                            self.assertIn(c, self.alternatives)
                    else:
                        self.assertIn(v.res_path(path), self.alternatives)

    def test_catalogs_scenes_and_terrain_preview_textures_are_required(self) -> None:
        for catalog in v.CATALOGS:
            self.assertIn(v.res_path(catalog), self.alternatives)
            for asset in json.loads(catalog.read_text())["assets"]:
                self.assertIn(asset["preview_scene"], self.alternatives)
        preview = sorted((v.APP / "assets" / "terrain" / "preview").glob("*.png"))
        self.assertTrue(preview)
        for texture in preview:
            self.assertTrue(set(v.imported_candidates(texture)) <= self.alternatives, texture.name)

    def test_imported_textures_are_checked_through_their_import_outputs(self) -> None:
        texture = next((v.APP / "assets" / "terrain" / "preview").glob("*.png"))
        e = v.entry("t", texture)
        self.assertTrue(all("/.godot/imported/" in p for p in e["any_of"]), e)
        self.assertNotIn(v.res_path(texture), e["any_of"])

    def test_excluded_directories_are_forbidden(self) -> None:
        self.assertEqual(set(v.FORBIDDEN_DIRS), {"res://devtools", "res://tests"})

    def test_missing_pck_is_a_usage_error(self) -> None:
        import argparse
        import contextlib
        import io
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(v.cmd_verify_export(argparse.Namespace(pck="/nonexistent/x.pck")), 2)


if __name__ == "__main__":
    unittest.main()
