"""World Painter headless CLI (addons/world_painter/cli.gd) against the world-v4 fixture INDEX (IP-09).

Runs real Godot headless against app/ (skipped when Godot is absent); every invocation is bounded, stdin /dev/null."""
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from wp_test_support import FIXTURES as APP_FIXTURES  # noqa: F401

import godot_test  # noqa: E402

REPO = godot_test.REPO
V4 = REPO / "contracts" / "world-painter" / "world-v4" / "fixtures"
CLI = "res://addons/world_painter/cli.gd"


def cli(*args: str) -> tuple[int, dict]:
	r = subprocess.run([godot_test.GODOT, "--headless", "--path", str(godot_test.APP), "--script", CLI, "--", *args],
		capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
	lines = [x for x in r.stdout.splitlines() if x.startswith("{")]
	if len(lines) != 1:
		raise AssertionError(f"expected one JSON line (rc={r.returncode}):\n{r.stdout[-1500:]}{r.stderr[-1500:]}")
	return r.returncode, json.loads(lines[0])


@unittest.skipUnless(Path(godot_test.GODOT).exists(), "Godot binary not available")
class CliTests(unittest.TestCase):
	@classmethod
	def setUpClass(cls) -> None:
		rc, out = godot_test.godot_import(godot_test.APP)
		if rc != 0 or godot_test.import_errors(out):
			raise RuntimeError("godot import failed:\n" + out[-2000:])
		cls.index = {f["name"]: f for f in json.loads((V4 / "INDEX.json").read_text())["fixtures"]}

	def test_validate_agrees_with_fixture_index(self) -> None:
		checked = 0
		for name, f in sorted(self.index.items()):
			if f["path"] is None or f["kind"] not in ("world", "migration"):
				continue
			with self.subTest(fixture=name):
				rc, out = cli("validate", "--world", str(V4 / f["path"]))
				if f["expected"] == "valid":
					self.assertEqual((rc, out["ok"]), (0, True), out)
					self.assertEqual(out["authored_hash"], f["authored_hash"])
					self.assertEqual(out["errors"], [])
					self.assertIn("unavailable", out["availability"])
				else:
					self.assertEqual((rc, out["ok"]), (1, False), out)
					self.assertIn(f["error_substring"], " ".join(out["errors"]))
				checked += 1
		self.assertGreaterEqual(checked, 15)

	def test_usage_and_dispatch_errors(self) -> None:
		self.assertEqual(cli()[0], 2)
		self.assertEqual(cli("nope")[0], 2)
		self.assertEqual(cli("validate")[0], 2)
		self.assertEqual(cli("validate", "--world", "/definitely/missing.worldpoc")[0], 1)

	def test_migrate_matches_index_and_refuses_existing(self) -> None:
		with tempfile.TemporaryDirectory(prefix="wp_cli_mig_") as d:
			for name in ("migrate_v2", "migrate_v3"):
				f = self.index[name]
				dest = Path(d) / name
				rc, out = cli("migrate", "--world", str(V4 / f["source"]), "--out", str(dest))
				self.assertEqual((rc, out["ok"]), (0, True), out)
				self.assertEqual(out["authored_hash"], f["authored_hash"])
				self.assertEqual(out["source_hash"], f["source_authored_hash"])
				rc, again = cli("validate", "--world", str(dest))
				self.assertEqual((rc, again["schema"], again["authored_hash"]), (0, 4, f["authored_hash"]))
				self.assertEqual(cli("migrate", "--world", str(V4 / f["source"]), "--out", str(dest))[0], 2)
			rc, out = cli("migrate", "--world", str(V4 / self.index["holes"]["path"]), "--out", str(Path(d) / "x"))
			self.assertEqual((rc, out["ok"]), (1, False))
			self.assertFalse((Path(d) / "x").exists())

	def test_migrate_app_fixtures_match_index(self) -> None:
		with tempfile.TemporaryDirectory(prefix="wp_cli_mig_") as d:
			for name in ("migrate_v2_app_flat", "migrate_v2_app_gentle_hills"):
				f = self.index[name]
				rc, out = cli("migrate", "--world", str(REPO / f["source"]), "--out", str(Path(d) / name))
				self.assertEqual((rc, out["ok"]), (0, True), out)
				self.assertEqual(out["authored_hash"], f["authored_hash"])


if __name__ == "__main__":
	unittest.main()
