"""Minimal consumer built only from the published archives (IP-09). Skipped without Godot or the AssetStudio repo."""
from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from wp_test_support import SCRIPTS  # noqa: F401

import godot_test  # noqa: E402
import make_minimal_consumer as mmc  # noqa: E402


@unittest.skipUnless(Path(godot_test.GODOT).exists(), "Godot binary not available")
@unittest.skipUnless((mmc.DEFAULT_ASSET_STUDIO / "scripts" / "package_addon.py").is_file(), "AssetStudio repo not available")
class MinimalConsumerTests(unittest.TestCase):
	def test_install_import_validate_and_load(self) -> None:
		work = Path(tempfile.mkdtemp(prefix="wp_minimal_consumer_"))
		try:
			result = mmc.run(work)
			self.assertEqual(set(result["lock"]["addons"]), {"assetstudio", "world_painter", "world_painter_catalog"})
			self.assertTrue(result["validate"]["ok"])
			self.assertFalse((work / "project" / "src").exists())
		finally:
			shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
	unittest.main()
