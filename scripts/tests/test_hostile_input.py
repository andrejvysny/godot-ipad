"""Hostile JSON must produce errors, never exceptions or unprintable reports (world-format §7)."""
from __future__ import annotations

import subprocess
import sys

from wp_test_support import SCRIPTS, GenerationTestCase, boulder_record, uuid_n, wf

HUGE = "1" + "0" * 400  # an int no float can hold; Godot reads it as inf


class HostileJsonTests(GenerationTestCase):
	def _raw_manifest(self, old: str, new: str) -> None:
		path = self.gen / "manifest.json"
		text = path.read_text()
		self.assertIn(old, text)
		path.write_text(text.replace(old, new, 1))

	def _raw_objects(self, record_json: str) -> None:
		self.write_objects([], raw=('{"schema_version": 1, "objects": [%s]}' % record_json).encode("utf-8"))
		self.reseal()

	def assertRejectedAscii(self, needle: str) -> list[str]:
		errors = self.assertRejected(needle)
		for e in errors:
			e.encode("ascii")  # every diagnostic stays printable on any terminal
		return errors

	def test_huge_int_schema_version(self) -> None:
		self._raw_manifest('"schema_version": 1', '"schema_version": ' + HUGE)
		self.assertRejectedAscii("unknown schema_version")

	def test_int_beyond_python_digit_limit(self) -> None:
		self._raw_manifest('"schema_version": 1', '"schema_version": 1' + "0" * 5000)
		self.assertRejectedAscii("not valid JSON")

	def test_huge_int_payload_bytes_and_revision(self) -> None:
		m = self.manifest()
		m["payload_files"][0]["bytes"] = int(HUGE)
		m["document_revision"] = int(HUGE)
		self.write_manifest(m)
		errors = self.assertRejectedAscii("bytes 1000")
		self.assertTrue(any("document_revision" in e for e in errors), errors)

	def test_huge_int_in_terrain_block(self) -> None:
		m = self.manifest()
		m["terrain"]["region_samples"] = int(HUGE)
		m["terrain"]["region_locations"][0][0] = -int(HUGE)
		self.write_manifest(m)
		errors = self.assertRejectedAscii("terrain.region_samples")
		self.assertTrue(any("terrain.region_locations" in e for e in errors), errors)

	def test_huge_ints_in_object_record(self) -> None:
		rec = wf.dump_json(boulder_record(uuid_n(1))).decode("utf-8")
		self._raw_objects(rec.replace('"asset_version": 1', '"asset_version": ' + HUGE))
		self.assertRejectedAscii("asset_version must be a positive integer")
		self._raw_objects(rec.replace('"height_offset_m": 0.0', '"height_offset_m": ' + HUGE))
		self.assertRejectedAscii("height_offset_m must be finite")

	def test_deep_nesting(self) -> None:
		self._raw_manifest('"document_revision": 0', '"document_revision": ' + "[" * 100000 + "]" * 100000)
		self.assertRejectedAscii("")

	def test_lone_surrogates_are_escaped(self) -> None:
		rec = wf.dump_json(boulder_record(uuid_n(1))).decode("utf-8")
		for field, needle in (("grounding", "grounding '\\ud800'"), ("origin", "origin '\\ud800'"),
				("asset_id", "asset '\\ud800'")):
			old = '"%s": "%s"' % (field, boulder_record(uuid_n(1))[field])
			self._raw_objects(rec.replace(old, '"%s": "\\ud800"' % field))
			self.assertRejectedAscii(needle)
		self._raw_manifest('"format": "world-painter-poc"', '"format": "\\udfff\\u0007"')
		self.assertRejectedAscii("unknown format '\\udfff\\x07'")

	def test_duplicate_key_with_surrogate(self) -> None:
		self._raw_objects('{"\\ud800": 1, "\\ud800": 2}')
		self.assertRejectedAscii("duplicate JSON key '\\ud800'")

	def test_cli_reports_hostile_world_as_invalid(self) -> None:
		rec = wf.dump_json(boulder_record(uuid_n(1))).decode("utf-8")
		variants = (rec.replace('"grounding": "FOLLOW_TERRAIN"', '"grounding": "\\ud800"'),
			rec.replace('"asset_version": 1', '"asset_version": ' + HUGE))
		for variant in variants:
			self._raw_objects(variant)
			for extra in ([], ["--json"]):
				# Strict UTF-8 stdout: an unescaped lone surrogate would raise UnicodeEncodeError.
				p = subprocess.run([sys.executable, str(SCRIPTS / "validate_world.py"), str(self.gen)] + extra,
					capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120,
					env={"PYTHONIOENCODING": "utf-8:strict"})
				self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
				self.assertNotIn("Traceback", p.stderr)
				self.assertIn("INVALID" if not extra else '"valid": false', p.stdout)

	def test_hostile_package_is_invalid_not_raised(self) -> None:
		self._raw_manifest('"schema_version": 1', '"schema_version": ' + HUGE)
		pkg = self.tmp / "hostile.worldpoc"
		wf.write_package(self.gen, pkg)
		result = wf.validate_path(pkg)
		self.assertFalse(result["valid"])
		self.assertTrue(any("unknown schema_version" in e for e in result["errors"]), result["errors"])


if __name__ == "__main__":
	import unittest
	unittest.main()
