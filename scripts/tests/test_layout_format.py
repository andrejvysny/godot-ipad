"""Schema 3 layout worlds (docs/world-format.md §11): layout rules, limits parity with GDScript,
the cross-language authored-hash vector, WORLD-03 rejections and a km1 package round trip."""
from __future__ import annotations

import hashlib
import io
import re
import shutil
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from typing import Any

from wp_test_support import wf, FIXTURES
import generate_fixtures as gf

# Same literal as KM1_FLAT_VECTOR in app/tests/unit/test_world_layout.gd (computed here first).
KM1_FLAT_VECTOR = "f1357e481f58e3076704020e211bea87471db121c067170e50b8de88d1816d92"
SMALL = ((0, 0), (2, 1))  # x in [0, 255.5], z in [0, 127.5]
LIMITS_GD = wf.APP_DIR / "src" / "document" / "world_limits.gd"


def km1_flat_hash() -> str:
	cat = wf.load_trusted_catalog()
	digests_of = (hashlib.sha256(struct.pack("<f", 0.0) * wf.REGION_SAMPLE_COUNT).digest(),
		hashlib.sha256(struct.pack("<I", wf.DEFAULT_CONTROL) * wf.REGION_SAMPLE_COUNT).digest(),
		hashlib.sha256(wf.DEFAULT_COLOR * wf.REGION_SAMPLE_COUNT).digest())
	digests = {loc: digests_of for loc in wf.layout_regions(*wf.KM1_LAYOUT)}
	return wf.authored_hash({"id": cat["id"], "version": int(cat["version"]), "sha256": cat["sha256"]},
		wf.DEFAULT_RULES, digests, wf.write_scatter([]), wf.write_paths([]), [], wf.KM1_LAYOUT)


class LayoutRuleTests(unittest.TestCase):
	def test_validate_layout(self) -> None:
		for ok in (((-4, -4), (8, 8)), ((-1, -1), (2, 2)), ((-8, -8), (1, 1)), ((7, 7), (1, 1)), ((0, -8), (8, 8))):
			self.assertEqual(wf.validate_layout(*ok), "", ok)
		for bad in (((0, 0), (0, 1)), ((0, 0), (1, 0)), ((-4, -4), (9, 1)), ((-4, -4), (1, 9)), ((0, 0), (-1, 2)),
				((-9, 0), (1, 1)), ((0, -9), (1, 1)), ((8, 0), (1, 1)), ((1, -4), (8, 8)), ((-4, 5), (1, 4)), ((7, 0), (2, 1))):
			self.assertNotEqual(wf.validate_layout(*bad), "", bad)

	def test_regions_extent_and_schema(self) -> None:
		self.assertEqual(wf.layout_regions(*wf.LEGACY_LAYOUT), wf.REGION_LOCATIONS)
		km = wf.layout_regions(*wf.KM1_LAYOUT)
		self.assertEqual((len(km), km[0], km[1], km[8], km[63]), (64, (-4, -4), (-3, -4), (-4, -3), (3, 3)))
		self.assertEqual(wf.layout_sample_range(wf.KM1_LAYOUT), ((-1024, 1023), (-1024, 1023)))
		self.assertEqual(wf.layout_extent(wf.KM1_LAYOUT), (-512.0, 511.5, -512.0, 511.5))
		self.assertEqual(wf.layout_extent(wf.LEGACY_LAYOUT), (wf.WORLD_MIN, wf.WORLD_MAX_SAMPLE, wf.WORLD_MIN, wf.WORLD_MAX_SAMPLE))
		self.assertEqual((wf.layout_schema(wf.LEGACY_LAYOUT), wf.layout_schema(wf.KM1_LAYOUT)), (2, 3))
		self.assertEqual(wf.layout_extent(((2, 3), (3, 1))), (256.0, 639.5, 384.0, 511.5))

	def test_layout_from_manifest(self) -> None:
		self.assertEqual(wf.layout_from_manifest(wf.layout_to_manifest(wf.KM1_LAYOUT)), (wf.KM1_LAYOUT, ""))
		self.assertEqual(wf.layout_from_manifest({"min_region": [-1.0, -1.0], "region_count": [2.0, 2.0]})[0], wf.LEGACY_LAYOUT)
		cases: dict[str, Any] = {
			"object": 5,
			"unknown field": {"min_region": [0, 0], "region_count": [1, 1], "x": 1},
			"missing field": {"min_region": [0, 0]},
			"two integers": {"min_region": [0, 0.5], "region_count": [1, 1]},
			"two integers ": {"min_region": [0, True], "region_count": [1, 1]},
			"region_count": {"min_region": [0, 0], "region_count": [0, 1]},
		}
		for needle, d in cases.items():
			layout, err = wf.layout_from_manifest(d)
			self.assertIsNone(layout, needle)
			self.assertIn(needle.strip(), err)

	def test_sampling_on_km1(self) -> None:
		h = struct.pack("<f", 2.5) * wf.REGION_SAMPLE_COUNT
		regions = wf.load_region_arrays({loc: h for loc in wf.layout_regions(*wf.KM1_LAYOUT)})
		layout = wf.KM1_LAYOUT
		self.assertEqual(wf.sample_height(regions, -512.0, 511.5, None, layout), 2.5)
		self.assertEqual(wf.sample_height(regions, 511.5, 100.25, None, layout), 2.5, "max edge clamp")
		for x, z in ((-512.01, 0.0), (0.0, 511.51), (600.0, 0.0)):
			self.assertTrue(wf.sample_height(regions, x, z, None, layout) != wf.sample_height(regions, x, z, None, layout))


class LimitsParityTests(unittest.TestCase):
	@staticmethod
	def _gd_tables() -> dict[str, dict[str, int]]:
		text = LIMITS_GD.read_text()
		out: dict[str, dict[str, int]] = {}
		for name in ("SCHEMA_2", "SCHEMA_3"):
			block = re.search(r"^const %s := \{\n((?:\t\"[a-z_]+\": [0-9]+(?: \* [0-9]+)*,\n)+)\}$" % name, text, re.M)
			assert block, "%s table not found or not in the strict form" % name
			table: dict[str, int] = {}
			for key, expr in re.findall(r"\t\"([a-z_]+)\": ([0-9]+(?: \* [0-9]+)*),", block.group(1)):
				value = 1
				for factor in expr.split(" * "):
					value *= int(factor)
				table[key] = value
			out[name] = table
		return out

	def test_tables_match_world_limits_gd(self) -> None:
		gd = self._gd_tables()
		self.assertEqual(gd["SCHEMA_2"], wf.limits_for_schema(2))
		self.assertEqual(gd["SCHEMA_3"], wf.limits_for_schema(3))
		self.assertEqual(wf.ZIP_ENVELOPE, wf.limits_for_schema(3))
		self.assertEqual(sorted(gd["SCHEMA_2"]), sorted(gd["SCHEMA_3"]))
		self.assertEqual(len(gd["SCHEMA_3"]), 10)

	def test_spec_values(self) -> None:
		v2, v3 = wf.limits_for_schema(2), wf.limits_for_schema(3)
		self.assertEqual((v2["max_objects"], v3["max_objects"]), (2000, 50000))
		self.assertEqual((v2["max_scatter_instances"], v3["max_scatter_instances"]), (20000, 100000))
		self.assertEqual(v3["max_entries"], 4 + 1 + 3 * 64)
		with self.assertRaises(KeyError):
			wf.limits_for_schema(1)


class VectorTests(unittest.TestCase):
	def test_km1_flat_vector_is_stable(self) -> None:
		self.assertEqual(km1_flat_hash(), KM1_FLAT_VECTOR)


class LegacyCompatibilityTests(unittest.TestCase):
	"""WORLD-01: schema 2 fixtures keep their recorded hashes and are never rewritten by reading."""

	def test_fixture_hashes_match_toolchain_lock(self) -> None:
		lock = wf.parse_json_bytes((wf.REPO / "config" / "toolchain.lock.json").read_bytes())
		for name, rec in lock["fixtures"].items():
			before = {p.name: p.stat().st_mtime_ns for p in (FIXTURES / name).iterdir() if p.is_file()}
			result = wf.validate_path(FIXTURES / name)
			self.assertTrue(result["valid"], result["errors"])
			self.assertEqual(result["authored_content_hash"], rec["authored_content_hash"], name)
			gen, _ = wf.validate_generation(FIXTURES / name)
			self.assertEqual((gen.layout, wf.layout_schema(gen.layout)), (wf.LEGACY_LAYOUT, 2))
			self.assertEqual(before, {p.name: p.stat().st_mtime_ns for p in (FIXTURES / name).iterdir() if p.is_file()})

	def test_rewriting_a_legacy_world_reproduces_schema_2_bytes(self) -> None:
		tmp = Path(tempfile.mkdtemp(prefix="wp_legacy_"))
		try:
			manifest = gf.write_flat_world(tmp / "w", wf.LEGACY_LAYOUT, "0f1a7000-0000-4000-8000-000000000001")
			self.assertEqual(manifest["schema_version"], 2)
			self.assertNotIn("layout", manifest["terrain"])
			self.assertEqual(manifest["authored_content_hash"],
				wf.parse_json_bytes((FIXTURES / "flat" / "manifest.json").read_bytes())["authored_content_hash"])
			for rel in sorted(wf.GENERATION_FILES - {"manifest.json"}):
				self.assertEqual((tmp / "w" / rel).read_bytes(), (FIXTURES / "flat" / rel).read_bytes(), rel)
		finally:
			shutil.rmtree(tmp, ignore_errors=True)


class SmallWorldCase(unittest.TestCase):
	"""A schema 3 world on a 2 x 1 layout (6 region files) that tests may damage."""

	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_layout_"))
		self.gen = self.tmp / "gen"
		gf.write_flat_world(self.gen, SMALL)

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def manifest(self) -> dict[str, Any]:
		return wf.parse_json_bytes((self.gen / "manifest.json").read_bytes())

	def write_manifest(self, m: dict[str, Any]) -> None:
		(self.gen / "manifest.json").write_bytes(wf.dump_json(m))

	def reseal_payload(self, name: str, data: bytes) -> None:
		(self.gen / name).write_bytes(data)
		m = self.manifest()
		for e in m["payload_files"]:
			if e["path"] == name:
				e["bytes"], e["sha256"] = len(data), hashlib.sha256(data).hexdigest()
		self.write_manifest(m)

	def errors(self) -> list[str]:
		return wf.validate_generation(self.gen)[1]

	def assertRejected(self, needle: str) -> None:
		errors = self.errors()
		self.assertTrue(any(needle in e for e in errors), "expected %r in %r" % (needle, errors))


class SchemaThreeGenerationTests(SmallWorldCase):
	def test_valid_world_and_manifest_shape(self) -> None:
		self.assertEqual(self.errors(), [])
		m = self.manifest()
		self.assertEqual(m["schema_version"], 3)
		self.assertEqual(m["terrain"]["layout"], {"min_region": [0, 0], "region_count": [2, 1]})
		self.assertEqual(m["terrain"]["region_locations"], [[0, 0], [1, 0]])
		self.assertEqual(len(m["payload_files"]), 3 + 3 * 2)
		self.assertEqual(wf.parse_json_bytes((self.gen / "objects.json").read_bytes())["schema_version"], 3)
		result = wf.validate_path(self.gen)
		self.assertTrue(result["valid"], result["errors"])

	def test_flat_helper_matches_the_vector_construction(self) -> None:
		m = self.manifest()
		other = self.tmp / "other"
		self.assertEqual(gf.write_flat_world(other, SMALL)["authored_content_hash"], m["authored_content_hash"], "deterministic")

	def test_legacy_layout_is_rejected_for_schema_3(self) -> None:
		m = self.manifest()
		m["terrain"]["layout"] = {"min_region": [-1, -1], "region_count": [2, 2]}
		self.write_manifest(m)
		self.assertRejected("schema 3 must not use the legacy 2x2 layout")

	def test_layout_tampering(self) -> None:
		cases = {
			"missing field 'layout'": lambda m: m["terrain"].pop("layout"),
			"unknown field": lambda m: m["terrain"]["layout"].update(extra=1),
			"two integers": lambda m: m["terrain"]["layout"].update(min_region=[0, 0.5]),
			"region_count": lambda m: m["terrain"]["layout"].update(region_count=[9, 1]),
			"min_region": lambda m: m["terrain"]["layout"].update(min_region=[-9, 0]),
		}
		for needle, edit in cases.items():
			with self.subTest(needle):
				m = self.manifest()
				edit(m)
				self.write_manifest(m)
				self.assertRejected(needle)
				gf.write_flat_world(self.gen, SMALL)

	def test_region_locations_mismatch(self) -> None:
		m = self.manifest()
		m["terrain"]["region_locations"] = [[1, 0], [0, 0]]
		self.write_manifest(m)
		self.assertRejected("terrain.region_locations")

	def test_missing_and_extra_region_files(self) -> None:
		(self.gen / "regions/r_1_0.control.u32le").unlink()
		self.assertRejected("missing file 'regions/r_1_0.control.u32le'")
		gf.write_flat_world(self.gen, SMALL)
		(self.gen / "regions/r_2_0.height.f32le").write_bytes(b"x")
		self.assertRejected("unexpected file 'regions/r_2_0.height.f32le'")

	def test_schema_2_manifest_with_layout_block_is_rejected(self) -> None:
		legacy = self.tmp / "legacy"
		shutil.copytree(FIXTURES / "flat", legacy)
		m = wf.parse_json_bytes((legacy / "manifest.json").read_bytes())
		m["terrain"]["layout"] = wf.layout_to_manifest(wf.LEGACY_LAYOUT)
		(legacy / "manifest.json").write_bytes(wf.dump_json(m))
		errors = wf.validate_generation(legacy)[1]
		self.assertTrue(any("unknown field 'layout'" in e for e in errors), errors)

	def test_objects_schema_must_match(self) -> None:
		self.reseal_payload("objects.json", wf.dump_json({"schema_version": 2, "objects": []}))
		self.assertRejected("objects.json has unknown schema_version")

	def test_object_count_limits_follow_the_manifest_schema(self) -> None:
		self.reseal_payload("objects.json", wf.dump_json({"schema_version": 3, "objects": [{}] * 50001}))
		self.assertRejected("objects.json has 50001 objects (max 50000)")
		legacy = self.tmp / "legacy"
		shutil.copytree(FIXTURES / "flat", legacy)
		(legacy / "objects.json").write_bytes(wf.dump_json({"schema_version": 2, "objects": [{}] * 2001}))
		errors = wf.validate_generation(legacy)[1]
		self.assertTrue(any("objects.json has 2001 objects (max 2000)" in e for e in errors), errors)

	def test_extent_comes_from_the_layout(self) -> None:
		inside = wf.make_object_record("11111111-1111-4111-8111-111111111111", "nature.rock.boulder_a", 1,
			[255.5, 0.0, 127.5], [0.0, 0.0, 0.0, 1.0], 1.0, "WORLD_FIXED", 0.0)
		cat = wf.load_trusted_catalog()
		self.assertEqual(wf.check_record_against_catalog(inside, cat["assets"], SMALL), [])
		self.assertTrue(wf.check_record_against_catalog(inside, cat["assets"]), "outside the legacy extent")
		scatter = wf.write_scatter([{"asset_id": "test.a", "asset_version": 1, "x": 200.0, "z": 50.0, "yaw_rad": 0.0, "scale": 1.0}])
		self.assertIsNotNone(wf.parse_scatter(scatter, 100000, SMALL)[0])
		self.assertIsNone(wf.parse_scatter(scatter)[0], "legacy extent rejects x = 200")
		paths = wf.write_paths([{"path_id": "33333333-3333-4333-8333-333333333333", "width_m": 2.0, "points": [(10.0, 10.0), (250.0, 120.0)]}])
		self.assertIsNotNone(wf.parse_paths(paths, SMALL)[0])
		self.assertIsNone(wf.parse_paths(paths)[0])

	def test_scatter_limit_is_per_schema(self) -> None:
		head = b"WPSC" + struct.pack("<III", 1, 0, 20001)
		self.assertIn("exceed the limit of 20000", wf.parse_scatter(head)[1])
		self.assertIn("truncated", wf.parse_scatter(head, 100000)[1])
		head = b"WPSC" + struct.pack("<III", 1, 0, 100001)
		self.assertIn("exceed the limit of 100000", wf.parse_scatter(head, 100000)[1])


def zip_of(entries: list[tuple[str, bytes]]) -> bytes:
	buf = io.BytesIO()
	with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
		for name, data in entries:
			info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
			info.compress_type = zipfile.ZIP_DEFLATED
			info.external_attr = 0o100644 << 16
			zf.writestr(info, data)
	return buf.getvalue()


class PackageEnvelopeTests(unittest.TestCase):
	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_layout_pkg_"))
		self.region = b"\0" * wf.REGION_MAP_BYTES

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def entries(self, layout: wf.Layout) -> list[tuple[str, bytes]]:
		fixed = [("manifest.json", b"{}"), ("objects.json", b"{}"), ("scatter.bin", b"WPSC"), ("paths.bin", b"WPPA")]
		return fixed + [(p, self.region) for p in wf.payload_paths(layout) if p.startswith("regions/")]

	def errors(self, entries: list[tuple[str, bytes]]) -> list[str]:
		path = self.tmp / "p.worldpoc"
		path.write_bytes(zip_of(entries))
		return wf.inspect_zip(path)[1]

	def assertRejected(self, entries: list[tuple[str, bytes]], needle: str) -> None:
		errors = self.errors(entries)
		self.assertTrue(any(needle in e for e in errors), "expected %r in %r" % (needle, errors))

	def test_km1_layout_passes_inspection(self) -> None:
		entries = [("regions/", b"")] + self.entries(wf.KM1_LAYOUT)
		self.assertEqual(len(entries), 197)
		self.assertEqual(self.errors(entries), [])

	def test_region_name_grammar(self) -> None:
		base = self.entries(wf.LEGACY_LAYOUT)
		for name in ("r_8_0", "r_0_8", "r_-9_0", "r_0_-9"):
			self.assertRejected(base + [("regions/%s.height.f32le" % name, self.region)], "outside [-8, 7]")
		for name in ("r_+1_0", "r_01_0", "r_-0_0", "r_1_00", "r_ 1_0", "R_1_0", "r_1", "r_1_0_0"):
			self.assertRejected(base + [("regions/%s.height.f32le" % name, self.region)], "unknown entry")
		self.assertRejected(base + [("regions/r_1_0.height.f32le\n", self.region)], "unknown entry")
		self.assertEqual(wf.parse_region_name("regions/r_-8_7.color.rgba8"), ((-8, 7), "color.rgba8"))
		self.assertEqual(self.errors(self.entries(((-8, -8), (1, 1)))), [])

	def test_incomplete_region_triples(self) -> None:
		base = self.entries(wf.LEGACY_LAYOUT)
		self.assertRejected(base + [("regions/r_1_1.height.f32le", self.region)], "missing entry 'regions/r_1_1.control.u32le'")
		self.assertRejected([e for e in base if e[0] != "regions/r_0_0.color.rgba8"], "missing entry 'regions/r_0_0.color.rgba8'")

	def test_region_size_is_exact(self) -> None:
		base = self.entries(wf.LEGACY_LAYOUT) + [("regions/r_3_3.height.f32le", b"\0")]
		self.assertRejected(base, "expected 262144")

	def test_entry_count_over_the_envelope(self) -> None:
		extras = [("x%d" % i, b"") for i in range(198 - 16)]
		self.assertRejected(self.entries(wf.LEGACY_LAYOUT) + extras, "archive has 198 entries, allowed 1..197")

	def test_oversize_entries_use_the_envelope(self) -> None:
		base = self.entries(wf.LEGACY_LAYOUT)
		over = [(n, b"\0" * (4 * 1024 * 1024 + 1) if n == "scatter.bin" else d) for n, d in base]
		self.assertRejected(over, "limit 4194304")
		ok = [(n, b"\0" * (600 * 1024) if n == "scatter.bin" else d) for n, d in base]
		self.assertEqual(self.errors(ok), [], "600 KiB scatter passes inspection (schema 2 limit applies after extraction)")

	def test_km1_package_round_trip_validates(self) -> None:
		gen = self.tmp / "km1"
		manifest = gf.write_flat_world(gen, wf.KM1_LAYOUT)
		self.assertEqual(manifest["authored_content_hash"], KM1_FLAT_VECTOR)
		self.assertEqual(manifest["schema_version"], 3)
		self.assertEqual(len(manifest["payload_files"]), 3 + 3 * 64)
		pkg = self.tmp / "km1.worldpoc"
		wf.write_package(gen, pkg)
		result = wf.validate_path(pkg)
		self.assertTrue(result["valid"], result["errors"][:3])
		self.assertEqual(result["authored_content_hash"], KM1_FLAT_VECTOR)


if __name__ == "__main__":
	unittest.main()
