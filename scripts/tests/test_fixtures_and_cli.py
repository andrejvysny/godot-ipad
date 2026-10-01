"""Fixture properties (spec §3.2), determinism, CLI exit codes, and dev.py helpers."""
from __future__ import annotations

import filecmp
import io
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from wp_test_support import FIXTURES, SCRIPTS, wf  # noqa: F401

import dev  # noqa: E402
import generate_fixtures  # noqa: E402
import validate_world  # noqa: E402


def quiet(fn, *args):  # type: ignore[no-untyped-def]
	out, err = io.StringIO(), io.StringIO()
	with redirect_stdout(out), redirect_stderr(err):
		rc = fn(*args)
	return rc, out.getvalue() + err.getvalue()


class FixturePropertyTests(unittest.TestCase):
	@classmethod
	def setUpClass(cls) -> None:
		cls.hills = generate_fixtures.fixture_stats(FIXTURES / "gentle_hills")
		cls.flat = generate_fixtures.fixture_stats(FIXTURES / "flat")

	def test_gentle_hills_properties(self) -> None:
		s = self.hills
		self.assertTrue(10.0 <= s["max_height_m"] <= 13.0, s["max_height_m"])
		self.assertTrue(25.0 <= s["max_slope_deg"] <= 30.0, s["max_slope_deg"])
		self.assertLess(s["flat_area_stddev_m"], 0.01)
		self.assertLess(s["min_height_m"], 0.0)
		self.assertGreater(s["flat_area_samples"], 1000)

	def test_gentle_hills_varies_across_all_seams(self) -> None:
		for key, span in self.hills["seam_ranges_m"].items():
			self.assertGreater(span, 0.5, key)

	def test_flat_is_flat(self) -> None:
		self.assertEqual((self.flat["max_height_m"], self.flat["min_height_m"]), (0.0, 0.0))

	def test_fixture_metadata(self) -> None:
		for name, world_id in generate_fixtures.WORLD_IDS.items():
			m = json.loads((FIXTURES / name / "manifest.json").read_text())
			self.assertEqual(m["world_id"], world_id)
			self.assertEqual(m["document_revision"], 0)
			self.assertEqual(m["created_with"], generate_fixtures.CREATED_WITH)
			objects = json.loads((FIXTURES / name / "objects.json").read_text())["objects"]
			self.assertEqual(len(objects), 100 if name == "stress_100" else 0)

	def test_fixtures_are_schema_2_defaults(self) -> None:
		for name in generate_fixtures.WORLD_IDS:
			m = json.loads((FIXTURES / name / "manifest.json").read_text())
			self.assertEqual(m["schema_version"], 2)
			self.assertEqual(m["terrain"]["rules"], {"rock_enabled": True, "rock_slope_deg": 30,
				"sand_enabled": True, "sand_height_dm": -4})
			self.assertEqual(m["terrain"]["color_encoding"], "rgba8-tint-v1")
			self.assertEqual([e["path"] for e in m["payload_files"]], wf.PAYLOAD_PATHS)
			self.assertEqual((FIXTURES / name / "scatter.bin").read_bytes(), b"WPSC" + bytes([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
			self.assertEqual((FIXTURES / name / "paths.bin").read_bytes(), b"WPPA" + bytes([1, 0, 0, 0, 0, 0, 0, 0]))
			for loc in wf.REGION_LOCATIONS:
				self.assertEqual((FIXTURES / name / wf.control_path(loc)).read_bytes(),
					b"\x01\x00\x00\x00" * wf.REGION_SAMPLE_COUNT)
				self.assertEqual((FIXTURES / name / wf.color_path(loc)).read_bytes(),
					b"\xff\xff\xff\x00" * wf.REGION_SAMPLE_COUNT)

	def test_stress_100_objects(self) -> None:
		gen, errors = wf.validate_generation(FIXTURES / "stress_100")
		self.assertEqual(errors, [])
		objects = json.loads((FIXTURES / "stress_100" / "objects.json").read_text())["objects"]
		self.assertEqual(len({o["object_id"] for o in objects}), 100)
		counts: dict[str, int] = {}
		for o in objects:
			counts[o["asset_id"]] = counts.get(o["asset_id"], 0) + 1
		self.assertEqual(counts, {"built.lodge.cabin_a": 10, "nature.rock.boulder_a": 40, "nature.tree.spruce_a": 50})
		regions = wf.load_region_arrays(gen.heights)
		for o in objects:
			if o["grounding"] == "FOLLOW_TERRAIN":
				x, y, z = o["position"]
				self.assertAlmostEqual(y, wf.sample_height(regions, x, z) + o["height_offset_m"], delta=1e-3)


class DeterminismTests(unittest.TestCase):
	def test_generation_twice_is_byte_identical_and_matches_committed(self) -> None:
		with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
			generate_fixtures.generate(Path(a))
			generate_fixtures.generate(Path(b))
			for name in generate_fixtures.WORLD_IDS:
				for rel in sorted(wf.GENERATION_FILES):
					self.assertTrue(filecmp.cmp(Path(a) / name / rel, Path(b) / name / rel, shallow=False), rel)
		self.assertEqual(generate_fixtures.check(), [])

	def test_check_detects_mismatch(self) -> None:
		with tempfile.TemporaryDirectory() as d:
			shutil.copytree(FIXTURES / "flat", Path(d) / "flat")
			shutil.copytree(FIXTURES / "gentle_hills", Path(d) / "gentle_hills")
			shutil.copytree(FIXTURES / "stress_100", Path(d) / "stress_100")
			(Path(d) / "flat" / "objects.json").write_text('{"objects": [], "schema_version": 2}')
			self.assertEqual(generate_fixtures.check(Path(d)), ["flat/objects.json"])
			rc, _ = quiet(generate_fixtures.main, ["--check", "--out", d])
			self.assertEqual(rc, 1)


class ValidateWorldCliTests(unittest.TestCase):
	def test_exit_codes(self) -> None:
		rc, out = quiet(validate_world.main, [str(FIXTURES / "gentle_hills")])
		self.assertEqual(rc, 0)
		self.assertIn("VALID", out)
		rc, _ = quiet(validate_world.main, [str(FIXTURES / "stress_100")])
		self.assertEqual(rc, 0)
		rc, out = quiet(validate_world.main, [str(FIXTURES / "flat"), "--json"])
		self.assertEqual(rc, 0)
		self.assertTrue(json.loads(out)["valid"])
		rc, _ = quiet(validate_world.main, ["/nonexistent/world.worldpoc"])
		self.assertEqual(rc, 2)
		with tempfile.TemporaryDirectory() as d:
			bad = Path(d) / "bad.worldpoc"
			bad.write_bytes(b"not a zip")
			rc, out = quiet(validate_world.main, [str(bad)])
			self.assertEqual(rc, 1)
			self.assertIn("INVALID", out)


class DevHelperTests(unittest.TestCase):
	def test_patch_ios_preset_only_touches_preset0(self) -> None:
		text = (wf.APP_DIR / "export_presets.cfg").read_text()
		patched = dev.patch_ios_preset(text, {"application/app_store_team_id": '"ABCDE12345"',
			"application/export_project_only": "true"})
		self.assertIn('application/app_store_team_id="ABCDE12345"', patched)
		self.assertIn("application/export_project_only=true", patched)
		self.assertEqual(patched.split("[preset.1]")[1], text.split("[preset.1]")[1])
		with self.assertRaises(ValueError):
			dev.patch_ios_preset(text, {"application/no_such_option": "1"})

	def test_export_without_signing_fails_cleanly(self) -> None:
		preset = wf.APP_DIR / "export_presets.cfg"
		before = preset.read_bytes()
		with tempfile.TemporaryDirectory() as d:
			rc, out = quiet(dev.main, ["export-ios", "--signing-config", str(Path(d) / "missing.json")])
		self.assertEqual(rc, 2)
		self.assertIn("signing not configured", out)
		self.assertEqual(preset.read_bytes(), before)

	def test_signing_config_validation(self) -> None:
		with tempfile.TemporaryDirectory() as d:
			p = Path(d) / "s.json"
			p.write_text('{"team_id": "short"}')
			self.assertIn("10-character", dev.load_signing(p)[1])
			p.write_text('{"team_id": "ABCDE12345", "bundle_id": "com.example.x"}')
			self.assertEqual(dev.load_signing(p)[1], "")

	def test_placeholder_scan(self) -> None:
		found = dev._placeholders({"a": "RECORD_X", "b": {"c": "NOT_RUN: no iPad"}, "d": ["ok", "RECORD_Y"]})
		self.assertEqual(sorted(k for k, _ in found), ["a", "b.c", "d[1]"])

	def test_lock_and_evidence_have_no_unfilled_placeholders(self) -> None:
		for path in (dev.LOCK_PATH, dev.ENV_PATH):
			marks = dev._placeholders(json.loads(path.read_text()))
			self.assertEqual([k for k, v in marks if v.startswith("RECORD_")], [], path)

	def test_required_evidence_fields(self) -> None:
		for path in (dev.LOCK_PATH, dev.ENV_PATH):
			self.assertEqual(dev.missing_evidence_fields(json.loads(path.read_text())), [], path)
		data = json.loads(dev.LOCK_PATH.read_text())
		for key in ("ipad_model", "rendering_method", "godot_commit", "rendering_driver_active"):
			del data[key]
		data["xcode_version"] = ""
		data["export_template_sha256"]["ios.zip"] = ""
		missing = dev.missing_evidence_fields(data)
		self.assertEqual(missing[:5], ["godot_commit", "export_template_sha256", "xcode_version", "ipad_model",
			"rendering_method"])
		self.assertIn("rendering_driver", missing[5])
		with tempfile.TemporaryDirectory() as d:
			lock = Path(d) / "lock.json"
			lock.write_text(json.dumps(data))
			r = dev.Report()
			with mock.patch.object(dev, "LOCK_PATH", lock), redirect_stdout(io.StringIO()):
				dev._doctor_evidence(r)
			self.assertIn(("FAIL", str(lock)), [(s, n) for s, n, _ in r.rows])
			self.assertEqual(r.exit_code(False), 1)

	def test_doctor_godot_requires_recorded_commit(self) -> None:
		lock = json.loads(dev.LOCK_PATH.read_text())
		with mock.patch.object(dev, "run", return_value=(0, "4.7.2.stable.official.ed1daf0bf")), \
				redirect_stdout(io.StringIO()):
			ok, bad = dev.Report(), dev.Report()
			dev._doctor_godot(ok, lock)
			dev._doctor_godot(bad, {k: v for k, v in lock.items() if k != "godot_commit"})
		self.assertEqual(ok.rows[0][0], "OK")
		self.assertEqual(bad.rows[0][0], "FAIL")

	def test_native_bridge_reports_each_missing_artifact(self) -> None:
		self.assertTrue(any(".ios.template_release." in a for a in dev.native_bridge_artifacts()))
		with tempfile.TemporaryDirectory() as d:
			ext = Path(d) / "x.gdextension"
			ext.write_text('[libraries]\nmacos.debug = "res://project.godot"\n'
				'ios.release = "res://addons/wp_native_input/bin/missing.ios.template_release.xcframework"\n')
			r = dev.Report()
			with redirect_stdout(io.StringIO()):
				dev._doctor_native_bridge(r, ext)
		rows = sorted((s, detail) for s, _, detail in r.rows)
		self.assertEqual(rows, [("OK", "present project.godot"),
			("PENDING", "MISSING missing.ios.template_release.xcframework")])

	def test_secret_pattern(self) -> None:
		for name in ("x/dev.mobileprovision", "a.p12", "c.cer", "config/local.signing.json",
				"app/.godot/export_credentials.cfg"):
			self.assertTrue(dev.SECRET_PATTERNS.search(name), name)
		self.assertFalse(dev.SECRET_PATTERNS.search("app/export_presets.cfg"))


if __name__ == "__main__":
	unittest.main()
