"""Shared helpers for the Python format tests (stdlib unittest)."""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import worldpoc_format as wf  # noqa: E402

FIXTURES = wf.APP_DIR / "fixtures"
BOULDER = "nature.rock.boulder_a"


def boulder_record(object_id: str, x: float = 1.25, z: float = -7.3, y: float = 0.0, scale: float = 1.3,
		offset: float = 0.0, grounding: str = "FOLLOW_TERRAIN") -> dict[str, Any]:
	return wf.make_object_record(object_id, BOULDER, 1, [x, y, z], [0.0, 0.34289780745545134, 0.0, 0.9393727128473789],
		scale, grounding, offset)


def uuid_n(n: int) -> str:
	return "00000000-0000-4000-8000-%012d" % n


class GenerationTestCase(unittest.TestCase):
	"""Each test gets a private copy of the flat fixture it may mutate."""

	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_test_"))
		self.gen = self.tmp / "gen"
		shutil.copytree(FIXTURES / "flat", self.gen)

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def manifest(self) -> dict[str, Any]:
		return json.loads((self.gen / "manifest.json").read_text())

	def write_manifest(self, m: dict[str, Any]) -> None:
		(self.gen / "manifest.json").write_bytes(wf.dump_json(m))

	def write_objects(self, objects: list[Any], raw: bytes | None = None) -> None:
		data = raw if raw is not None else wf.dump_json({"schema_version": 1, "objects": objects})
		(self.gen / "objects.json").write_bytes(data)

	def reseal(self) -> None:
		"""Recompute payload sizes/hashes and the authored hash so only the rule under test fails."""
		m = self.manifest()
		for e in m["payload_files"]:
			data = (self.gen / e["path"]).read_bytes()
			e["bytes"] = len(data)
			e["sha256"] = hashlib.sha256(data).hexdigest()
		try:
			objs = json.loads((self.gen / "objects.json").read_text())["objects"]
			records = [wf.parse_object_record(o)[0] for o in objs]
			if all(r is not None for r in records):
				digests = {loc: (hashlib.sha256((self.gen / wf.height_path(loc)).read_bytes()).digest(),
					hashlib.sha256((self.gen / wf.control_path(loc)).read_bytes()).digest()) for loc in wf.REGION_LOCATIONS}
				m["authored_content_hash"] = wf.authored_hash(m["catalog"], digests, records)  # type: ignore[arg-type]
		except (ValueError, KeyError, TypeError):
			pass
		self.write_manifest(m)

	def errors(self) -> list[str]:
		_, errors = wf.validate_generation(self.gen)
		return errors

	def assertRejected(self, needle: str) -> list[str]:
		errors = self.errors()
		self.assertTrue(any(needle in e for e in errors), "expected an error containing %r, got %r" % (needle, errors))
		return errors
