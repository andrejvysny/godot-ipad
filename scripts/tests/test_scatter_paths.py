"""scatter.bin / paths.bin (world-format §5, §6): round trips, canonical order, hostile input, catalog rules."""
from __future__ import annotations

import hashlib
import json
import math
import shutil
import struct
import tempfile
import unittest
from pathlib import Path
from typing import Any

from wp_test_support import FIXTURES, boulder_record, scatter_instance, uuid_n, wf, write_test_catalog

EMPTY_SCATTER = b"WPSC" + struct.pack("<III", 1, 0, 0)
EMPTY_PATHS = b"WPPA" + struct.pack("<II", 1, 0)


def path(n: int, points: list[tuple[float, float]] | None = None, width: float = 2.0) -> dict[str, Any]:
	return {"path_id": uuid_n(n), "width_m": width, "points": points or [(0.0, 0.0), (5.0, 5.0)]}


def raw_scatter(assets: list[tuple[str, int]], instances: list[tuple[int, int, float, float, float, float]]) -> bytes:
	out = b"WPSC" + struct.pack("<II", 1, len(assets))
	for a, v in assets:
		out += struct.pack("<I", len(a)) + a.encode() + struct.pack("<I", v)
	out += struct.pack("<I", len(instances))
	for i in instances:
		out += struct.pack("<HHffff", *i)
	return out


def raw_path(path_id: str, width: float, points: list[tuple[float, float]], count: int | None = None) -> bytes:
	out = struct.pack("<I", len(path_id)) + path_id.encode() + struct.pack("<fI", width, len(points) if count is None else count)
	return out + b"".join(struct.pack("<ff", *p) for p in points)


def raw_paths(*paths: bytes) -> bytes:
	return b"WPPA" + struct.pack("<II", 1, len(paths)) + b"".join(paths)


A1 = ("test.a", 1)


class ScatterParserTests(unittest.TestCase):
	def assertScatterError(self, data: bytes, needle: str) -> None:
		parsed, err = wf.parse_scatter(data)
		self.assertIsNone(parsed)
		self.assertIn(needle, err)

	def test_empty_file_layout(self) -> None:
		self.assertEqual(wf.write_scatter([]), EMPTY_SCATTER)
		self.assertEqual(len(EMPTY_SCATTER), 16)
		parsed, err = wf.parse_scatter(EMPTY_SCATTER)
		self.assertEqual((err, parsed), ("", {"assets": [], "instances": []}))

	def test_round_trip_is_byte_exact(self) -> None:
		insts = [scatter_instance("test.b", 3, 1.5, -2.5, 0.5, 1.25, 1), scatter_instance("test.a", 1, -128.0, 127.5, -3.14, 0.5),
			scatter_instance("test.b", 3, 0.1, 0.2, 3.1416, 2.0)]
		data = wf.write_scatter(insts)
		parsed, err = wf.parse_scatter(data)
		self.assertEqual(err, "")
		self.assertEqual([i["asset_id"] for i in parsed["instances"]], ["test.b", "test.a", "test.b"])  # order kept
		self.assertEqual(parsed["assets"], [("test.a", 1), ("test.b", 3)])
		self.assertEqual(wf.write_scatter(parsed["instances"]), data)
		self.assertEqual(len(data), 4 + 4 + 4 + (4 + 6 + 4) * 2 + 4 + 20 * 3)
		# f32 values come back widened exactly; 0.1 is not representable and is rounded once.
		self.assertEqual(parsed["instances"][2]["x"], struct.unpack("<f", struct.pack("<f", 0.1))[0])

	def test_table_is_minimal_and_sorted_bytewise(self) -> None:
		data = wf.write_scatter([scatter_instance("b.x", 1), scatter_instance("B.y", 1), scatter_instance("b.x", 1)])
		parsed, _ = wf.parse_scatter(data)
		self.assertEqual([a for a, _ in parsed["assets"]], ["B.y", "b.x"])  # uppercase sorts first
		self.assertEqual(struct.unpack_from("<HH", data, len(data) - 60)[0], 1)  # first instance is b.x -> index 1

	def test_writer_rejects_two_versions_of_one_asset(self) -> None:
		with self.assertRaises(ValueError):
			wf.write_scatter([scatter_instance("test.a", 1), scatter_instance("test.a", 2)])

	def test_hostile_structures(self) -> None:
		good = raw_scatter([A1], [(0, 0, 1.0, 1.0, 0.0, 1.0)])
		self.assertEqual(wf.parse_scatter(good)[1], "")
		self.assertScatterError(b"WPXX" + good[4:], "bad magic")
		self.assertScatterError(good[:4] + struct.pack("<I", 2) + good[8:], "version 2")
		self.assertScatterError(good + b"\0", "trailing bytes")
		self.assertScatterError(good[:-1], "truncated")
		self.assertScatterError(b"WPS", "truncated")
		self.assertScatterError(b"", "truncated")
		self.assertScatterError(raw_scatter([A1], [(1, 0, 1.0, 1.0, 0.0, 1.0)]), "asset_index 1 is out of range")
		self.assertScatterError(raw_scatter([A1], [(0, 2, 1.0, 1.0, 0.0, 1.0)]), "unknown flag bits")
		self.assertScatterError(raw_scatter([A1], [(0, 0x8000, 1.0, 1.0, 0.0, 1.0)]), "unknown flag bits")
		self.assertEqual(wf.parse_scatter(raw_scatter([A1], [(0, 1, 1.0, 1.0, 0.0, 1.0)]))[1], "")

	def test_non_finite_and_extent_and_yaw(self) -> None:
		for bad in (math.nan, math.inf, -math.inf):
			for slot in range(4):
				vals = [1.0, 1.0, 0.0, 1.0]
				vals[slot] = bad
				self.assertScatterError(raw_scatter([A1], [(0, 0, *vals)]), "non-finite")
		for x, z in ((128.0, 0.0), (127.75, 0.0), (0.0, -128.5), (0.0, 127.51), (-200.0, 0.0)):
			self.assertScatterError(raw_scatter([A1], [(0, 0, x, z, 0.0, 1.0)]), "outside the world extent")
		for x, z in ((-128.0, -128.0), (127.5, 127.5)):
			self.assertEqual(wf.parse_scatter(raw_scatter([A1], [(0, 0, x, z, 0.0, 1.0)]))[1], "")
		for yaw in (3.15, -3.15, 4.0):
			self.assertScatterError(raw_scatter([A1], [(0, 0, 0.0, 0.0, yaw, 1.0)]), "yaw")
		for yaw in (3.1416, -3.1416, 0.0):
			self.assertEqual(wf.parse_scatter(raw_scatter([A1], [(0, 0, 0.0, 0.0, yaw, 1.0)]))[1], "")

	def test_table_rules(self) -> None:
		inst = [(0, 0, 0.0, 0.0, 0.0, 1.0), (1, 0, 0.0, 0.0, 0.0, 1.0)]
		self.assertEqual(wf.parse_scatter(raw_scatter([("a", 1), ("b", 1)], inst))[1], "")
		self.assertScatterError(raw_scatter([("b", 1), ("a", 1)], inst), "not sorted")
		self.assertScatterError(raw_scatter([("a", 1), ("a", 2)], inst), "duplicate asset_id")
		self.assertScatterError(raw_scatter([("a", 1), ("b", 1)], inst[:1]), "not referenced")
		self.assertScatterError(raw_scatter([("", 1)], inst[:1]), "empty asset_id")
		bad_utf8 = b"WPSC" + struct.pack("<II", 1, 1) + struct.pack("<I", 2) + b"\xff\xfe" + struct.pack("<II", 1, 0)
		self.assertScatterError(bad_utf8, "UTF-8")

	def test_count_limits(self) -> None:
		head = b"WPSC" + struct.pack("<II", 1, 1) + struct.pack("<I", 1) + b"a" + struct.pack("<I", 1)
		self.assertScatterError(head + struct.pack("<I", wf.SCATTER_MAX_INSTANCES + 1), "exceed the limit")
		self.assertScatterError(head + struct.pack("<I", 0xFFFFFFFF), "exceed the limit")
		self.assertScatterError(head + struct.pack("<I", 5), "truncated")  # count larger than the data
		insts = [(0, 0, 0.0, 0.0, 0.0, 1.0)] * wf.SCATTER_MAX_INSTANCES
		self.assertEqual(wf.parse_scatter(raw_scatter([A1], insts))[1], "")
		self.assertScatterError(b"WPSC" + struct.pack("<II", 1, 0xFFFFFFFF), "truncated")


class PathsParserTests(unittest.TestCase):
	def assertPathsError(self, data: bytes, needle: str) -> None:
		parsed, err = wf.parse_paths(data)
		self.assertIsNone(parsed)
		self.assertIn(needle, err)

	def test_empty_file_layout(self) -> None:
		self.assertEqual(wf.write_paths([]), EMPTY_PATHS)
		self.assertEqual(len(EMPTY_PATHS), 12)
		self.assertEqual(wf.parse_paths(EMPTY_PATHS), ([], ""))

	def test_round_trip_and_canonical_order(self) -> None:
		paths = [path(5, [(1.5, 2.5), (3.25, -4.75), (127.5, -128.0)], 3.5), path(2), path(9, width=6.0)]
		data = wf.write_paths(paths)
		parsed, err = wf.parse_paths(data)
		self.assertEqual(err, "")
		self.assertEqual([p["path_id"] for p in parsed], [uuid_n(2), uuid_n(5), uuid_n(9)])  # sorted by id
		self.assertEqual(wf.write_paths(parsed), data)
		self.assertEqual(wf.write_paths(list(reversed(paths))), data)
		self.assertEqual(parsed[1]["points"], [(1.5, 2.5), (3.25, -4.75), (127.5, -128.0)])

	def test_hostile_structures(self) -> None:
		ok = raw_path(uuid_n(1), 2.0, [(0.0, 0.0), (1.0, 1.0)])
		good = raw_paths(ok)
		self.assertEqual(wf.parse_paths(good)[1], "")
		self.assertPathsError(b"WPSC" + good[4:], "bad magic")
		self.assertPathsError(good[:4] + struct.pack("<I", 0) + good[8:], "version 0")
		self.assertPathsError(good + b"\0", "trailing bytes")
		self.assertPathsError(good[:-1], "truncated")
		self.assertPathsError(b"", "truncated")
		self.assertPathsError(raw_paths(raw_path("not-a-uuid", 2.0, [(0.0, 0.0), (1.0, 1.0)])), "not a lowercase UUID")
		self.assertPathsError(raw_paths(raw_path("0000000a-0000-4000-8000-00000000000A", 2.0, [(0.0, 0.0), (1.0, 1.0)])), "not a lowercase UUID")

	def test_order_and_uniqueness(self) -> None:
		a = raw_path(uuid_n(1), 2.0, [(0.0, 0.0), (1.0, 1.0)])
		b = raw_path(uuid_n(2), 2.0, [(0.0, 0.0), (1.0, 1.0)])
		self.assertEqual(wf.parse_paths(raw_paths(a, b))[1], "")
		self.assertPathsError(raw_paths(b, a), "not sorted")
		self.assertPathsError(raw_paths(a, a), "duplicate path_id")

	def test_width_points_and_extent(self) -> None:
		pts = [(0.0, 0.0), (1.0, 1.0)]
		for w in (0.99, 6.01, math.nan, math.inf, -1.0, 0.0):
			self.assertPathsError(raw_paths(raw_path(uuid_n(1), w, pts)), "width")
		for w in (1.0, 6.0):
			self.assertEqual(wf.parse_paths(raw_paths(raw_path(uuid_n(1), w, pts)))[1], "")
		self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, [(0.0, 0.0)])), "1 points")
		self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, [])), "0 points")
		many = [(float(i % 100), 0.0) for i in range(257)]
		self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, many)), "257 points")
		self.assertEqual(wf.parse_paths(raw_paths(raw_path(uuid_n(1), 2.0, many[:256])))[1], "")
		self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, pts, count=0xFFFFFFFF)), "points (allowed")
		self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, pts, count=5)), "truncated")
		for bad in (math.nan, math.inf):
			self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, [(0.0, bad), (1.0, 1.0)])), "not finite")
		for p in ((128.0, 0.0), (0.0, 127.75), (-128.01, 0.0)):
			self.assertPathsError(raw_paths(raw_path(uuid_n(1), 2.0, [p, (1.0, 1.0)])), "outside the world extent")

	def test_path_count_limit(self) -> None:
		self.assertPathsError(b"WPPA" + struct.pack("<II", 1, wf.PATHS_MAX_COUNT + 1), "exceed the limit")
		many = [raw_path(uuid_n(i), 2.0, [(0.0, 0.0), (1.0, 1.0)]) for i in range(wf.PATHS_MAX_COUNT)]
		self.assertEqual(wf.parse_paths(raw_paths(*many))[1], "")


class CatalogChecksTests(unittest.TestCase):
	@classmethod
	def setUpClass(cls) -> None:
		cls.tmp = Path(tempfile.mkdtemp(prefix="wp_cat_"))
		write_test_catalog(cls.tmp)
		cls.assets = wf.load_trusted_catalog(cls.tmp)["assets"]

	@classmethod
	def tearDownClass(cls) -> None:
		shutil.rmtree(cls.tmp, ignore_errors=True)

	def errors(self, insts: list[dict[str, Any]]) -> list[str]:
		parsed, err = wf.parse_scatter(wf.write_scatter(insts))
		self.assertEqual(err, "")
		return wf.check_scatter_catalog(parsed, self.assets)

	def test_valid(self) -> None:
		self.assertEqual(self.errors([scatter_instance("test.scatter.grass_a", 1), scatter_instance("test.scatter.pine_b", 3, scale=2.0)]), [])
		self.assertEqual(self.errors([]), [])

	def test_unknown_asset_and_wrong_version(self) -> None:
		self.assertIn("not in the trusted catalog", self.errors([scatter_instance("nope.x", 1)])[0])
		self.assertIn("does not match catalog version 3", self.errors([scatter_instance("test.scatter.pine_b", 1)])[0])

	def test_not_scatter_allowed(self) -> None:
		self.assertIn("not scatter-allowed", self.errors([scatter_instance(wf_boulder(), 1)])[0])

	def test_null_scatter_mesh(self) -> None:
		assets = {k: dict(v) for k, v in self.assets.items()}
		assets["test.scatter.grass_a"]["scatter_mesh"] = None
		parsed, _ = wf.parse_scatter(wf.write_scatter([scatter_instance("test.scatter.grass_a", 1)]))
		self.assertIn("not scatter-allowed", wf.check_scatter_catalog(parsed, assets)[0])

	def test_scale_range(self) -> None:
		for scale in (0.49, 2.01):
			self.assertIn("scale", self.errors([scatter_instance("test.scatter.grass_a", 1, scale=scale)])[0])
		for scale in (0.5, 2.0):
			self.assertEqual(self.errors([scatter_instance("test.scatter.grass_a", 1, scale=scale)]), [])


def wf_boulder() -> str:
	return "built.lodge.cabin_a"  # the one bundled asset that forbids scatter


class GenerationWithScatterTests(unittest.TestCase):
	"""Whole-generation validation against a temp app dir whose catalog has scatter-capable assets."""

	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_scatter_gen_"))
		self.app = self.tmp / "app"
		write_test_catalog(self.app)
		self.catalog = wf.load_trusted_catalog(self.app)
		src, errors = wf.validate_generation(FIXTURES / "flat")
		self.assertEqual(errors, [])
		self.flat = src

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def write(self, scatter: list[dict[str, Any]], paths: list[dict[str, Any]], objects: list[dict[str, Any]] | None = None,
			rules: dict[str, Any] | None = None) -> Path:
		out = self.tmp / "gen"
		shutil.rmtree(out, ignore_errors=True)
		cat = self.catalog
		wf.write_generation(out, {
			"world_id": "0f1a7000-0000-4000-8000-0000000000aa", "document_revision": 5,
			"created_with": {"godot": "g", "terrain3d": "t", "world_painter": "w"},
			"catalog": {"id": cat["id"], "version": cat["version"], "sha256": cat["sha256"]},
			"heights": self.flat_bytes("heights"), "controls": self.flat_bytes("controls"), "colors": self.flat_bytes("colors"),
			"objects": objects or [], "scatter": scatter, "paths": paths, "rules": rules or dict(wf.DEFAULT_RULES)})
		return out

	def flat_bytes(self, kind: str) -> dict[tuple[int, int], bytes]:
		if kind == "colors":
			return {l: self.flat.colors[l] for l in wf.REGION_LOCATIONS}
		return {l: getattr(self.flat, kind)[l] for l in wf.REGION_LOCATIONS}

	def test_valid_world_with_scatter_paths_and_custom_rules(self) -> None:
		rules = {"rock_enabled": False, "rock_slope_deg": 55, "sand_enabled": True, "sand_height_dm": 12}
		gen = self.write([scatter_instance("test.scatter.pine_b", 3, 10.0, 20.0, scale=1.5, flags=1),
			scatter_instance("test.scatter.grass_a", 1)], [path(3), path(1)], [boulder_record(uuid_n(1))], rules)
		g, errors = wf.validate_generation(gen, self.app)
		self.assertEqual(errors, [])
		self.assertEqual(g.rules, rules)
		self.assertEqual(len(g.scatter["instances"]), 2)
		self.assertEqual([p["path_id"] for p in g.paths], [uuid_n(1), uuid_n(3)])
		result = wf.validate_path(gen, self.app)
		self.assertTrue(result["valid"], result["errors"])
		manifest = json.loads((gen / "manifest.json").read_text())
		self.assertEqual(manifest["terrain"]["rules"], rules)
		self.assertEqual(manifest["authored_content_hash"], g.authored_hash)

	def test_hash_changes_with_scatter_and_paths(self) -> None:
		a = wf.validate_generation(self.write([], []), self.app)[0].authored_hash
		b = wf.validate_generation(self.write([scatter_instance("test.scatter.grass_a", 1)], []), self.app)[0].authored_hash
		c = wf.validate_generation(self.write([], [path(1)]), self.app)[0].authored_hash
		self.assertEqual(len({a, b, c}), 3)

	def test_bundled_catalog_rejects_scatter_for_non_scatter_assets(self) -> None:
		gen = self.write([], [])
		(gen / "scatter.bin").write_bytes(wf.write_scatter([scatter_instance("built.lodge.cabin_a", 1)]))
		m = json.loads((gen / "manifest.json").read_text())
		for e in m["payload_files"]:
			data = (gen / e["path"]).read_bytes()
			e["bytes"], e["sha256"] = len(data), hashlib.sha256(data).hexdigest()
		(gen / "manifest.json").write_bytes(wf.dump_json(m))
		errors = wf.validate_generation(gen, self.app)[1]
		self.assertTrue(any("not scatter-allowed" in e for e in errors), errors)

	def test_corrupt_scatter_inside_generation(self) -> None:
		gen = self.write([scatter_instance("test.scatter.grass_a", 1)], [])
		(gen / "scatter.bin").write_bytes((gen / "scatter.bin").read_bytes() + b"\0")
		errors = wf.validate_generation(gen, self.app)[1]
		self.assertTrue(any("scatter.bin" in e and "trailing bytes" in e for e in errors), errors)
		self.assertTrue(any("sha256 mismatch" in e for e in errors), errors)


if __name__ == "__main__":
	unittest.main()
