#!/usr/bin/env python3
"""Shared World Painter PoC format library (docs/world-format.md), Python stdlib only.

Mirrors WorldConstants, ControlCodec, ObjectRecord, WorldDocument.sample_height and
CanonicalEncoder from app/addons/world_painter/core/document. Validators return lists of error strings; they never
raise for invalid content.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import shutil
import struct
import sys
import tempfile
import zipfile
import zlib
from array import array
from pathlib import Path
from typing import Any

from worldpoc_constants import (
	REGION_MAP_BYTES,
	REGION_COORD_MIN,
	REGION_COORD_MAX,
	SCATTER_PATH,
	PATHS_PATH,
	ZIP_ENVELOPE,
	ZIP_ENVELOPE_V4,
	LOCK_PATH,
	LEGACY_LAYOUT,
	Layout,
	payload_paths,
	region_stem,
)

from worldpoc_manifest import _unknown_schema, is_supported_schema, manifest_layout
from worldpoc_values import (
	show,
	parse_json_bytes,
	FormatError,
)

# --- .worldpoc package (world-format §9, §11.3) ----------------------------------------
# Inspection runs before the manifest is read, so every limit here is the schema 3 envelope, except the
# asset_locks.json entry (schema 4: 8 MiB, one more archive entry, accepted only when the lock is present).
PACKAGE_ALLOWED_DIRS = {"regions/"}
PACKAGE_MAX_TOTAL_BYTES = ZIP_ENVELOPE["max_total_bytes"]
PACKAGE_MAX_FILE_BYTES = ZIP_ENVELOPE["max_archive_bytes"]
PACKAGE_MAX_ENTRIES = ZIP_ENVELOPE["max_entries"]
PACKAGE_MAX_ENTRIES_V4 = ZIP_ENVELOPE_V4["max_entries"]
FIXED_ENTRIES = ("objects.json", PATHS_PATH, SCATTER_PATH, "manifest.json")
REGION_KINDS = ("height.f32le", "control.u32le", "color.rgba8")
# Canonical decimal coordinates: no '+', no leading zeros, no "-0".
REGION_NAME_RE = re.compile(
	r"^regions/r_(0|-?[1-9][0-9]{0,2})_(0|-?[1-9][0-9]{0,2})\.(height\.f32le|control\.u32le|color\.rgba8)$")


def parse_region_name(name: str) -> tuple[tuple[int, int], str] | None | bool:
	"""((x, z), kind) for a canonical region file name inside [-8, 7]; None when the grammar does not
	match; False when it matches but a coordinate is out of range."""
	m = REGION_NAME_RE.fullmatch(name)
	if m is None:
		return None
	loc = (int(m.group(1)), int(m.group(2)))
	if not all(REGION_COORD_MIN <= c <= REGION_COORD_MAX for c in loc):
		return False
	return loc, m.group(3)


def _entry_limit(name: str) -> int:
	if name == "manifest.json":
		return ZIP_ENVELOPE["max_manifest_bytes"]
	if name == LOCK_PATH:
		return ZIP_ENVELOPE_V4["max_lock_bytes"]
	if name == "objects.json":
		return ZIP_ENVELOPE["max_objects_bytes"]
	if name == SCATTER_PATH:
		return ZIP_ENVELOPE["max_scatter_bytes"]
	if name == PATHS_PATH:
		return ZIP_ENVELOPE["max_paths_bytes"]
	return REGION_MAP_BYTES


EOCD_SIZE = 22
EOCD_SEARCH = EOCD_SIZE + 65535
SIG_EOCD = b"PK\x05\x06"
SIG_ZIP64_LOCATOR = b"PK\x06\x07"


def _zip64_locator_present(tail: bytes, eocd: int) -> bool:
	"""minizip uses ANY ZIP64 locator in the last 64 KiB whose disk fields are 0 and 1; Python
	looks only right before the end record. Mirrors ZipInspector._has_zip64_locator."""
	if eocd >= 20 and tail[eocd - 20:eocd - 16] == SIG_ZIP64_LOCATOR:
		return True
	i = tail.find(SIG_ZIP64_LOCATOR, max(0, len(tail) - 0xFFFF))
	while 0 <= i <= len(tail) - 20:
		if struct.unpack_from("<I", tail, i + 4)[0] == 0 and struct.unpack_from("<I", tail, i + 16)[0] == 1:
			return True
		i = tail.find(SIG_ZIP64_LOCATOR, i + 1)
	return False


def _archive_layout_error(path: Path) -> str:
	"""End-record rules mirrored from ZipInspector. zipfile silently tolerates trailing data,
	comments and data prepended before the central directory (it shifts every offset), so
	without these checks the two validators would disagree on such packages."""
	size = path.stat().st_size
	if size > PACKAGE_MAX_FILE_BYTES:
		return "package file is %d bytes (limit %d)" % (size, PACKAGE_MAX_FILE_BYTES)
	with open(path, "rb") as f:
		f.seek(max(0, size - EOCD_SEARCH))
		tail = f.read()
	eocd = len(tail) - EOCD_SIZE
	last = tail.rfind(SIG_EOCD)
	if eocd < 0 or last < 0:
		return "not a readable ZIP package: no end-of-central-directory record"
	if last != eocd:
		return "archive has data after its end-of-central-directory record"
	_, disk, cd_disk, here, total, cd_size, cd_offset, comment = struct.unpack_from("<IHHHHIIH", tail, eocd)
	if comment != 0:
		return "archive comments are not allowed"
	if total == 0xFFFF or 0xFFFFFFFF in (cd_size, cd_offset) or _zip64_locator_present(tail, eocd):
		return "ZIP64 packages are not supported"
	if disk != 0 or cd_disk != 0 or here != total:
		return "multi-disk archives are not supported"
	if total == 0 or total > PACKAGE_MAX_ENTRIES_V4:
		return "archive has %d entries, allowed 1..%d" % (total, PACKAGE_MAX_ENTRIES_V4)
	if cd_offset + cd_size != size - EOCD_SIZE:
		return "central directory is not immediately followed by the end record (prepended or inserted data)"
	return ""


def _entry_uses_zip64(info: zipfile.ZipInfo) -> bool:
	extra = info.extra
	i = 0
	while i + 4 <= len(extra):
		hid, ln = struct.unpack("<HH", extra[i:i + 4])
		if hid == 0x0001:
			return True
		i += 4 + ln
	return info.file_size >= 0xFFFFFFFF or info.compress_size >= 0xFFFFFFFF or info.header_offset >= 0xFFFFFFFF


def _check_entry_name(info: zipfile.ZipInfo) -> str:
	# zipfile cuts names at NUL and lets a Unicode-path extra field replace the raw name;
	# ZipInspector only ever sees the raw bytes, so both must be rejected here.
	raw = info.orig_filename
	if raw == "" or "\x00" in raw or raw != info.filename:
		return "entry %s has an empty, NUL-containing or substituted name" % show(raw)
	name = info.filename
	if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
		return "absolute path %s" % show(name)
	if "\\" in name:
		return "backslash in entry name %s" % show(name)
	if ".." in name.split("/"):
		return "path traversal in entry name %s" % show(name)
	if name in FIXED_ENTRIES or name in PACKAGE_ALLOWED_DIRS or name == LOCK_PATH:
		return ""
	parsed = parse_region_name(name)
	if parsed is None:
		return "unknown entry %s" % show(name)
	if parsed is False:
		return "entry %s names a region outside [%d, %d]" % (show(name), REGION_COORD_MIN, REGION_COORD_MAX)
	return ""


def inspect_zip(path: Path) -> tuple[list[zipfile.ZipInfo], list[str]]:
	"""Central-directory checks performed BEFORE any extraction."""
	path = Path(path)
	try:
		layout_error = _archive_layout_error(path)
		if layout_error:
			return [], [layout_error]
		with zipfile.ZipFile(path) as zf:
			infos = zf.infolist()
	except (zipfile.BadZipFile, OSError, ValueError) as e:
		return [], ["not a readable ZIP package: %s" % show(str(e), 200)]
	errors: list[str] = []
	seen: set[str] = set()
	regions: dict[tuple[int, int], set[str]] = {}
	total = 0
	for info in infos:
		name = info.filename
		err = _check_entry_name(info)
		if err:
			errors.append(err)
		if name in seen:
			errors.append("duplicate entry %s" % show(name))
		seen.add(name)
		if _entry_uses_zip64(info):
			errors.append("entry %s uses ZIP64 fields; ZIP64 packages are not supported" % show(name))
		mode = (info.external_attr >> 16) & 0o170000
		if mode == 0o120000:
			errors.append("symlink entry %s" % show(name))
		if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
			errors.append("entry %s uses unsupported compression %d" % (show(name), info.compress_type))
		if info.flag_bits & 0x41:
			errors.append("entry %s is encrypted" % show(name))
		if err or name.endswith("/"):
			if name.endswith("/") and info.file_size != 0:
				errors.append("directory entry %s has data" % show(name))
			continue
		parsed = parse_region_name(name)
		if parsed:
			regions.setdefault(parsed[0], set()).add(parsed[1])
		limit = _entry_limit(name)
		if name.startswith("regions/") and info.file_size != REGION_MAP_BYTES:
			errors.append("entry '%s' is %d bytes, expected %d" % (name, info.file_size, REGION_MAP_BYTES))
		elif info.file_size > limit:
			errors.append("entry '%s' is %d bytes (limit %d)" % (name, info.file_size, limit))
		total += info.file_size
	if len(infos) > PACKAGE_MAX_ENTRIES and LOCK_PATH not in seen:
		errors.append("archive has %d entries, allowed 1..%d" % (len(infos), PACKAGE_MAX_ENTRIES))
	if total > PACKAGE_MAX_TOTAL_BYTES:
		errors.append("package expands to %d bytes (limit %d)" % (total, PACKAGE_MAX_TOTAL_BYTES))
	for name in FIXED_ENTRIES:
		if name not in seen:
			errors.append("missing entry '%s'" % name)
	if not regions and not any(e.startswith("regions/r_") for e in seen):
		errors.append("package has no regions")
	for loc in sorted(regions, key=lambda l: (l[1], l[0])):
		for kind in REGION_KINDS:
			if kind not in regions[loc]:
				errors.append("missing entry '%s.%s'" % (region_stem(loc), kind))
	return infos, errors


def safe_extract(path: Path) -> tuple[Path | None, list[str]]:
	"""inspect_zip, then extract into a new temporary directory, checking actual sizes.
	The caller owns (and must delete) the returned directory."""
	infos, errors = inspect_zip(path)
	if errors:
		return None, errors
	dest = Path(tempfile.mkdtemp(prefix="worldpoc_"))
	try:
		with zipfile.ZipFile(path) as zf:
			for info in infos:
				if info.filename.endswith("/"):
					continue
				target = dest / info.filename
				target.parent.mkdir(parents=True, exist_ok=True)
				with zf.open(info) as src:
					data = src.read(info.file_size + 1)
				if len(data) != info.file_size:
					errors.append("entry '%s' decompressed to %d bytes, central directory says %d"
						% (info.filename, len(data), info.file_size))
					break
				target.write_bytes(data)
	except (zipfile.BadZipFile, OSError, EOFError, ValueError, zlib.error) as e:
		errors.append("extraction failed: %s" % show(str(e), 200))
	if errors:
		shutil.rmtree(dest, ignore_errors=True)
		return None, errors
	return dest, []


def schema_error(path: Path) -> str:
	"""Explicit unknown-schema diagnostic for a package whose manifest names another schema.
	Such packages (e.g. schema 1) also fail the entry-set check; this names the real cause."""
	try:
		with zipfile.ZipFile(path) as zf:
			info = zf.getinfo("manifest.json")
			if info.file_size > ZIP_ENVELOPE["max_manifest_bytes"]:
				return ""
			manifest = parse_json_bytes(zf.read(info))
	except (zipfile.BadZipFile, OSError, KeyError, ValueError, FormatError, EOFError, zlib.error):
		return ""
	version = manifest.get("schema_version") if isinstance(manifest, dict) else None
	if is_supported_schema(version):
		return ""
	return _unknown_schema(version)


def write_package(gen_dir: Path, out_path: Path, layout: Layout | None = None) -> None:
	"""Deterministic .worldpoc (deflate, fixed timestamps) from a generation directory. `layout`
	defaults to the one named by the directory's manifest (legacy when unreadable)."""
	schema = 0
	try:
		m = parse_json_bytes((Path(gen_dir) / "manifest.json").read_bytes())
		schema = int(m["schema_version"]) if isinstance(m, dict) and is_supported_schema(m.get("schema_version")) else 0
		if layout is None:
			layout = manifest_layout(m)[0] or LEGACY_LAYOUT
	except (OSError, FormatError):
		layout = layout or LEGACY_LAYOUT
	layout = layout or LEGACY_LAYOUT
	with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
		for name in ["manifest.json"] + payload_paths(layout, schema):
			info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
			info.compress_type = zipfile.ZIP_DEFLATED
			info.external_attr = 0o100644 << 16
			zf.writestr(info, (Path(gen_dir) / name).read_bytes())
