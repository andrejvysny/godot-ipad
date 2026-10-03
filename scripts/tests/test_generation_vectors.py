"""Apply identities (ADR 0017 A2): invariants of the Python reference behind generation-vectors.json. The committed
file itself is covered by test_world_v4_format (generator output) and the GDScript test_snapshot_identity."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import world_v4_builders as B  # noqa: E402
import world_v4_generation_vectors as GV  # noqa: E402

PINS = {"installer_version": "1.0.0", "godot_build": "a", "terrain3d_build": "b", "assetstudio_pin": "c", "world_painter_pin": "d"}
H = "ab" * 32


class GenerationVectorTests(unittest.TestCase):
	def test_snapshot_hash_ignores_insertion_order_and_uses_code_point_order(self) -> None:
		a = {"manifest.json": H, "regions/r_-1_-1.height.f32le": H, "regions/r_0_0.height.f32le": "cd" * 32}
		b = dict(reversed(list(a.items())))
		self.assertEqual(GV.snapshot_hash(a), GV.snapshot_hash(b))
		self.assertNotEqual(GV.snapshot_hash(a), GV.snapshot_hash({**a, "objects.json": H}))

	def test_every_generation_input_changes_the_id(self) -> None:
		base = GV.generation_id(H, H, PINS)
		self.assertEqual(len(base), 64)
		self.assertNotEqual(base, GV.generation_id("cd" * 32, H, PINS))
		self.assertNotEqual(base, GV.generation_id(H, "cd" * 32, PINS))
		for key in GV.PIN_KEYS:
			self.assertNotEqual(base, GV.generation_id(H, H, dict(PINS, **{key: PINS[key] + "x"})), key)

	def test_pins_are_length_prefixed_so_boundaries_matter(self) -> None:
		a = GV.generation_id(H, H, dict(PINS, godot_build="ab", terrain3d_build="c"))
		b = GV.generation_id(H, H, dict(PINS, godot_build="a", terrain3d_build="bc"))
		self.assertNotEqual(a, b)

	def test_profile_hash_is_over_canonical_json(self) -> None:
		p1 = {"b": 1, "a": ["x"]}
		p2 = {"a": ["x"], "b": 1}
		self.assertEqual(GV.profile_hash(p1), GV.profile_hash(p2))

	def test_committed_vectors_are_consistent(self) -> None:
		data = json.loads((B.FIXTURES_V4 / "generation-vectors.json").read_text())
		for g in data["generations"]:
			self.assertEqual(GV.generation_id(g["source_snapshot_hash"], g["consumer_profile_hash"], g["pins"]), g["generation_id"])
			self.assertEqual(g["directory_name"], g["generation_id"][:32])
		for s in data["snapshots"]:
			self.assertEqual(GV.snapshot_hash(s["digests"]), s["source_snapshot_hash"])


if __name__ == "__main__":
	unittest.main()
