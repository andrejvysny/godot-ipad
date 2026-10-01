"""dev.py open-consumer --verify-only against a real Godot headless run."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from wp_test_support import FIXTURES, SCRIPTS, wf  # noqa: F401

import dev  # noqa: E402

REPORT_PREFIX = "WORLDPOC_REPORT "


def run_consumer(path: Path) -> tuple[int, str]:
	p = subprocess.run([sys.executable, str(SCRIPTS / "dev.py"), "open-consumer", "--verify-only", "--timeout", "300", str(path)],
		stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600)
	return p.returncode, p.stdout + p.stderr


def build_package(gen: Path, out: Path) -> None:
	names = ["manifest.json"] + wf.PAYLOAD_PATHS
	with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as zf:
		for name in names:
			zf.writestr(zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0)), (gen / name).read_bytes())


@unittest.skipUnless(Path(dev.GODOT).exists(), "Godot binary not available")
class ConsumerVerifyOnlyTests(unittest.TestCase):
	def test_package_report_matches_manifest(self) -> None:
		gen = FIXTURES / "gentle_hills"
		with tempfile.TemporaryDirectory() as d:
			pkg = Path(d) / "hills.worldpoc"
			build_package(gen, pkg)
			rc, out = run_consumer(pkg)
		self.assertEqual(rc, 0, out)
		lines = [x for x in out.splitlines() if x.startswith(REPORT_PREFIX)]
		self.assertEqual(len(lines), 1, out)
		report = json.loads(lines[0][len(REPORT_PREFIX):])
		manifest = json.loads((gen / "manifest.json").read_text())
		self.assertTrue(report["ok"])
		self.assertEqual(report["authored_hash"], manifest["authored_content_hash"])

	def test_missing_file_fails(self) -> None:
		rc, out = run_consumer(Path(tempfile.gettempdir()) / "definitely_missing.worldpoc")
		self.assertNotEqual(rc, 0, out)


if __name__ == "__main__":
	unittest.main()
