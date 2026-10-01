"""Every generation rejection rule (world-format §3, §4, §7; spec IO-07, IO-09)."""
from __future__ import annotations

import struct
import math

from wp_test_support import GenerationTestCase, boulder_record, uuid_n, wf

REGION = (0, 0)


class ValidGenerationTests(GenerationTestCase):
	def test_fixture_copy_is_valid(self) -> None:
		self.assertEqual(self.errors(), [])

	def test_objects_valid_and_grounding_is_warning_only(self) -> None:
		self.write_objects([boulder_record(uuid_n(1)), boulder_record(uuid_n(2), y=0.5)])
		self.reseal()
		gen, errors = wf.validate_generation(self.gen)
		self.assertEqual(errors, [])
		warnings = wf.grounding_report(gen)
		self.assertEqual(len(warnings), 1)
		self.assertIn(uuid_n(2), warnings[0])

	def test_control_other_bits_are_opaque(self) -> None:
		value = wf.GRASS_VALUE | (0xF << 3) | (0x7 << 7) | 0x7  # reserved, uv scale, flags
		(self.gen / wf.control_path(REGION)).write_bytes(struct.pack("<I", value) * wf.REGION_SAMPLE_COUNT)
		self.reseal()
		self.assertEqual(self.errors(), [])

	def test_hole_grounding_is_no_surface_without_mutating_payload(self) -> None:
		self.write_objects([boulder_record(uuid_n(1), x=-0.25, z=-0.25)])
		path = self.gen / wf.control_path((-1, -1))
		data = bytearray(path.read_bytes())
		struct.pack_into("<I", data, (255 * 256 + 255) * 4, wf.GRASS_VALUE | wf.HOLE_BIT)
		path.write_bytes(data)
		self.reseal()
		gen, errors = wf.validate_generation(self.gen)
		self.assertEqual(errors, [])
		before = path.read_bytes()
		self.assertIn("no terrain sample", wf.grounding_report(gen)[0])
		regions = wf.load_region_arrays(gen.heights)
		self.assertTrue(math.isnan(wf.sample_height(regions, -0.001, -0.001, gen.controls)))
		self.assertFalse(math.isnan(wf.sample_height(regions, 0.0, 0.0, gen.controls)))
		self.assertEqual(path.read_bytes(), before)


class TerrainRejectionTests(GenerationTestCase):
	def _set_height(self, index: int, value: float) -> None:
		path = self.gen / wf.height_path(REGION)
		data = bytearray(path.read_bytes())
		data[index * 4:index * 4 + 4] = struct.pack("<f", value)
		path.write_bytes(bytes(data))
		self.reseal()

	def test_nan_height(self) -> None:
		self._set_height(77, float("nan"))
		self.assertRejected("not finite")

	def test_inf_height(self) -> None:
		self._set_height(0, float("inf"))
		self.assertRejected("not finite")

	def test_height_above_limit(self) -> None:
		self._set_height(5, 65.0)
		self.assertRejected("height 65.0")

	def test_height_below_limit(self) -> None:
		self._set_height(5, -32.5)
		self.assertRejected("height -32.5")

	def test_wrong_byte_length(self) -> None:
		path = self.gen / wf.height_path(REGION)
		path.write_bytes(path.read_bytes()[:-4])
		self.reseal()
		self.assertRejected("has 262140 bytes")

	def test_unsupported_control_ids(self) -> None:
		path = self.gen / wf.control_path(REGION)
		data = bytearray(path.read_bytes())
		data[40:44] = struct.pack("<I", 2 << 27)
		path.write_bytes(bytes(data))
		self.reseal()
		self.assertRejected("unsupported material ids")

	def test_nan_looking_control_rejected_as_uint32_ids(self) -> None:
		path = self.gen / wf.control_path(REGION)
		data = bytearray(path.read_bytes())
		data[0:4] = struct.pack("<I", 0x7FC00001)
		path.write_bytes(bytes(data))
		self.reseal()
		self.assertRejected("control 0x7fc00001 uses unsupported material ids")

	def test_missing_file(self) -> None:
		(self.gen / wf.control_path(REGION)).unlink()
		self.assertRejected("missing file 'regions/r_0_0.control.u32le'")

	def test_extra_region_file(self) -> None:
		(self.gen / "regions" / "r_1_0.height.f32le").write_bytes(b"\0" * wf.REGION_MAP_BYTES)
		self.assertRejected("unexpected file 'regions/r_1_0.height.f32le'")

	def test_extra_region_in_manifest(self) -> None:
		m = self.manifest()
		m["terrain"]["region_locations"].append([1, 0])
		self.write_manifest(m)
		self.assertRejected("terrain.region_locations")

	def test_region_order(self) -> None:
		m = self.manifest()
		m["terrain"]["region_locations"].reverse()
		self.write_manifest(m)
		self.assertRejected("terrain.region_locations")

	def test_material_slots(self) -> None:
		m = self.manifest()
		m["terrain"]["material_slots"] = {"0": "dirt", "1": "grass"}
		self.write_manifest(m)
		self.assertRejected("terrain.material_slots")


class ManifestRejectionTests(GenerationTestCase):
	def test_placeholder_hash(self) -> None:
		for placeholder in ("0" * 64, "RECORD_ACTUAL_HASH", ""):
			m = self.manifest()
			m["payload_files"][1]["sha256"] = placeholder
			self.write_manifest(m)
			self.assertRejected("placeholder sha256")

	def test_payload_hash_mismatch(self) -> None:
		m = self.manifest()
		m["payload_files"][2]["sha256"] = "ab" * 32
		self.write_manifest(m)
		self.assertRejected("sha256 mismatch")

	def test_payload_bytes_mismatch(self) -> None:
		m = self.manifest()
		m["payload_files"][0]["bytes"] = 40
		self.write_manifest(m)
		self.assertRejected("bytes 40 != actual")

	def test_payload_list_incomplete(self) -> None:
		m = self.manifest()
		m["payload_files"].pop()
		self.write_manifest(m)
		self.assertRejected("payload_files must list exactly")

	def test_payload_list_unsorted(self) -> None:
		m = self.manifest()
		m["payload_files"].reverse()
		self.write_manifest(m)
		self.assertRejected("not sorted by path")

	def test_wrong_catalog_sha(self) -> None:
		m = self.manifest()
		m["catalog"]["sha256"] = "cd" * 32
		self.write_manifest(m)
		self.assertRejected("does not match trusted catalog")

	def test_unknown_catalog_id_and_version(self) -> None:
		m = self.manifest()
		m["catalog"]["id"] = "other_catalog"
		m["catalog"]["version"] = 2
		self.write_manifest(m)
		errors = self.assertRejected("unknown catalog id")
		self.assertTrue(any("catalog version 2" in e for e in errors))

	def test_unknown_schema(self) -> None:
		m = self.manifest()
		m["schema_version"] = 2
		self.write_manifest(m)
		self.assertRejected("unknown schema_version 2")

	def test_integral_float_accepted_fractional_rejected(self) -> None:
		m = self.manifest()
		m["document_revision"] = 3.0
		self.write_manifest(m)
		self.assertEqual(self.errors(), [])
		m["document_revision"] = 3.5
		self.write_manifest(m)
		self.assertRejected("document_revision")

	def test_uppercase_world_id(self) -> None:
		m = self.manifest()
		m["world_id"] = m["world_id"].upper()
		self.write_manifest(m)
		self.assertRejected("world_id")

	def test_nan_literal_json(self) -> None:
		raw = (self.gen / "manifest.json").read_bytes().replace(b'"document_revision": 0', b'"document_revision": NaN')
		(self.gen / "manifest.json").write_bytes(raw)
		self.assertRejected("not valid JSON")

	def test_authored_hash_mismatch(self) -> None:
		m = self.manifest()
		m["authored_content_hash"] = "ef" * 32
		self.write_manifest(m)
		self.assertRejected("authored_content_hash")


class ObjectRejectionTests(GenerationTestCase):
	def _objects(self, objects: list) -> None:
		self.write_objects(objects)
		self.reseal()

	def test_duplicate_object_id(self) -> None:
		self._objects([boulder_record(uuid_n(1)), boulder_record(uuid_n(1))])
		self.assertRejected("duplicate object_id")

	def test_unsorted_objects(self) -> None:
		self._objects([boulder_record(uuid_n(2)), boulder_record(uuid_n(1))])
		self.assertRejected("not sorted by object_id")

	def test_scale_outside_asset_limits(self) -> None:
		self._objects([boulder_record(uuid_n(1), scale=5.0)])
		self.assertRejected("uniform_scale 5.0 outside")

	def test_non_positive_scale(self) -> None:
		self._objects([boulder_record(uuid_n(1), scale=0.0)])
		self.assertRejected("positive finite")

	def test_height_offset_outside_limits(self) -> None:
		self._objects([boulder_record(uuid_n(1), offset=2.0)])
		self.assertRejected("height_offset_m 2.0 outside")

	def test_position_outside_extent(self) -> None:
		self._objects([boulder_record(uuid_n(1), x=127.75)])
		self.assertRejected("outside the world extent")

	def test_bad_f64le(self) -> None:
		rec = boulder_record(uuid_n(1))
		rec["f64le"]["uniform_scale"] = wf.f64_hex(1.4)
		self._objects([rec])
		self.assertRejected("f64le exact bits")
		rec = boulder_record(uuid_n(1))
		rec["f64le"]["position"][0] = "not-hex-value!!!"
		self._objects([rec])
		self.assertRejected("f64le exact bits")
		rec = boulder_record(uuid_n(1))
		del rec["f64le"]
		self._objects([rec])
		self.assertRejected("f64le exact-value block missing")

	def test_unknown_asset_and_version(self) -> None:
		rec = boulder_record(uuid_n(1))
		rec["asset_id"] = "nature.rock.unknown"
		self._objects([rec])
		self.assertRejected("not in the trusted catalog")
		rec = boulder_record(uuid_n(1))
		rec["asset_version"] = 2
		self._objects([rec])
		self.assertRejected("does not match catalog version")

	def test_enums_and_quaternion(self) -> None:
		rec = boulder_record(uuid_n(1))
		rec["grounding"] = "SNAP"
		self._objects([rec])
		self.assertRejected("grounding 'SNAP'")
		rec = boulder_record(uuid_n(1))
		rec["origin"] = "IMPORTED"
		self._objects([rec])
		self.assertRejected("origin 'IMPORTED'")
		rec = wf.make_object_record(uuid_n(1), "nature.rock.boulder_a", 1, [0.0, 0.0, 0.0], [0.0, 0.5, 0.0, 0.5],
			1.0, "WORLD_FIXED", 0.0)
		self._objects([rec])
		self.assertRejected("unit quaternion")

	def test_too_many_objects(self) -> None:
		self._objects([boulder_record(uuid_n(i)) for i in range(wf.MAX_OBJECTS + 1)])
		self.assertRejected("max 2000")


if __name__ == "__main__":
	import unittest
	unittest.main()
