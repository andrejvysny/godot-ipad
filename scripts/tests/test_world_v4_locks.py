"""Schema 4 lock primitives (ADR 0014 D3-D6): canonical bytes, dec(), binding_id, asset_key, in_range, lock grammar
and the vectors in contracts/world-painter/world-v4/fixtures/canonical-lock-vectors.json."""
from __future__ import annotations

import hashlib
import json
import unittest
from typing import Any

from wp_test_support import wf
import world_v4_builders as B
import worldpoc_lockcheck as lc
from worldpoc_locks import CanonicalError, asset_key, binding_id, bundled_binding, canonical_v1, dec, default_policy, in_range

VECTORS = json.loads((B.FIXTURES_V4 / "canonical-lock-vectors.json").read_text())
TRUSTED = wf.load_trusted_catalog()


class CanonicalTests(unittest.TestCase):
	def test_escaping_is_normative(self) -> None:
		short = {8: "\\b", 9: "\\t", 10: "\\n", 12: "\\f", 13: "\\r"}
		for c in range(1, 32):
			want = short.get(c, "\\u%04x" % c)
			self.assertEqual(canonical_v1({"s": chr(c)}), ('{"s":"%s"}' % want).encode(), c)
		self.assertEqual(canonical_v1({"s": '"\\/'}), b'{"s":"\\"\\\\/"}')
		self.assertEqual(canonical_v1({"s": "\x7f  "}), b'{"s":"\x7f\xe2\x80\xa8\xe2\x80\xa9"}')
		self.assertEqual(canonical_v1({"s": "á森\U0001f332"}), '{"s":"á森\U0001f332"}'.encode())

	def test_structure(self) -> None:
		self.assertEqual(canonical_v1({"b": [1, True, None], "a": {}}), b'{"a":{},"b":[1,true,null]}')
		self.assertEqual(canonical_v1({"\U0001f332": 1, "": 2}), '{"":2,"\U0001f332":1}'.encode(),
			"sorted by code point, not UTF-16 units")

	def test_rejections(self) -> None:
		for bad in (1.0, {"a": 0.5}, [1, [2.5]], {1: 2}, {"a": (1,)}, {"a": b"x"}, {"a": {1, 2}}, float("nan"), {"a": "\ud800"}):
			with self.assertRaises(CanonicalError, msg=repr(bad)):
				canonical_v1(bad)

	def test_vector_file_matches_implementation(self) -> None:
		self.assertIn("U+0000", VECTORS["note"])
		for v in VECTORS["canonical"]:
			self.assertEqual(canonical_v1(v["input"]).hex(), v["canonical_hex"], v["name"])
		self.assertGreaterEqual(len(VECTORS["canonical"]), 31 + 10)
		for v in VECTORS["reject_inputs"]:
			with self.assertRaises(CanonicalError, msg=v["name"]):
				canonical_v1(json.loads(v["json"]))
		for v in VECTORS["non_canonical_lock_bytes"]:
			data = bytes.fromhex(v["bytes_hex"])
			try:
				same = canonical_v1(wf.parse_json_bytes(data)) == data
			except (wf.FormatError, CanonicalError):
				same = False
			self.assertFalse(same, v["name"])


class DecimalTests(unittest.TestCase):
	def test_dec_edge_cases(self) -> None:
		cases = {0.8: "0.8", 1.25: "1.25", -0.2: "-0.2", 0.0: "0", -0.0: "0", 1e-7: "0", -1e-7: "0", 1e-6: "0.000001",
			3.0: "3", 100.0: "100", 0.30000000000000004: "0.3", 2.5000004: "2.5", 123.4567891: "123.456789", 10.0: "10"}
		for x, want in cases.items():
			self.assertEqual(dec(x), want, x)
		for item in VECTORS["dec"]:
			self.assertEqual(dec(float(item["input_json"])), item["expected"])

	def test_dec_output_matches_the_assetstudio_grammar(self) -> None:
		for x in (0.8, 1.25, -0.2, 0.75, 1.5, 2.0, -1.5, 0.3, 0.123456):
			self.assertRegex(dec(x), lc.DECIMAL_RE.pattern)

	def test_in_range_epsilon(self) -> None:
		self.assertTrue(in_range(0.3, 0.3, 3.0))
		self.assertTrue(in_range(0.3 - 1e-7, 0.3, 3.0))
		self.assertFalse(in_range(0.3 - 1e-5, 0.3, 3.0))
		self.assertTrue(in_range(3.0 + 3e-6, 0.3, 3.0), "eps scales with max(1, |bound|)")
		self.assertFalse(in_range(3.0 + 1e-4, 0.3, 3.0))
		self.assertTrue(in_range(-2.0 - 1.5e-6, -2.0, 3.0))


class IdentifierTests(unittest.TestCase):
	def test_binding_id_vectors(self) -> None:
		self.assertGreaterEqual(len(VECTORS["binding_ids"]), len(TRUSTED["assets"]) + 3)
		for v in VECTORS["binding_ids"]:
			body = {k: x for k, x in v["binding"].items() if k != "binding_id"}
			self.assertEqual(canonical_v1(body).hex(), v["body_canonical_hex"], v["name"])
			self.assertEqual(binding_id(v["binding"]), v["binding_id"], v["name"])
			expected = "b" + hashlib.sha256(b"WPBIND1\n" + canonical_v1(body)).hexdigest()[:32]
			self.assertEqual(v["binding_id"], expected)

	def test_every_catalog_asset_has_a_default_binding(self) -> None:
		for asset_id, asset in TRUSTED["assets"].items():
			b = bundled_binding(TRUSTED, asset_id)
			self.assertEqual(b["policy"], default_policy(asset))
			self.assertEqual(b["asset_version"], int(asset["version"]))
			self.assertEqual(b["catalog"], {"id": TRUSTED["id"], "version": int(TRUSTED["version"]), "sha256": TRUSTED["sha256"]})
			self.assertEqual(b["policy"]["scatter_allowed"], bool(asset["scatter_allowed"] and asset["scatter_mesh"] is not None))
			self.assertRegex(b["binding_id"], r"^b[0-9a-f]{32}$")

	def test_asset_key_follows_assetstudio(self) -> None:
		r = B.ref()
		raw = b"".join(len(p.encode()).to_bytes(4, "little") + p.encode()
			for p in (r["server_id"], r["library_id"], r["asset_id"], r["version_id"]))
		self.assertEqual(asset_key(r), hashlib.sha256(raw).hexdigest())
		self.assertEqual(asset_key(r), "3e4cecabdb6c9bac29d5f9c655852e10f1d96abdb437cee386bfecf3974b1cbf",
			"matches the AssetStudio locks/valid fixtures")
		for item in VECTORS["asset_keys"]:
			self.assertEqual(asset_key(item["asset_ref"]), item["asset_key"])

	def test_binding_id_ignores_key_order_and_existing_id(self) -> None:
		b = bundled_binding(TRUSTED, "nature.rock.boulder_a")
		shuffled = dict(reversed(list(b.items())))
		self.assertEqual(binding_id(shuffled), b["binding_id"])
		self.assertEqual(binding_id(dict(b, binding_id="bx")), b["binding_id"])
		changed = dict(b, asset_version=2)
		self.assertNotEqual(binding_id(changed), b["binding_id"])


def lock_of(bindings: list[dict[str, Any]], deps: dict[str, Any] | None = None) -> bytes:
	from worldpoc_write import lock_bytes_of
	return lock_bytes_of(bindings, deps)


class LockGrammarTests(unittest.TestCase):
	def parse(self, lock: Any) -> list[str]:
		return lc.parse_lock(canonical_v1(lock), TRUSTED)[1]

	def assertRejects(self, lock: Any, needle: str) -> None:
		errors = self.parse(lock)
		self.assertTrue(any(needle in e for e in errors), (needle, errors))

	def test_empty_and_bundled_locks_parse(self) -> None:
		self.assertEqual(lc.parse_lock(lock_of([]), TRUSTED)[1], [])
		self.assertEqual(lc.parse_lock(lock_of([bundled_binding(TRUSTED, "nature.rock.boulder_a")]), TRUSTED)[1], [])

	def test_top_level_shape(self) -> None:
		self.assertRejects({"schema_version": 2, "bindings": [], "dependencies": {}}, "schema_version must be 1")
		self.assertRejects({"schema_version": 1, "bindings": []}, "missing field 'dependencies'")
		self.assertRejects({"schema_version": 1, "bindings": [], "dependencies": {}, "x": 1}, "unknown field")
		self.assertRejects({"schema_version": 1, "bindings": {}, "dependencies": {}}, "bindings must be an array")

	def test_binding_count_limit(self) -> None:
		errors = lc.parse_lock(canonical_v1({"schema_version": 1, "bindings": [{}] * 4097, "dependencies": {}}), TRUSTED)[1]
		self.assertTrue(any("4097 bindings (max 4096)" in e for e in errors), errors)

	def test_size_limit(self) -> None:
		errors = lc.parse_lock(b" " * (8 * 1024 * 1024 + 1), TRUSTED)[1]
		self.assertTrue(any("limit 8388608" in e for e in errors), errors)

	def test_unsorted_and_duplicate_bindings(self) -> None:
		a, b = (bundled_binding(TRUSTED, n) for n in ("nature.rock.boulder_a", "nature.tree.spruce_a"))
		lo, hi = sorted((a, b), key=lambda x: x["binding_id"])
		self.assertRejects({"schema_version": 1, "bindings": [hi, lo], "dependencies": {}}, "not sorted")
		self.assertRejects({"schema_version": 1, "bindings": [lo, lo], "dependencies": {}}, "duplicate binding_id")

	def test_policy_grammar(self) -> None:
		b = bundled_binding(TRUSTED, "nature.rock.boulder_a")
		for bad, needle in (({"scatter_allowed": 1, "scale_range": ["1", "2"], "height_offset_range_m": ["0", "1"]}, "boolean"),
				({"scatter_allowed": True, "scale_range": ["1.0", "2"], "height_offset_range_m": ["0", "1"]}, "canonical decimal"),
				({"scatter_allowed": True, "scale_range": ["0", "2"], "height_offset_range_m": ["0", "1"]}, "canonical decimal"),
				({"scatter_allowed": True, "scale_range": ["2", "1"], "height_offset_range_m": ["0", "1"]}, "minimum exceeds"),
				({"scatter_allowed": True, "scale_range": ["1", "2"], "height_offset_range_m": ["-0", "1"]}, "canonical decimal"),
				({"scatter_allowed": True, "scale_range": ["1", "2"]}, "missing field")):
			self.assertRejects({"schema_version": 1, "bindings": [dict(b, policy=bad)], "dependencies": {}}, needle)

	def test_bundled_fields_and_provider(self) -> None:
		b = bundled_binding(TRUSTED, "nature.rock.boulder_a")
		self.assertRejects({"schema_version": 1, "bindings": [dict(b, provider="other")], "dependencies": {}}, "unknown provider")
		self.assertRejects({"schema_version": 1, "bindings": [dict(b, extra=1)], "dependencies": {}}, "unknown field")
		bad = dict(b, asset_id="Bad Id")
		self.assertRejects({"schema_version": 1, "bindings": [bad], "dependencies": {}}, "asset_id")

	def test_unavailable_bundled_binding_is_structurally_valid(self) -> None:
		other = bundled_binding(dict(TRUSTED, sha256="0" * 64), "nature.rock.boulder_a")
		lock, errors = lc.parse_lock(lock_of([other]), TRUSTED)
		self.assertEqual(errors, [])
		self.assertEqual(len(lc.availability_report(lock, TRUSTED)), 1)
		self.assertEqual(lc.availability_report(lc.parse_lock(lock_of([bundled_binding(TRUSTED, "nature.rock.boulder_a")]), TRUSTED)[0], TRUSTED), [])
		gone = bundled_binding(TRUSTED, "nature.rock.boulder_a")
		gone = dict(gone, asset_id="nature.rock.removed_a")
		from worldpoc_locks import with_binding_id
		lock, errors = lc.parse_lock(lock_of([with_binding_id(gone)]), TRUSTED)
		self.assertEqual((errors, len(lc.availability_report(lock, TRUSTED))), ([], 1))


class AssetStudioBindingTests(unittest.TestCase):
	def binding(self, **kw: Any) -> dict[str, Any]:
		return B.remote_binding(B.descriptor_text("primitive_prop.json"), B.ref(), **kw)

	def errors(self, b: dict[str, Any]) -> list[str]:
		return lc.parse_lock(lock_of([b]), TRUSTED)[1]

	def test_valid(self) -> None:
		self.assertEqual(self.errors(self.binding()), [])
		self.assertEqual(self.errors(self.binding(static=True, scatter=True)), [])

	def test_policy_must_lie_within_descriptor_ranges(self) -> None:
		self.assertTrue(any("scale_range is outside the descriptor" in e for e in self.errors(self.binding(scale=("0.4", "2")))))
		self.assertTrue(any("height_offset_range_m is outside" in e for e in self.errors(self.binding(height=("-0.1", "0.6")))))
		self.assertEqual(self.errors(self.binding(scale=("0.75", "1.5"), height=("0", "0.25"))), [])

	def test_asset_key_and_ref_checks(self) -> None:
		from worldpoc_locks import with_binding_id
		b = self.binding()
		self.assertTrue(any("asset_key does not equal" in e for e in self.errors(with_binding_id(dict(b, asset_key="0" * 64)))))
		bad_ref = dict(b["asset_ref"], asset_id="ast_NOPE")
		self.assertTrue(any("asset_ref.asset_id" in e for e in self.errors(with_binding_id(dict(b, asset_ref=bad_ref)))))

	def test_descriptor_checks(self) -> None:
		text = B.descriptor_text("primitive_prop.json")
		ref = B.ref()
		d = json.loads(text)
		for mutate, needle in ((lambda x: x.update(kind="scene"), "descriptor.kind"),
				(lambda x: x.update(bounds_max=["-1", "0", "0"]), "bounds are not ordered"),
				(lambda x: x.update(asset_ref=dict(ref, version_id="ver_00000000000000v9")), "does not equal the binding"),
				(lambda x: x.pop("licence"), "missing field 'licence'"),
				(lambda x: x.update(scale_range=["2", "1"]), "minimum exceeds")):
			x = json.loads(text)
			mutate(x)
			desc, errors = lc.check_descriptor(canonical_v1(x).decode(), ref)
			self.assertIsNone(desc)
			self.assertTrue(any(needle in e for e in errors), (needle, errors))
		self.assertIsNotNone(lc.check_descriptor(text, ref)[0])
		self.assertEqual(d["scale_range"], ["0.5", "2"])
		self.assertIsNone(lc.check_descriptor("not json", ref)[0])

	def test_dependency_requires_must_be_sorted_present_and_acyclic(self) -> None:
		b = self.binding()
		key = b["asset_key"]
		other_ref = B.ref(version_id="ver_00000000000000v2")
		other = asset_key(other_ref)
		entry = {"asset_ref": b["asset_ref"], "descriptor_sha256": b["descriptor_sha256"], "deliveries": b["deliveries"], "requires": []}
		dep2 = {"asset_ref": other_ref, "descriptor_sha256": "1" * 64, "deliveries": {"portable_glb_v1": b["deliveries"]["portable_glb_v1"]}, "requires": []}
		ok = {key: dict(entry, requires=[other]), other: dep2}
		lock = lc.parse_lock(lock_of([b], ok), TRUSTED)[0]
		self.assertIsNotNone(lock)
		self.assertEqual(lc.check_dependencies(lock, {b["binding_id"]}), [], "transitive requires belong to the closure")
		cyc = {key: dict(entry, requires=[other]), other: dict(dep2, requires=[key])}
		lock = lc.parse_lock(lock_of([b], cyc), TRUSTED)[0]
		self.assertTrue(any("cycle" in e for e in lc.check_dependencies(lock, {b["binding_id"]})))
		dangling = {key: dict(entry, requires=[other])}
		lock = lc.parse_lock(lock_of([b], dangling), TRUSTED)[0]
		self.assertTrue(any("missing" in e for e in lc.check_dependencies(lock, {b["binding_id"]})))
		unsorted = {key: dict(entry, requires=sorted([other, key], reverse=True))}
		self.assertTrue(any("sorted and unique" in e for e in lc.parse_lock(lock_of([b], unsorted), TRUSTED)[1]))
		wrong_pin = {key: dict(entry, deliveries={"portable_glb_v1": dict(b["deliveries"]["portable_glb_v1"], profile_id="other")})}
		lock = lc.parse_lock(lock_of([b], wrong_pin), TRUSTED)[0]
		self.assertTrue(any("lacks delivery pin" in e for e in lc.check_dependencies(lock, {b["binding_id"]})))


if __name__ == "__main__":
	unittest.main()
