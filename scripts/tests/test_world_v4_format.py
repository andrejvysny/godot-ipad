"""Schema 4 worlds (docs/world-format.md §12): golden fixtures and INDEX, validation, writer, migration, CLI,
package envelope."""
from __future__ import annotations

import hashlib
import io
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from typing import Any

from wp_test_support import FIXTURES, SCRIPTS, wf
import world_v4_builders as B
import generate_world_v4_fixtures as gen_fx
import worldpoc_migrate as wm
from worldpoc_locks import bundled_binding
from worldpoc_v4 import parse_scatter_v2, write_scatter_v2
from worldpoc_write import seal_generation_v4, write_generation_v4

F = B.FIXTURES_V4
INDEX = json.loads((F / "INDEX.json").read_text())["fixtures"]
TRUSTED = wf.load_trusted_catalog()
# Same literal as the km1_flat_empty entry of INDEX.json; the GDScript test pins it too.
KM1_FLAT_V4 = "6295548902d7"


def validate(path: Path) -> dict[str, Any]:
	return wf.validate_path(path)


class IndexTests(unittest.TestCase):
	def test_required_vectors_are_listed(self) -> None:
		names = {e["name"] for e in INDEX}
		for need in ("km1_flat_empty", "legacy_flat_empty", "one_bundled_object", "one_remote_object", "two_versions",
				"remote_scatter", "non_ascii_ids", "holes", "migrate_v2", "migrate_v3"):
			self.assertIn(need, names)
		self.assertGreaterEqual(len([e for e in INDEX if e["expected"] == "invalid"]), 13)

	def test_files_hash_and_outcomes(self) -> None:
		for e in INDEX:
			if e["path"] is None:
				self.assertIsNone(e["sha256"])
				continue
			path = F / e["path"]
			self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), e["sha256"], e["name"])
			if e["kind"] == "vectors":
				continue
			r = validate(path)
			if e["expected"] == "valid":
				self.assertEqual((r["valid"], r["errors"]), (True, []), e["name"])
				self.assertEqual(r["authored_content_hash"], e["authored_hash"], e["name"])
			else:
				self.assertFalse(r["valid"], e["name"])
				self.assertTrue(any(e["error_substring"] in x for x in r["errors"]), (e["name"], r["errors"]))

	def test_committed_files_are_the_generator_output(self) -> None:
		for name, data in gen_fx.generate().items():
			self.assertEqual((F / name).read_bytes(), data, name)

	def test_km1_flat_vector(self) -> None:
		self.assertTrue(gen_fx.km1_flat_empty_hash().startswith(KM1_FLAT_V4))
		entry = next(e for e in INDEX if e["name"] == "km1_flat_empty")
		self.assertEqual(entry["authored_hash"], gen_fx.km1_flat_empty_hash())

	def test_km1_flat_world_round_trips_through_the_validator(self) -> None:
		doc = B.v4_doc(40, wf.KM1_LAYOUT, [], [])
		with B.Workdir() as tmp:
			manifest = write_generation_v4(tmp / "g", doc)
			self.assertEqual(manifest["authored_content_hash"], gen_fx.km1_flat_empty_hash())
			self.assertEqual(validate(tmp / "g")["errors"], [])
			wf.write_package(tmp / "g", tmp / "w.worldpoc")
			self.assertEqual(len(zipfile.ZipFile(tmp / "w.worldpoc").namelist()), 1 + 4 + 3 * 64)
			self.assertEqual(validate(tmp / "w.worldpoc")["authored_content_hash"], gen_fx.km1_flat_empty_hash())

	def test_availability_is_reported_not_failed(self) -> None:
		r = validate(F / "one_remote_object.worldpoc")
		self.assertTrue(r["valid"])
		self.assertEqual(len(r["availability"]), 1)
		self.assertEqual(validate(F / "one_bundled_object.worldpoc")["availability"], [])


class ValidationTests(unittest.TestCase):
	def setUp(self) -> None:
		self.ctx = B.Workdir()
		self.tmp = self.ctx.__enter__()

	def tearDown(self) -> None:
		self.ctx.__exit__()

	def world(self, doc: dict[str, Any], name: str = "g") -> Path:
		write_generation_v4(self.tmp / name, doc)
		return self.tmp / name

	def test_unavailable_bundled_binding_still_validates_records(self) -> None:
		other = bundled_binding(dict(TRUSTED, sha256="0" * 64), "nature.rock.boulder_a")
		gen = self.world(B.v4_doc(41, B.ONE_REGION, [other], [B.obj(1, other["binding_id"], 5.0, 5.0, 1.0)]))
		r = validate(gen)
		self.assertTrue(r["valid"], r["errors"])
		self.assertEqual(len(r["availability"]), 1)
		gen2 = self.world(B.v4_doc(41, B.ONE_REGION, [other], [B.obj(1, other["binding_id"], 5.0, 5.0, 9.0)]), "g2")
		self.assertTrue(any("uniform_scale" in e for e in validate(gen2)["errors"]))

	def test_scatter_scale_must_lie_in_policy_range(self) -> None:
		b = bundled_binding(TRUSTED, "nature.tree.spruce_a")
		ok = self.world(B.v4_doc(42, B.ONE_REGION, [b], [], [B.scatter_inst(b["binding_id"], 5.0, 5.0, 0.5, 2.0)]))
		self.assertTrue(validate(ok)["valid"])
		bad = self.world(B.v4_doc(42, B.ONE_REGION, [b], [], [B.scatter_inst(b["binding_id"], 5.0, 5.0, 0.5, 2.1)]), "g2")
		self.assertTrue(any("scatter instance 0 scale" in e for e in validate(bad)["errors"]))

	def test_scatter_v2_round_trip_and_rules(self) -> None:
		a, b = "b" + "1" * 32, "b" + "2" * 32
		insts = [B.scatter_inst(b, 1.0, 2.0), B.scatter_inst(a, 3.0, 4.0, flags=1), B.scatter_inst(b, 5.0, 6.0)]
		data = write_scatter_v2(insts)
		parsed, err = parse_scatter_v2(data, 100, B.ONE_REGION)
		self.assertEqual((err, parsed["bindings"], [i["binding_id"] for i in parsed["instances"]]), ("", [a, b], [b, a, b]))
		self.assertEqual(write_scatter_v2(parsed["instances"]), data)
		self.assertEqual(write_scatter_v2([]), b"WPSC" + struct.pack("<III", 2, 0, 0))
		self.assertEqual(len(write_scatter_v2([])), 16)
		hdr = b"WPSC" + struct.pack("<II", 2, 2)
		pack = lambda s: struct.pack("<I", len(s)) + s.encode()  # noqa: E731
		rec = struct.pack("<HHffff", 0, 0, 1.0, 1.0, 0.0, 1.0)
		cases = {
			"not sorted": hdr + pack(b) + pack(a) + struct.pack("<I", 0),
			"duplicate": hdr + pack(a) + pack(a) + struct.pack("<I", 0),
			"not referenced": hdr + pack(a) + pack(b) + struct.pack("<I", 1) + rec,
			"not a binding_id": b"WPSC" + struct.pack("<II", 2, 1) + pack("x") + struct.pack("<I", 0),
			"version 1 is not supported": b"WPSC" + struct.pack("<III", 1, 0, 0),
			"trailing": data + b"\0",
			"out of range": b"WPSC" + struct.pack("<II", 2, 1) + pack(a) + struct.pack("<I", 1)
				+ struct.pack("<HHffff", 1, 0, 1.0, 1.0, 0.0, 1.0),
		}
		for needle, blob in cases.items():
			self.assertIsNone(parse_scatter_v2(blob, 100, B.ONE_REGION)[0], needle)
			self.assertIn(needle.split()[0], parse_scatter_v2(blob, 100, B.ONE_REGION)[1], needle)

	def test_object_record_rules(self) -> None:
		b = bundled_binding(TRUSTED, "nature.rock.boulder_a")
		rec = B.obj(1, b["binding_id"], 5.0, 5.0)
		self.assertIsNotNone(wf.parse_object_record(rec, True)[0])
		self.assertIn("binding_id must match", wf.parse_object_record(dict(rec, binding_id="x"), True)[1])
		self.assertIn("missing field 'binding_id'", wf.parse_object_record({k: v for k, v in rec.items() if k != "binding_id"}, True)[1])
		self.assertIn("missing field 'asset_id'", wf.parse_object_record(rec)[1])

	def test_manifest_rules(self) -> None:
		gen = self.world(B.v4_doc(43, B.ONE_REGION, [], []))
		original = (gen / "manifest.json").read_bytes()
		cases = {
			"asset_lock must be an object": lambda m: m.pop("asset_lock"),
			"asset_lock.path": lambda m: m["asset_lock"].update(path="x.json"),
			"must not have a catalog block": lambda m: m.update(catalog={"id": "poc_nature"}),
			"terrain missing field 'layout'": lambda m: m["terrain"].pop("layout"),
			"payload_files must list exactly": lambda m: m["payload_files"].pop(0),
		}
		for needle, mutate in cases.items():
			m = json.loads(original)
			mutate(m)
			(gen / "manifest.json").write_bytes(wf.dump_json(m))
			errors = validate(gen)["errors"]
			self.assertTrue(any(needle in e for e in errors), (needle, errors))
		(gen / "manifest.json").write_bytes(original)
		self.assertEqual(validate(gen)["errors"], [])

	def test_authored_hash_depends_on_the_lock_and_binding_ids(self) -> None:
		hashes = set()
		for scale in (1.0, 1.25):
			b = bundled_binding(TRUSTED, "nature.rock.boulder_a")
			gen = self.world(B.v4_doc(44, B.ONE_REGION, [b], [B.obj(1, b["binding_id"], 5.0, 5.0, scale)]), "g%s" % scale)
			hashes.add(validate(gen)["authored_content_hash"])
		self.assertEqual(len(hashes), 2)
		a = self.world(B.v4_doc(44, B.ONE_REGION, [], []), "a")
		self.assertNotEqual(validate(a)["authored_content_hash"], gen_fx.km1_flat_empty_hash())

	def test_extra_and_missing_files(self) -> None:
		gen = self.world(B.v4_doc(45, B.ONE_REGION, [], []))
		(gen / "asset_locks.json").unlink()
		self.assertTrue(any("missing file 'asset_locks.json'" in e for e in validate(gen)["errors"]))
		gen3 = self.tmp / "v3"
		shutil.copytree(FIXTURES / "flat", gen3)
		(gen3 / "asset_locks.json").write_bytes(b"{}")
		self.assertTrue(any("unexpected file" in e for e in validate(gen3)["errors"]))

	def test_seal_keeps_hostile_content_checkable(self) -> None:
		gen = self.world(B.v4_doc(46, B.ONE_REGION, [], []))
		(gen / "asset_locks.json").write_bytes(b'{"x":1}')
		seal_generation_v4(gen)
		errors = validate(gen)["errors"]
		self.assertTrue(any("asset_locks.json is missing field" in e or "missing field" in e for e in errors), errors)


class PackageEnvelopeTests(unittest.TestCase):
	def entries(self) -> list[tuple[str, bytes]]:
		with zipfile.ZipFile(F / "one_bundled_object.worldpoc") as zf:
			return [(i.filename, zf.read(i)) for i in zf.infolist()]

	def errors(self, entries: list[tuple[str, bytes]]) -> list[str]:
		with B.Workdir() as tmp:
			(tmp / "p.worldpoc").write_bytes(B.build_zip(entries))
			return wf.inspect_zip(tmp / "p.worldpoc")[1]

	def test_schema_4_allows_198_entries_schema_3_197(self) -> None:
		base = self.entries()
		self.assertEqual(self.errors(base), [])
		self.assertEqual(wf.PACKAGE_MAX_ENTRIES, 197)
		self.assertEqual(wf.PACKAGE_MAX_ENTRIES_V4, 198)
		def padded(entries: list[tuple[str, bytes]], n: int) -> list[tuple[str, bytes]]:
			return entries + [("x%d" % i, b"") for i in range(n - len(entries))]
		no_lock = [e for e in base if e[0] != "asset_locks.json"]
		self.assertTrue(any("archive has 198 entries, allowed 1..197" in e for e in self.errors(padded(no_lock, 198))))
		self.assertFalse(any("archive has" in e for e in self.errors(padded(base, 198))), "198 entries with the lock")
		self.assertTrue(any("archive has 199 entries, allowed 1..198" in e for e in self.errors(padded(base, 199))))

	def test_lock_entry_limit(self) -> None:
		over = [(n, b"\0" * (8 * 1024 * 1024 + 1) if n == "asset_locks.json" else d) for n, d in self.entries()]
		self.assertTrue(any("limit 8388608" in e for e in self.errors(over)))
		ok = [(n, b"\0" * (8 * 1024 * 1024) if n == "asset_locks.json" else d) for n, d in self.entries()]
		self.assertEqual(self.errors(ok), [])

	def test_package_is_deterministic_and_has_the_lock(self) -> None:
		names = [n for n, _ in self.entries()]
		self.assertEqual(names[0], "manifest.json")
		self.assertEqual(names[1:], wf.payload_paths(B.ONE_REGION, 4))
		self.assertIn("asset_locks.json", names)
		self.assertEqual(wf.payload_paths(wf.LEGACY_LAYOUT), [p for p in wf.payload_paths(wf.LEGACY_LAYOUT, 4) if p != "asset_locks.json"])


class MigrationTests(unittest.TestCase):
	def migrate(self, src: Path) -> tuple[Path, dict[str, Any], Any]:
		self.ctx = B.Workdir()
		tmp = self.ctx.__enter__()
		self.addCleanup(self.ctx.__exit__)
		manifest = wm.migrate(src, tmp / "out")
		return tmp / "out", manifest, tmp

	def assertSameWorld(self, src: Path, dst: Path) -> None:
		a, ea = wf.validate_generation(src)
		b, eb = wf.validate_generation(dst)
		self.assertEqual((ea, eb), ([], []))
		self.assertEqual(a.layout, b.layout)
		for loc in wf.layout_regions(*a.layout):
			for f in (wf.height_path, wf.control_path, wf.color_path):
				self.assertEqual((src / f(loc)).read_bytes(), (dst / f(loc)).read_bytes())
		self.assertEqual((src / "paths.bin").read_bytes(), (dst / "paths.bin").read_bytes())
		self.assertEqual(a.rules, b.rules)
		self.assertEqual(a.manifest["terrain"]["rules"], b.manifest["terrain"]["rules"])
		self.assertEqual([r["object_id"] for r in a.records], [r["object_id"] for r in b.records])
		for ra, rb in zip(a.records, b.records):
			for key in ("position", "rotation_xyzw", "uniform_scale", "grounding", "height_offset_m", "origin", "scatter_operation_id"):
				self.assertEqual(ra[key], rb[key], key)
		fa = json.loads((src / "objects.json").read_text())["objects"]
		fb = json.loads((dst / "objects.json").read_text())["objects"]
		for da, db in zip(fa, fb):
			self.assertEqual(da["f64le"], db["f64le"])
			self.assertEqual({k: v for k, v in da.items() if k not in ("asset_id", "asset_version")},
				{k: v for k, v in db.items() if k != "binding_id"})
		self.assertEqual(len(a.scatter["instances"]), len(b.scatter["instances"]))
		for ia, ib in zip(a.scatter["instances"], b.scatter["instances"]):
			self.assertEqual([ia[k] for k in ("flags", "x", "z", "yaw_rad", "scale")], [ib[k] for k in ("flags", "x", "z", "yaw_rad", "scale")])
			self.assertEqual(b.bindings[ib["binding_id"]]["asset_id"], ia["asset_id"])
		for ra, rb in zip(a.records, b.records):
			self.assertEqual(b.bindings[rb["binding_id"]]["asset_id"], ra["asset_id"])
		self.assertEqual(b.availability, [])

	def test_migrate_bundled_fixtures(self) -> None:
		for name in ("flat", "gentle_hills"):
			src = FIXTURES / name
			dst, manifest, _ = self.migrate(src)
			self.assertSameWorld(src, dst)
			self.assertEqual(manifest["schema_version"], 4)
			self.assertNotIn("catalog", manifest)
			self.assertEqual(validate(dst)["authored_content_hash"], manifest["authored_content_hash"])
			expected = next(e for e in INDEX if e["name"] == "migrate_v2_app_" + name)
			self.assertEqual(manifest["authored_content_hash"], expected["authored_hash"])

	def test_migrate_packaged_sources(self) -> None:
		for name in ("migrate_v2", "migrate_v3"):
			entry = next(e for e in INDEX if e["name"] == name)
			with B.Workdir() as tmp:
				src, errors = wf.safe_extract(F / entry["source"])
				self.assertIsNotNone(src, errors)
				try:
					manifest = wm.migrate(src, tmp / "out")
					self.assertSameWorld(src, tmp / "out")
				finally:
					shutil.rmtree(src, ignore_errors=True)
				self.assertEqual(manifest["authored_content_hash"], entry["authored_hash"])
				used = {b["asset_id"] for b in json.loads((tmp / "out" / "asset_locks.json").read_text())["bindings"]}
				self.assertEqual(used, {"nature.rock.boulder_a", "nature.tree.spruce_a", "built.lodge.cabin_a", "nature.cover.grass_tuft_a"})

	def test_migration_binds_default_policy_and_is_deterministic(self) -> None:
		src = F / "migrate_v3_source.worldpoc"
		hashes = []
		for _ in range(2):
			with B.Workdir() as tmp:
				d, _ = wf.safe_extract(src)[0], None
				try:
					hashes.append(wm.migrate(d, tmp / "o")["authored_content_hash"])
					lock = json.loads((tmp / "o" / "asset_locks.json").read_text())
					for b in lock["bindings"]:
						self.assertEqual(b, bundled_binding(TRUSTED, b["asset_id"]))
				finally:
					shutil.rmtree(d, ignore_errors=True)
		self.assertEqual(hashes[0], hashes[1])

	def test_refuses_existing_destination_and_schema_4_source(self) -> None:
		with B.Workdir() as tmp:
			(tmp / "exists").mkdir()
			with self.assertRaises(FileExistsError):
				wm.migrate(FIXTURES / "flat", tmp / "exists")
			wm.migrate(FIXTURES / "flat", tmp / "v4")
			with self.assertRaises(wm.MigrationError):
				wm.migrate(tmp / "v4", tmp / "v44")
			bad = tmp / "bad"
			shutil.copytree(FIXTURES / "flat", bad)
			(bad / "objects.json").write_text("{}")
			with self.assertRaises(wm.MigrationError):
				wm.migrate(bad, tmp / "out2")
			self.assertFalse((tmp / "out2").exists())
			self.assertEqual([p.name for p in tmp.iterdir() if p.name.startswith(".migrate_")], [])


class CliTests(unittest.TestCase):
	def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
		return subprocess.run([sys.executable, str(SCRIPTS / "validate_world.py"), *args], capture_output=True, text=True, timeout=120)

	def test_validate_schema_4_fixtures(self) -> None:
		for e in INDEX:
			if e["path"] is None or e["kind"] == "vectors":
				continue
			r = self.run_cli(str(F / e["path"]))
			if e["expected"] == "valid":
				self.assertEqual(r.returncode, 0, (e["name"], r.stdout))
				self.assertIn(e["authored_hash"], r.stdout)
			else:
				self.assertEqual(r.returncode, 1, e["name"])
				self.assertIn(e["error_substring"], r.stdout)

	def test_migrate_command(self) -> None:
		with B.Workdir() as tmp:
			r = self.run_cli("migrate", str(FIXTURES / "gentle_hills"), str(tmp / "out"), "--package", str(tmp / "o.worldpoc"))
			self.assertEqual(r.returncode, 0, r.stderr)
			expected = next(e for e in INDEX if e["name"] == "migrate_v2_app_gentle_hills")["authored_hash"]
			self.assertIn(expected, r.stdout)
			self.assertEqual(self.run_cli(str(tmp / "out")).returncode, 0)
			self.assertEqual(self.run_cli(str(tmp / "o.worldpoc")).returncode, 0)
			again = self.run_cli("migrate", str(FIXTURES / "gentle_hills"), str(tmp / "out"))
			self.assertEqual(again.returncode, 2)
			self.assertIn("already exists", again.stderr)
			pkg = self.run_cli("migrate", str(F / "migrate_v2_source.worldpoc"), str(tmp / "from_pkg"))
			self.assertEqual(pkg.returncode, 0, pkg.stderr)
			self.assertEqual(self.run_cli("migrate", str(F / "one_bundled_object.worldpoc"), str(tmp / "v4")).returncode, 1)
			self.assertEqual(self.run_cli("migrate", str(tmp / "nope"), str(tmp / "x")).returncode, 2)


if __name__ == "__main__":
	unittest.main()
