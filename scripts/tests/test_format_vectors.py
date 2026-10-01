"""Known vectors shared with the GDScript side (ControlCodec, ObjectRecord.f64_hex, CanonicalEncoder)."""
from __future__ import annotations

import hashlib
import json
import math
import struct
import unittest

from wp_test_support import FIXTURES, boulder_record, wf


class F64Tests(unittest.TestCase):
	def test_known_vector(self) -> None:
		self.assertEqual(wf.f64_hex(0.1), "9a9999999999b93f")

	def test_round_trip_and_malformed(self) -> None:
		for v in (0.0, -0.0, 1.3, -7.3, 1e-300, 123456.789):
			self.assertEqual(struct.pack("<d", wf.f64_from_hex(wf.f64_hex(v))), struct.pack("<d", v))
		for bad in ("9a9999999999b93", "zz9999999999b93f", None, 12, "9a9999999999b93f00"):
			self.assertTrue(math.isnan(wf.f64_from_hex(bad)), bad)


class ControlTests(unittest.TestCase):
	def test_grass_value(self) -> None:
		self.assertEqual(wf.GRASS_VALUE, 0x00400000)
		d = wf.control_decode(wf.GRASS_VALUE)
		self.assertEqual((d["base_id"], d["overlay_id"], d["blend"], d["auto"]), (0, 1, 0, False))

	def test_known_vector_decode(self) -> None:
		# Same vector as app/tests/unit/test_control_codec.gd.
		v = (3 << 27) | (17 << 22) | (200 << 14) | (5 << 10) | (6 << 7) | (1 << 4) | 0x2 | 0x1
		d = wf.control_decode(v)
		self.assertEqual((d["base_id"], d["overlay_id"], d["blend"], d["auto"], d["hole"]), (3, 17, 200, True, False))
		self.assertEqual(d["other_bits"], (5 << 10) | (6 << 7) | (1 << 4) | 0x2)

	def test_encode_paint_preserves_other_bits(self) -> None:
		p = wf.control_encode_paint(0xFFFFFFFF, 128)
		d = wf.control_decode(p)
		self.assertEqual((d["base_id"], d["overlay_id"], d["blend"], d["auto"]), (0, 1, 128, False))
		others = ~wf.PAINT_OWNED_MASK & 0xFFFFFFFF
		self.assertEqual(p & others, others)
		self.assertEqual(wf.control_encode_paint(0, 300) >> 14 & 0xFF, 255)

	def test_supported_layout_is_uint32(self) -> None:
		self.assertTrue(wf.control_is_supported(wf.GRASS_VALUE | (0xF << 3) | 0x7))  # reserved/flags opaque
		self.assertTrue(wf.control_is_supported((1 << 27) | (1 << 22) | (255 << 14)))
		self.assertFalse(wf.control_is_supported(2 << 27))
		self.assertFalse(wf.control_is_supported(2 << 22))
		# Float-NaN bit patterns always carry base id >= 15, so they fail on material ids, not as NaN.
		self.assertFalse(wf.control_is_supported(0x7FC00001))


class HashTests(unittest.TestCase):
	def test_catalog_hash_recomputed_independently(self) -> None:
		raw = (wf.APP_DIR / "assets" / "catalog.json").read_bytes()
		cat = json.loads(raw)
		files = sorted({a[k] for a in cat["assets"] for k in ("preview_scene", "scatter_mesh") if a[k] is not None})
		stream = b"WPOC-CATALOG-V1\n" + struct.pack("<I", 12) + b"catalog.json" + hashlib.sha256(raw).digest()
		stream += struct.pack("<I", len(files))
		for res in files:
			stream += struct.pack("<I", len(res)) + res.encode() + hashlib.sha256(
				(wf.APP_DIR / res[len("res://"):]).read_bytes()).digest()
		expected = hashlib.sha256(stream).hexdigest()
		self.assertEqual(wf.catalog_sha256(), expected)
		self.assertEqual(json.loads((FIXTURES / "gentle_hills" / "manifest.json").read_text())["catalog"]["sha256"], expected)

	def test_fixture_authored_hashes_match_manifests(self) -> None:
		for name in ("flat", "gentle_hills"):
			gen, errors = wf.validate_generation(FIXTURES / name)
			self.assertEqual(errors, [], name)
			m = json.loads((FIXTURES / name / "manifest.json").read_text())
			self.assertEqual(gen.authored_hash, m["authored_content_hash"], name)

	def test_cross_language_object_vector(self) -> None:
		# Computed by CanonicalEncoder.authored_hash in Godot 4.7.2 for the flat grass world plus this
		# record (decimal fields as written by Godot's JSON.stringify, exact values from f64le).
		gen, _ = wf.read_generation_dir(FIXTURES / "flat")
		digests = {l: (hashlib.sha256(gen.heights[l]).digest(), hashlib.sha256(gen.controls[l]).digest())
			for l in wf.REGION_LOCATIONS}
		d = boulder_record("00000000-0000-4000-8000-000000000001", y=3.1, offset=-0.2)
		d["rotation_xyzw"] = [0.0, 0.342897807455451, 0.0, 0.939372712847379]  # Godot's 15-digit decimals
		rec, err = wf.parse_object_record(d)
		self.assertEqual(err, "")
		catalog = {"id": "poc_nature", "version": 1,
			"sha256": "a4cfbc629fa7ef9c1d2585cf3881011e385b175993e8d2508b28e5317056e78d"}
		self.assertEqual(wf.authored_hash(catalog, digests, [rec]),
			"18928e9ba96c419d8b6dfb1b977dd790acceb661d5187939251fbb4f0b41d1eb")

	def test_negative_zero_is_canonical(self) -> None:
		cat = {"id": "c", "version": 1, "sha256": "0" * 64}
		a = wf.parse_object_record(boulder_record("00000000-0000-4000-8000-000000000001", x=0.0))[0]
		b = wf.parse_object_record(boulder_record("00000000-0000-4000-8000-000000000001", x=-0.0))[0]
		self.assertEqual(wf.authored_hash(cat, {}, [a]), wf.authored_hash(cat, {}, [b]))


class SampleHeightTests(unittest.TestCase):
	def setUp(self) -> None:
		gen, _ = wf.read_generation_dir(FIXTURES / "gentle_hills")
		self.regions = wf.load_region_arrays(gen.heights)

	def test_matches_godot_values(self) -> None:
		# Values printed by WorldDocument.sample_height in Godot 4.7.2 on the same bytes.
		self.assertAlmostEqual(wf.sample_height(self.regions, 20.0, 20.0), 5.3203444480896, places=12)
		self.assertAlmostEqual(wf.sample_height(self.regions, -60.25, -50.1), 11.9366585731506, places=12)
		self.assertAlmostEqual(wf.sample_height(self.regions, 127.5, 127.5), 0.0054818908684, places=12)

	def test_outside_is_nan(self) -> None:
		for x, z in ((128.0, 0.0), (0.0, -128.01), (-200.0, 5.0)):
			self.assertTrue(math.isnan(wf.sample_height(self.regions, x, z)))
		self.assertFalse(math.isnan(wf.sample_height(self.regions, -128.0, -128.0)))

	def test_seam_is_continuous(self) -> None:
		left = wf.height_at_sample(self.regions, -1, 10)
		right = wf.height_at_sample(self.regions, 0, 10)
		mid = wf.sample_height(self.regions, -0.25, 5.0)
		self.assertAlmostEqual(mid, (left + right) / 2.0, places=9)


if __name__ == "__main__":
	unittest.main()
