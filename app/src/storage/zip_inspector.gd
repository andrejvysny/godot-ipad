class_name ZipInspector
extends RefCounted
## Parses a .worldpoc central directory from raw bytes BEFORE anything is extracted
## (docs/world-format.md §7). Only the exact generation layout is accepted; anything that
## could escape the extraction directory, expand unboundedly, or need ZIP64 is rejected.

const SIG_EOCD := 0x06054b50
const SIG_CENTRAL := 0x02014b50
const SIG_LOCAL := 0x04034b50
const SIG_ZIP64_LOCATOR := 0x07064b50
const EOCD_SIZE := 22
const EOCD_SEARCH := 65557  # 22-byte record + max 65535-byte comment
const CENTRAL_HEADER_SIZE := 46
const LOCAL_HEADER_SIZE := 30
const ZIP64_EXTRA_ID := 0x0001
const FLAG_ENCRYPTED := 0x0001
const FLAG_STRONG_ENCRYPTION := 0x0040
const FLAG_DATA_DESCRIPTOR := 0x0008
const METHOD_STORED := 0
const METHOD_DEFLATE := 8
const S_IFMT := 0xF000
const S_IFLNK := 0xA000
const REGIONS_DIR := "regions/"


static func default_limits() -> Dictionary:
	return {
		"max_file_bytes": 20 * 1024 * 1024,
		"max_total_uncompressed": 12 * 1024 * 1024,
		"max_entries": 20,
		"max_manifest_bytes": WorldCodec.MAX_MANIFEST_BYTES,
		"max_objects_bytes": WorldCodec.MAX_OBJECTS_BYTES,
		"max_scatter_bytes": WorldCodec.MAX_SCATTER_BYTES,
		"max_paths_bytes": WorldCodec.MAX_PATHS_BYTES,
	}


## Returns {ok, error, entries: [{name, method, compressed, uncompressed, is_dir}]}.
static func inspect(path: String, limits: Dictionary = {}) -> Dictionary:
	var lim := default_limits()
	lim.merge(limits, true)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _fail("cannot open package '%s' (error %d)" % [path, FileAccess.get_open_error()])
	if f.get_length() > int(lim.max_file_bytes):
		return _fail("package is %d bytes, limit %d" % [f.get_length(), int(lim.max_file_bytes)])
	var data := f.get_buffer(f.get_length())
	f.close()
	return inspect_bytes(data, lim)


static func inspect_bytes(data: PackedByteArray, lim: Dictionary) -> Dictionary:
	var err := _end_record_error(data)
	if err != "":
		return _fail(err)
	var eocd := data.size() - EOCD_SIZE
	var disk := data.decode_u16(eocd + 4)
	var cd_disk := data.decode_u16(eocd + 6)
	var entries_here := data.decode_u16(eocd + 8)
	var total := data.decode_u16(eocd + 10)
	var cd_size := data.decode_u32(eocd + 12)
	var cd_offset := data.decode_u32(eocd + 16)
	if total == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF or _has_zip64_locator(data, eocd):
		return _fail("ZIP64 archives are not supported")
	if disk != 0 or cd_disk != 0 or entries_here != total:
		return _fail("multi-disk archives are not supported")
	if total == 0 or total > int(lim.max_entries):
		return _fail("archive has %d entries, allowed 1..%d" % [total, int(lim.max_entries)])
	if cd_offset + cd_size > eocd:
		return _fail("central directory lies outside the archive")
	# minizip shifts every offset by any gap here, so a gap would make it read other bytes.
	if cd_offset + cd_size != eocd:
		return _fail("central directory is not immediately followed by the end record")
	var parsed := _parse_central(data, cd_offset, cd_size, total)
	if parsed.error != "":
		return _fail(parsed.error)
	err = _check_layout(parsed.entries, lim)
	if err != "":
		return _fail(err)
	var public: Array = []
	for e in parsed.entries:
		public.append({"name": e.name, "method": e.method, "compressed": e.compressed,
			"uncompressed": e.uncompressed, "is_dir": e.is_dir})
	return {"ok": true, "error": "", "entries": public}


## The inspected central directory must be the one ZIPReader (minizip) will use. minizip takes
## the end record with the HIGHEST offset in the last 64 KiB and ignores its comment length
## (Python's zipfile prefers an end record at size-22 with no comment). Requiring exactly that
## layout, with no end-record signature after it, makes every reader agree with this parser.
static func _end_record_error(data: PackedByteArray) -> String:
	var eocd := data.size() - EOCD_SIZE
	var found := _find_signatures(data, SIG_EOCD, maxi(0, data.size() - EOCD_SEARCH), data.size() - 4)
	if eocd < 0 or found.is_empty():
		return "not a ZIP archive (no end-of-central-directory record)"
	if found[found.size() - 1] != eocd:
		return "archive has data after its end-of-central-directory record"
	if data.decode_u16(eocd + 20) != 0:
		return "archive comments are not allowed"
	return ""


## minizip first looks for ANY ZIP64 locator in the last 64 KiB (and uses it when its disk
## fields are 0 and 1); Python looks only right before the end record. Reject both shapes.
static func _has_zip64_locator(data: PackedByteArray, eocd: int) -> bool:
	if eocd >= 20 and data.decode_u32(eocd - 20) == SIG_ZIP64_LOCATOR:
		return true
	for i in _find_signatures(data, SIG_ZIP64_LOCATOR, maxi(0, data.size() - 0xFFFF), data.size() - 20):
		if data.decode_u32(i + 4) == 0 and data.decode_u32(i + 16) == 1:
			return true
	return false


## Offsets in [from, to] where the little-endian u32 `sig` starts, ascending.
static func _find_signatures(data: PackedByteArray, sig: int, from: int, to: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var i := data.find(sig & 0xFF, maxi(0, from))
	while i >= 0 and i <= to:
		if i + 4 <= data.size() and data.decode_u32(i) == sig:
			out.append(i)
		i = data.find(sig & 0xFF, i + 1)
	return out


static func _parse_central(data: PackedByteArray, cd_offset: int, cd_size: int, total: int) -> Dictionary:
	var entries: Array = []
	var p := cd_offset
	var cd_end := cd_offset + cd_size
	for n in total:
		if p + CENTRAL_HEADER_SIZE > cd_end or data.decode_u32(p) != SIG_CENTRAL:
			return {"entries": [], "error": "central directory record %d is malformed" % n}
		var name_len := data.decode_u16(p + 28)
		var extra_len := data.decode_u16(p + 30)
		var comment_len := data.decode_u16(p + 32)
		var rec_end := p + CENTRAL_HEADER_SIZE + name_len + extra_len + comment_len
		if rec_end > cd_end:
			return {"entries": [], "error": "central directory record %d overruns the directory" % n}
		var e := {
			"flags": data.decode_u16(p + 8),
			"method": data.decode_u16(p + 10),
			"crc": data.decode_u32(p + 16),
			"compressed": data.decode_u32(p + 20),
			"uncompressed": data.decode_u32(p + 24),
			"disk_start": data.decode_u16(p + 34),
			"external_attr": data.decode_u32(p + 38),
			"local_offset": data.decode_u32(p + 42),
			"raw_name": data.slice(p + CENTRAL_HEADER_SIZE, p + CENTRAL_HEADER_SIZE + name_len),
			"extra": data.slice(p + CENTRAL_HEADER_SIZE + name_len, p + CENTRAL_HEADER_SIZE + name_len + extra_len),
		}
		var err := _check_entry(data, e, cd_offset)
		if err != "":
			return {"entries": [], "error": err}
		entries.append(e)
		p = rec_end
	if p != cd_end:
		return {"entries": [], "error": "central directory size does not match its records"}
	return {"entries": entries, "error": ""}


## Fills e.name / e.is_dir and rejects unsafe or unsupported entry encodings.
static func _check_entry(data: PackedByteArray, e: Dictionary, cd_offset: int) -> String:
	var raw: PackedByteArray = e.raw_name
	if raw.is_empty() or raw.has(0):
		return "archive entry has an empty or NUL-containing name"
	var name := raw.get_string_from_utf8()
	if name.to_utf8_buffer() != raw:
		return "archive entry name is not valid UTF-8"
	e.name = name
	e.is_dir = name.ends_with("/")
	var err := _check_name(name)
	if err != "":
		return err
	if e.flags & (FLAG_ENCRYPTED | FLAG_STRONG_ENCRYPTION):
		return "entry '%s' is encrypted" % name
	if e.method != METHOD_STORED and e.method != METHOD_DEFLATE:
		return "entry '%s' uses unsupported compression method %d" % [name, e.method]
	if e.compressed == 0xFFFFFFFF or e.uncompressed == 0xFFFFFFFF or e.local_offset == 0xFFFFFFFF \
			or e.disk_start == 0xFFFF or _has_zip64_extra(e.extra):
		return "entry '%s' uses ZIP64 fields" % name
	if e.disk_start != 0:
		return "entry '%s' is on another disk" % name
	if ((e.external_attr >> 16) & S_IFMT) == S_IFLNK:
		return "entry '%s' is a symbolic link" % name
	if e.method == METHOD_STORED and e.compressed != e.uncompressed:
		return "stored entry '%s' declares mismatched sizes" % name
	return _check_local_header(data, e, cd_offset)


static func _check_name(name: String) -> String:
	if name.begins_with("/") or name.contains("\\") or name.contains(":"):
		return "entry '%s' has an absolute or non-portable path" % name
	for seg in name.trim_suffix("/").split("/"):
		if seg == ".." or seg == "." or seg == "":
			return "entry '%s' contains a '%s' path segment" % [name, seg]
	return ""


## minizip reads the data at the local header's own name/extra lengths and checks only some
## local fields, so every local field that could differ from the central record must match.
static func _check_local_header(data: PackedByteArray, e: Dictionary, cd_offset: int) -> String:
	var lo: int = e.local_offset
	if lo + LOCAL_HEADER_SIZE > cd_offset or data.decode_u32(lo) != SIG_LOCAL:
		return "entry '%s' has no valid local header" % e.name
	var name_len := data.decode_u16(lo + 26)
	var data_start := lo + LOCAL_HEADER_SIZE + name_len + data.decode_u16(lo + 28)
	if data_start + int(e.compressed) > cd_offset:
		return "entry '%s' data overruns the archive" % e.name
	if data.slice(lo + LOCAL_HEADER_SIZE, lo + LOCAL_HEADER_SIZE + name_len) != e.raw_name:
		return "entry '%s' local header names a different file" % e.name
	if data.decode_u16(lo + 6) != e.flags or data.decode_u16(lo + 8) != e.method:
		return "entry '%s' local header flags or method differ from the central directory" % e.name
	var has_descriptor: bool = (e.flags & FLAG_DATA_DESCRIPTOR) != 0
	var pairs := [[data.decode_u32(lo + 14), e.crc], [data.decode_u32(lo + 18), e.compressed],
		[data.decode_u32(lo + 22), e.uncompressed]]
	for pair in pairs:
		if int(pair[0]) != int(pair[1]) and not (has_descriptor and int(pair[0]) == 0):
			return "entry '%s' local header CRC or sizes differ from the central directory" % e.name
	return ""


static func _has_zip64_extra(extra: PackedByteArray) -> bool:
	var i := 0
	while i + 4 <= extra.size():
		if extra.decode_u16(i) == ZIP64_EXTRA_ID:
			return true
		i += 4 + extra.decode_u16(i + 2)
	return false


static func _check_layout(entries: Array, lim: Dictionary) -> String:
	var required := WorldCodec.payload_paths()
	required.append(WorldCodec.MANIFEST_FILE)
	var seen := {}
	var total := 0
	for e in entries:
		var name: String = e.name
		if seen.has(name):
			return "duplicate archive entry '%s'" % name
		seen[name] = true
		if e.is_dir:
			if name != REGIONS_DIR or e.uncompressed != 0:
				return "unexpected archive directory '%s'" % name
			continue
		if not required.has(name):
			return "unknown archive entry '%s'" % name
		var size: int = e.uncompressed
		var limit_err := _entry_limit_error(name, size, lim)
		if limit_err != "":
			return limit_err
		total += size
	if total > int(lim.max_total_uncompressed):
		return "package expands to %d bytes, limit %d" % [total, int(lim.max_total_uncompressed)]
	for name in required:
		if not seen.has(name):
			return "package is missing '%s'" % name
	return ""


static func _entry_limit_error(name: String, size: int, lim: Dictionary) -> String:
	if WorldCodec.is_region_path(name) and size != WorldConstants.REGION_MAP_BYTES:
		return "entry '%s' declares %d bytes, region files are exactly %d" % [name, size, WorldConstants.REGION_MAP_BYTES]
	if name == WorldCodec.MANIFEST_FILE and size > int(lim.max_manifest_bytes):
		return "manifest.json declares %d bytes, limit %d" % [size, int(lim.max_manifest_bytes)]
	if name == WorldCodec.OBJECTS_FILE and size > int(lim.max_objects_bytes):
		return "objects.json declares %d bytes, limit %d" % [size, int(lim.max_objects_bytes)]
	if name == WorldConstants.SCATTER_FILE and size > int(lim.max_scatter_bytes):
		return "scatter.bin declares %d bytes, limit %d" % [size, int(lim.max_scatter_bytes)]
	if name == WorldConstants.PATHS_FILE and size > int(lim.max_paths_bytes):
		return "paths.bin declares %d bytes, limit %d" % [size, int(lim.max_paths_bytes)]
	return ""


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "entries": []}
