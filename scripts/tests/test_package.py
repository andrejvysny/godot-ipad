""".worldpoc package rules checked before extraction (world-format §9; spec IO-08) and a round trip."""
from __future__ import annotations

import io
import shutil
import struct
import tempfile
import unittest
import warnings
import zipfile
import zlib
from pathlib import Path

from wp_test_support import FIXTURES, wf

GOOD = FIXTURES / "flat"


def entries_of(gen: Path) -> dict[str, bytes]:
	return {name: (gen / name).read_bytes() for name in ["manifest.json"] + wf.PAYLOAD_PATHS}


def build_zip(entries: list[tuple[str, bytes]], compression: int = zipfile.ZIP_DEFLATED,
		attrs: dict[str, int] | None = None) -> bytes:
	buf = io.BytesIO()
	with warnings.catch_warnings():
		warnings.simplefilter("ignore")  # zipfile warns on duplicate names
		with zipfile.ZipFile(buf, "w", compression=compression) as zf:
			for name, data in entries:
				info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
				info.compress_type = compression
				info.external_attr = (attrs or {}).get(name, 0o100644 << 16)
				zf.writestr(info, data)
	return buf.getvalue()


def add_zip64_records(data: bytes) -> bytes:
	"""Insert a well-formed ZIP64 end record + locator before the classic end record."""
	eocd = data.rfind(b"PK\x05\x06")
	_, _, _, _, count, cd_size, cd_offset, _ = struct.unpack("<IHHHHIIH", data[eocd:eocd + 22])
	rec = struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, count, count, cd_size, cd_offset)
	loc = struct.pack("<IIQI", 0x07064B50, 0, eocd, 1)
	return data[:eocd] + rec + loc + data[eocd:]


def patch_central_size(data: bytes, name: str, new_size: int) -> bytes:
	i = data.find(b"PK\x01\x02")
	while i >= 0:
		name_len = struct.unpack("<H", data[i + 28:i + 30])[0]
		if data[i + 46:i + 46 + name_len] == name.encode():
			return data[:i + 24] + struct.pack("<I", new_size) + data[i + 28:]
		i = data.find(b"PK\x01\x02", i + 4)
	raise AssertionError("entry not found")


def rename_entry(data: bytes, old: str, new: bytes) -> bytes:
	"""Same-length raw rename in both the local and the central header (e.g. to inject a NUL)."""
	assert len(new) == len(old.encode())
	return data.replace(old.encode(), new)


def local_data_offset(data: bytes, name: str) -> int:
	i = data.find(b"PK\x03\x04")
	while i >= 0:
		name_len, extra_len = struct.unpack("<HH", data[i + 26:i + 30])
		if data[i + 30:i + 30 + name_len] == name.encode():
			return i + 30 + name_len + extra_len
		i = data.find(b"PK\x03\x04", i + 4)
	raise AssertionError("entry not found")


class PackageTests(unittest.TestCase):
	def setUp(self) -> None:
		self.tmp = Path(tempfile.mkdtemp(prefix="wp_pkg_"))
		self.good = entries_of(GOOD)

	def tearDown(self) -> None:
		shutil.rmtree(self.tmp, ignore_errors=True)

	def write(self, data: bytes) -> Path:
		path = self.tmp / "world.worldpoc"
		path.write_bytes(data)
		return path

	def good_entries(self, **replace: bytes) -> list[tuple[str, bytes]]:
		return [(n, replace.get(n, d)) for n, d in self.good.items()]

	def assertInspectRejects(self, data: bytes, needle: str) -> None:
		path = self.write(data)
		_, errors = wf.inspect_zip(path)
		self.assertTrue(any(needle in e for e in errors), "expected %r in %r" % (needle, errors))
		result = wf.validate_path(path)
		self.assertFalse(result["valid"])

	def test_valid_round_trip(self) -> None:
		path = self.tmp / "flat.worldpoc"
		wf.write_package(GOOD, path)
		_, errors = wf.inspect_zip(path)
		self.assertEqual(errors, [])
		result = wf.validate_path(path)
		self.assertTrue(result["valid"], result["errors"])
		manifest = wf.parse_json_bytes(self.good["manifest.json"])
		self.assertEqual(result["authored_content_hash"], manifest["authored_content_hash"])
		extracted, errors = wf.safe_extract(path)
		try:
			self.assertEqual(errors, [])
			for name, data in self.good.items():
				self.assertEqual((extracted / name).read_bytes(), data, name)
			self.assertNotEqual(extracted.resolve().parent, self.tmp.resolve())
		finally:
			shutil.rmtree(extracted, ignore_errors=True)

	def test_stored_and_directory_entry_tolerated(self) -> None:
		data = build_zip([("regions/", b"")] + self.good_entries(), compression=zipfile.ZIP_STORED)
		result = wf.validate_path(self.write(data))
		self.assertTrue(result["valid"], result["errors"])

	def test_absolute_path(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries() + [("/etc/manifest.json", b"x")]), "absolute path")

	def test_traversal(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries() + [("../escape.json", b"x")]), "path traversal")
		self.assertInspectRejects(build_zip(self.good_entries() + [("regions/../../x", b"x")]), "path traversal")

	def test_backslash(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries() + [("regions\\r_0_0.height.f32le", b"x")]), "backslash")

	def test_duplicate_entry(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries() + [("objects.json", self.good["objects.json"])]),
			"duplicate entry 'objects.json'")

	def test_unknown_entry(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries() + [("payload.dylib", b"\xcf\xfa\xed\xfe")]),
			"unknown entry 'payload.dylib'")

	def test_symlink(self) -> None:
		data = build_zip(self.good_entries(), attrs={"objects.json": 0o120777 << 16})
		self.assertInspectRejects(data, "symlink entry 'objects.json'")

	def test_oversize_entries(self) -> None:
		# Package inspection applies the schema 3 envelope (world-format §11.3).
		declared = patch_central_size(build_zip(self.good_entries()), "objects.json", 128 * 1024 * 1024 + 1)
		self.assertInspectRejects(declared, "limit 134217728")
		big = b" " * (256 * 1024 + 1)
		self.assertInspectRejects(build_zip(self.good_entries(**{"manifest.json": big})), "limit 262144")
		short = self.good["regions/r_0_0.height.f32le"][:-4]
		self.assertInspectRejects(build_zip(self.good_entries(**{"regions/r_0_0.height.f32le": short})), "expected 262144")

	def test_new_payload_names_and_limits(self) -> None:
		self.assertEqual(len(wf.PAYLOAD_PATHS), 15)
		self.assertEqual((wf.SCATTER_MAX_BYTES, wf.PATHS_MAX_BYTES), (512 * 1024, 640 * 1024), "schema 2 limits")
		self.assertEqual((wf.PACKAGE_MAX_TOTAL_BYTES, wf.PACKAGE_MAX_FILE_BYTES, wf.PACKAGE_MAX_ENTRIES),
			(256 * 1024 * 1024, 264 * 1024 * 1024, 197), "schema 3 envelope")
		for name in ("scatter.bin", "paths.bin", "regions/r_0_0.color.rgba8"):
			self.assertIn(name, self.good)
		self.assertInspectRejects(build_zip(self.good_entries(**{"scatter.bin": b"\0" * (4 * 1024 * 1024 + 1)})),
			"limit 4194304")
		self.assertInspectRejects(build_zip(self.good_entries(**{"paths.bin": b"\0" * (wf.PATHS_MAX_BYTES + 1)})),
			"limit 655360")
		short = self.good["regions/r_0_0.color.rgba8"][:-4]
		self.assertInspectRejects(build_zip(self.good_entries(**{"regions/r_0_0.color.rgba8": short})), "expected 262144")

	def test_boundary_sizes_pass_inspection(self) -> None:
		data = build_zip(self.good_entries(**{"scatter.bin": b"\0" * wf.SCATTER_MAX_BYTES,
			"paths.bin": b"\0" * wf.PATHS_MAX_BYTES}))
		_, errors = wf.inspect_zip(self.write(data))
		self.assertEqual(errors, [])

	def test_entry_count_limit(self) -> None:
		# manifest + 15 payload + regions/ is 17; the envelope allows 197 entries, 198 is too many.
		extras = [("regions/", b"")]
		self.assertEqual(wf.inspect_zip(self.write(build_zip(extras + self.good_entries())))[1], [])
		many = self.good_entries() + [("x%d" % i, b"") for i in range(198 - 16)]
		path = self.write(build_zip(many))
		self.assertTrue(any("archive has 198 entries" in e for e in wf.inspect_zip(path)[1]))

	def test_old_schema_1_package_gets_explicit_diagnostic(self) -> None:
		m = wf.parse_json_bytes(self.good["manifest.json"])
		m["schema_version"] = 1
		old = [(n, d) for n, d in self.good_entries() if n not in ("scatter.bin", "paths.bin") and "color" not in n]
		old = [("manifest.json", wf.dump_json(m))] + [e for e in old if e[0] != "manifest.json"]
		result = wf.validate_path(self.write(build_zip(old)))
		self.assertFalse(result["valid"])
		self.assertTrue(result["errors"][0].startswith("unknown schema_version 1"), result["errors"])

	def test_zip64(self) -> None:
		self.assertInspectRejects(add_zip64_records(build_zip(self.good_entries())), "ZIP64")

	def test_bad_compression(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries(), compression=zipfile.ZIP_BZIP2), "unsupported compression 12")
		self.assertInspectRejects(build_zip(self.good_entries(), compression=zipfile.ZIP_LZMA), "unsupported compression 14")

	def test_missing_entry(self) -> None:
		entries = [e for e in self.good_entries() if e[0] != "objects.json"]
		self.assertInspectRejects(build_zip(entries), "missing entry 'objects.json'")

	def test_not_a_zip(self) -> None:
		self.assertInspectRejects(b"definitely not a zip file", "not a readable ZIP")

	def test_actual_size_must_match_central_directory(self) -> None:
		data = build_zip(self.good_entries())
		n = len(self.good["objects.json"])
		path = self.write(patch_central_size(data, "objects.json", n - 1))
		_, errors = wf.inspect_zip(path)
		self.assertEqual(errors, [], "central directory itself looks fine")
		extracted, errors = wf.safe_extract(path)
		self.assertIsNone(extracted)
		self.assertTrue(errors)
		self.assertFalse(wf.validate_path(path)["valid"])

	def test_nul_in_entry_name(self) -> None:
		# zipfile would report 'objects.json' (cut at the NUL); ZipInspector sees the raw bytes.
		entries = [(n, d) for n, d in self.good_entries() if n != "objects.json"]
		entries.append(("objects.jsonXevil", self.good["objects.json"]))
		data = rename_entry(build_zip(entries), "objects.jsonXevil", b"objects.json\x00evil")
		self.assertInspectRejects(data, "NUL-containing")

	def test_unicode_path_extra_cannot_rename_entry(self) -> None:
		entries = [(n, d) for n, d in self.good_entries() if n != "objects.json"]
		buf = io.BytesIO()
		with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
			for name, payload in entries:
				zf.writestr(zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0)), payload)
			info = zipfile.ZipInfo("evil.bin", date_time=(1980, 1, 1, 0, 0, 0))
			up = b"objects.json"
			info.extra = struct.pack("<HHBI", 0x7075, 5 + len(up), 1, zlib.crc32(b"evil.bin")) + up
			zf.writestr(info, self.good["objects.json"])
		self.assertInspectRejects(buf.getvalue(), "substituted name")

	def test_prepended_data(self) -> None:
		self.assertInspectRejects(b"JUNK" * 64 + build_zip(self.good_entries()), "prepended")

	def test_trailing_data_and_comment(self) -> None:
		self.assertInspectRejects(build_zip(self.good_entries()) + b"\0" * 8, "after its end-of-central-directory")
		self.assertInspectRejects(build_zip(self.good_entries()) + b"note", "after its end-of-central-directory")
		data = bytearray(build_zip(self.good_entries()))
		data[-2:] = struct.pack("<H", 4)  # declared comment; zipfile would read past it
		self.assertInspectRejects(bytes(data), "comments are not allowed")

	def test_distant_zip64_locator(self) -> None:
		# minizip honours any ZIP64 locator in the last 64 KiB, not only one right before the end record.
		last = wf.PAYLOAD_PATHS[-1]
		locator = struct.pack("<IIQI", 0x07064B50, 0, 0, 1)
		payload = self.good[last][:-24] + locator + b"\0" * 4
		data = build_zip(self.good_entries(**{last: payload}), compression=zipfile.ZIP_STORED)
		self.assertInspectRejects(data, "ZIP64")

	def test_oversize_package_file(self) -> None:
		path = self.tmp / "huge.worldpoc"
		with open(path, "wb") as f:  # sparse: the size check runs before anything is read
			f.seek(wf.PACKAGE_MAX_FILE_BYTES)
			f.write(build_zip(self.good_entries()))
		_, errors = wf.inspect_zip(path)
		self.assertTrue(any("package file is" in e for e in errors), errors)

	def test_corrupt_deflate_stream(self) -> None:
		data = bytearray(build_zip(self.good_entries()))
		data[local_data_offset(bytes(data), "objects.json")] = 0x07  # BFINAL=1, reserved BTYPE=11
		path = self.write(bytes(data))
		self.assertEqual(wf.inspect_zip(path)[1], [])
		extracted, errors = wf.safe_extract(path)
		self.assertIsNone(extracted)
		self.assertTrue(any("extraction failed" in e for e in errors), errors)
		self.assertFalse(wf.validate_path(path)["valid"])

	def test_invalid_generation_inside_valid_zip(self) -> None:
		bad = bytearray(self.good["regions/r_0_0.height.f32le"])
		bad[0:4] = struct.pack("<f", float("nan"))
		result = wf.validate_path(self.write(build_zip(self.good_entries(**{"regions/r_0_0.height.f32le": bytes(bad)}))))
		self.assertFalse(result["valid"])
		self.assertTrue(any("sha256 mismatch" in e for e in result["errors"]), result["errors"])


if __name__ == "__main__":
	unittest.main()
