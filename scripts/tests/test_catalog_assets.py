"""Bundled catalog: geometry files are self-contained, every scatter asset has a scatter mesh."""
from __future__ import annotations

import json
import unittest

from wp_test_support import wf

CATALOG = json.loads((wf.APP_DIR / "assets" / "catalog.json").read_text())
ASSETS = CATALOG["assets"]


class CatalogAssetTests(unittest.TestCase):
	def test_catalog_v2_has_seven_assets(self) -> None:
		self.assertEqual((CATALOG["catalog_id"], CATALOG["catalog_version"]), ("poc_nature", 2))
		self.assertEqual(len(ASSETS), 7)
		self.assertEqual(len({a["asset_id"] for a in ASSETS}), 7)

	def test_geometry_files_exist_and_are_self_contained(self) -> None:
		paths = wf.catalog_geometry_paths(CATALOG)
		self.assertGreaterEqual(len(paths), 7)
		for res in paths:
			path = wf.APP_DIR / res[len("res://"):]
			self.assertTrue(path.is_file(), res)
			self.assertNotIn("[ext_resource", path.read_text(), res)

	def test_scatter_assets_have_scatter_meshes(self) -> None:
		for a in ASSETS:
			if a["scatter_allowed"]:
				self.assertIsNotNone(a["scatter_mesh"], a["asset_id"])
				self.assertTrue(a["scatter_mesh"].endswith("_scatter.tres"), a["asset_id"])
			else:
				self.assertEqual(a["asset_id"], "built.lodge.cabin_a")

	def test_thumbnails_exist(self) -> None:
		for a in ASSETS:
			self.assertTrue((wf.APP_DIR / a["thumbnail"][len("res://"):]).is_file(), a["asset_id"])


if __name__ == "__main__":
	unittest.main()
