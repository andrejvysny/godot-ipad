"""Known vectors shared with the GDScript side (ControlCodec, ObjectRecord.f64_hex, CanonicalEncoder)."""
from __future__ import annotations

import hashlib
import json
import math
import struct
import unittest

from wp_test_support import FIXTURES, boulder_record, scatter_instance, uuid_n, wf


class F64Tests(unittest.TestCase):
	def test_known_vector(self) -> None:
		self.assertEqual(wf.f64_hex(0.1), "9a9999999999b93f")

	def test_round_trip_and_malformed(self) -> None:
		for v in (0.0, -0.0, 1.3, -7.3, 1e-300, 123456.789):
			self.assertEqual(struct.pack("<d", wf.f64_from_hex(wf.f64_hex(v))), struct.pack("<d", v))
		for bad in ("9a9999999999b93", "zz9999999999b93f", None, 12, "9a9999999999b93f00"):
			self.assertTrue(math.isnan(wf.f64_from_hex(bad)), bad)


class ControlTests(unittest.TestCase):
	def test_default_control_is_rule_layer_only(self) -> None:
		self.assertEqual(wf.DEFAULT_CONTROL, 0x00000001)
		d = wf.control_decode(wf.DEFAULT_CONTROL)
		self.assertEqual((d["base_id"], d["overlay_id"], d["blend"], d["auto"]), (0, 0, 0, True))

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
		self.assertTrue(wf.control_is_supported((3 << 27) | (2 << 22)))  # rock and sand slots exist in schema 2
		self.assertFalse(wf.control_is_supported(4 << 27))
		self.assertFalse(wf.control_is_supported(4 << 22))
		# Float-NaN bit patterns always carry base id >= 15, so they fail on material ids, not as NaN.
		self.assertFalse(wf.control_is_supported(0x7FC00001))


# Recorded SHA-256 results of the streams assembled in HashTests (see test_authored_hash_v2_known_answer).
VECTOR_FULL = "0e403477ab15b4f678efa9cd6108cc4c0039c81ce6be435a9dfd7ae632b032e9"
VECTOR_EMPTY = "9b4c0b395b516ff34b003ca4a4bbff23e539817cf784fdc8d2024855393706e5"


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
		for name in ("flat", "gentle_hills", "stress_100"):
			gen, errors = wf.validate_generation(FIXTURES / name)
			self.assertEqual(errors, [], name)
			m = json.loads((FIXTURES / name / "manifest.json").read_text())
			self.assertEqual(gen.authored_hash, m["authored_content_hash"], name)

	def test_fixture_authored_hash_regression_pins(self) -> None:
		# Pins produced by this implementation (not yet cross-checked against CanonicalEncoder in Godot).
		pins = {"flat": "be76f01f80f2ae7abbc40272b7030fa9ba2b6da22666e2aa9b9137b5e66fd1dd",
			"gentle_hills": "6c38b11259c44ec7c0df2380a141d5f4c679bd65ac419761386e3c4b8749ec9a",
			"stress_100": "13f8636ba6481e89b9c3f5fe19b849fe8a4208fa54c262c9090dfd9534b5acff"}
		for name, expected in pins.items():
			gen, errors = wf.validate_generation(FIXTURES / name)
			self.assertEqual(errors, [], name)
			self.assertEqual(gen.authored_hash, expected, name)

	def _vector_inputs(self) -> tuple:  # type: ignore[type-arg]
		catalog = {"id": "test_cat", "version": 2, "sha256": "11" * 32}
		rules = {"rock_enabled": False, "rock_slope_deg": 45, "sand_enabled": True, "sand_height_dm": -12}
		digests = {}
		for i, loc in enumerate(wf.REGION_LOCATIONS):
			digests[loc] = tuple(hashlib.sha256(b"%s%d" % (kind, i)).digest() for kind in (b"height", b"control", b"color"))
		scatter = wf.write_scatter([scatter_instance("test.b", 3, 1.5, -2.5, 0.5, 1.25, 1),
			scatter_instance("test.a", 1, -128.0, 127.5, -3.14, 0.5)])
		paths = wf.write_paths([{"path_id": uuid_n(7), "width_m": 2.5, "points": [(0.0, 0.0), (10.5, -4.25)]}])
		rec = wf.parse_object_record(boulder_record(uuid_n(1), y=3.1, offset=-0.2))[0]
		return catalog, rules, digests, scatter, paths, rec

	def test_authored_hash_v2_known_answer(self) -> None:
		# Derivation: the stream of docs/world-format.md section 7 is assembled below with plain struct
		# packing (independent of worldpoc_values._Stream); the SHA-256 of that stream was computed once
		# and recorded as the literal. Any change to field order, widths or magic changes it.
		catalog, rules, digests, scatter, paths, rec = self._vector_inputs()
		self.assertEqual(len(scatter), 4 + 4 + 4 + (4 + 6 + 4) * 2 + 4 + 20 * 2)
		def s(v: str) -> bytes:
			b = v.encode()
			return struct.pack("<I", len(b)) + b
		stream = b"WPOC-AUTHORED-V2\n" + struct.pack("<I", 2) + s("test_cat") + struct.pack("<I", 2) + s("11" * 32)
		stream += struct.pack("<dI", 0.5, 256)
		stream += struct.pack("<BiBi", 0, 45, 1, -12)
		stream += struct.pack("<I", 4)
		for loc in sorted(wf.REGION_LOCATIONS, key=lambda l: (l[1], l[0])):
			stream += struct.pack("<ii", *loc) + b"".join(digests[loc])
		stream += hashlib.sha256(scatter).digest() + hashlib.sha256(paths).digest()
		stream += struct.pack("<I", 1) + s(rec["object_id"]) + s(rec["asset_id"]) + struct.pack("<I", 1)
		stream += struct.pack("<3d", *rec["position"]) + struct.pack("<4d", *rec["rotation_xyzw"])
		stream += struct.pack("<d", rec["uniform_scale"]) + s("FOLLOW_TERRAIN") + struct.pack("<d", rec["height_offset_m"])
		stream += s("MANUAL") + s("")
		expected = hashlib.sha256(stream).hexdigest()
		got = wf.authored_hash(catalog, rules, digests, scatter, paths, [rec])
		self.assertEqual(got, expected)
		self.assertEqual(got, VECTOR_FULL)

	def test_authored_hash_v2_empty_world_vector(self) -> None:
		catalog, rules, digests, _, _, _ = self._vector_inputs()
		got = wf.authored_hash(catalog, wf.DEFAULT_RULES, digests, wf.write_scatter([]), wf.write_paths([]), [])
		self.assertEqual(got, VECTOR_EMPTY)

	def test_authored_hash_covers_each_new_input(self) -> None:
		catalog, rules, digests, scatter, paths, rec = self._vector_inputs()
		base = wf.authored_hash(catalog, rules, digests, scatter, paths, [rec])
		variants = [
			wf.authored_hash(catalog, dict(rules, rock_enabled=True), digests, scatter, paths, [rec]),
			wf.authored_hash(catalog, dict(rules, rock_slope_deg=46), digests, scatter, paths, [rec]),
			wf.authored_hash(catalog, dict(rules, sand_enabled=False), digests, scatter, paths, [rec]),
			wf.authored_hash(catalog, dict(rules, sand_height_dm=-11), digests, scatter, paths, [rec]),
			wf.authored_hash(catalog, rules, digests, wf.write_scatter([]), paths, [rec]),
			wf.authored_hash(catalog, rules, digests, scatter, wf.write_paths([]), [rec]),
			wf.authored_hash(catalog, rules, {**digests, (0, 0): (b"x" * 32,) + digests[(0, 0)][1:]}, scatter, paths, [rec]),
			wf.authored_hash(catalog, rules, {**digests, (0, 0): digests[(0, 0)][:2] + (b"x" * 32,)}, scatter, paths, [rec]),
		]
		self.assertEqual(len(set(variants + [base])), len(variants) + 1)

	def test_negative_zero_is_canonical(self) -> None:
		cat = {"id": "c", "version": 1, "sha256": "0" * 64}
		a = wf.parse_object_record(boulder_record("00000000-0000-4000-8000-000000000001", x=0.0))[0]
		b = wf.parse_object_record(boulder_record("00000000-0000-4000-8000-000000000001", x=-0.0))[0]
		args = (wf.DEFAULT_RULES, {}, b"", b"")
		self.assertEqual(wf.authored_hash(cat, *args, [a]), wf.authored_hash(cat, *args, [b]))


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
