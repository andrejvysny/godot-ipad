class_name ZipTestBuilder
extends RefCounted
## Crafts ZIP archives byte by byte so tests can feed ZipInspector malicious layouts that
## ZIPPacker would never produce. Entries are stored (data written as-is) with CRC 0 unless
## overridden, so extracting one with ZIPReader fails its CRC check.
##
## Per-entry overrides: method, flags, external_attr, declared_uncompressed,
## declared_compressed, disk_start, extra (PackedByteArray), crc; local-header-only overrides
## local_name, local_flags, local_method, local_crc, local_compressed, local_uncompressed.
## Archive overrides for build(): disk, cd_disk, total_entries, entries_here, cd_size,
## cd_offset, zip64_locator (bool), gap (bytes between the central directory and the end
## record), comment (bytes), comment_len (declared, defaults to comment size), trailer (bytes
## after the comment).

var _entries: Array = []


func add(name: String, data: PackedByteArray = PackedByteArray(), overrides: Dictionary = {}) -> ZipTestBuilder:
	var e := {"name": name, "data": data, "method": 0, "flags": 0, "external_attr": 0x81A4 << 16,
		"disk_start": 0, "extra": PackedByteArray()}
	e.merge(overrides, true)
	_entries.append(e)
	return self


## The exact accepted layout: regions/ dir, manifest, objects, 8 correctly sized regions.
static func valid_layout() -> ZipTestBuilder:
	var b := ZipTestBuilder.new()
	b.add("manifest.json", "{}".to_utf8_buffer())
	b.add("objects.json", "{}".to_utf8_buffer())
	b.add("regions/", PackedByteArray(), {"external_attr": 0x41ED << 16})
	var region := PackedByteArray()
	region.resize(WorldConstants.REGION_MAP_BYTES)
	for path in WorldCodec.payload_paths():
		if WorldCodec.is_region_path(path):
			b.add(path, region)
	return b


func build(archive: Dictionary = {}) -> PackedByteArray:
	var out := PackedByteArray()
	var central := PackedByteArray()
	for e in _entries:
		var name: PackedByteArray = String(e.name).to_utf8_buffer()
		var data: PackedByteArray = e.data
		var comp: int = e.get("declared_compressed", data.size())
		var uncomp: int = e.get("declared_uncompressed", data.size())
		var crc: int = e.get("crc", 0)
		var local_name: PackedByteArray = String(e.get("local_name", e.name)).to_utf8_buffer()
		var offset := out.size()
		out.append_array(_u32(ZipInspector.SIG_LOCAL) + _u16(20) + _u16(e.get("local_flags", e.flags))
			+ _u16(e.get("local_method", e.method)) + _u32(0) + _u32(e.get("local_crc", crc))
			+ _u32(e.get("local_compressed", comp)) + _u32(e.get("local_uncompressed", uncomp))
			+ _u16(local_name.size()) + _u16(0))
		out.append_array(local_name)
		out.append_array(data)
		var extra: PackedByteArray = e.extra
		central.append_array(_u32(ZipInspector.SIG_CENTRAL) + _u16(0x031E) + _u16(20) + _u16(e.flags)
			+ _u16(e.method) + _u32(0) + _u32(crc) + _u32(comp) + _u32(uncomp) + _u16(name.size())
			+ _u16(extra.size()) + _u16(0) + _u16(e.disk_start) + _u16(0) + _u32(e.external_attr)
			+ _u32(offset))
		central.append_array(name)
		central.append_array(extra)
	var cd_offset := out.size()
	out.append_array(central)
	if archive.get("zip64_locator", false):
		out.append_array(zip64_locator())
	out.append_array(archive.get("gap", PackedByteArray()))
	var n: int = _entries.size()
	var comment: PackedByteArray = archive.get("comment", PackedByteArray())
	out.append_array(_u32(ZipInspector.SIG_EOCD) + _u16(archive.get("disk", 0)) + _u16(archive.get("cd_disk", 0))
		+ _u16(archive.get("entries_here", archive.get("total_entries", n))) + _u16(archive.get("total_entries", n))
		+ _u32(archive.get("cd_size", central.size())) + _u32(archive.get("cd_offset", cd_offset))
		+ _u16(archive.get("comment_len", comment.size())))
	out.append_array(comment)
	out.append_array(archive.get("trailer", PackedByteArray()))
	return out


## A ZIP64 end-of-central-directory locator that minizip would act on (disk 0 of 1 disk).
static func zip64_locator() -> PackedByteArray:
	return _u32(ZipInspector.SIG_ZIP64_LOCATOR) + _u32(0) + _u32(0) + _u32(0) + _u32(1)


## Appends, inside the comment of `zip`'s end record, a second central directory + end record
## in which `entry` declares `declared_uncompressed` bytes. minizip reads the LAST end record,
## so this is the directory ZIPReader would extract from. `inner_comment_len` is the second
## end record's declared comment length (non-zero hides it from parsers that require the
## comment to reach the end of the file). `zip` must have no comment.
static func hide_directory_in_comment(zip: PackedByteArray, entry: String, declared_uncompressed: int,
		inner_comment_len: int) -> PackedByteArray:
	var out := zip.duplicate()
	var eocd := out.size() - ZipInspector.EOCD_SIZE
	var cd_offset := out.decode_u32(eocd + 16)
	var cd := out.slice(cd_offset, eocd)
	var p := 0
	while p + ZipInspector.CENTRAL_HEADER_SIZE <= cd.size():
		var name_len := cd.decode_u16(p + 28)
		var name := cd.slice(p + 46, p + 46 + name_len).get_string_from_utf8()
		if name == entry:
			cd.encode_u32(p + 24, declared_uncompressed)
		p += ZipInspector.CENTRAL_HEADER_SIZE + name_len + cd.decode_u16(p + 30) + cd.decode_u16(p + 32)
	var inner_eocd := out.slice(eocd)
	inner_eocd.encode_u32(16, out.size())  # the hidden directory starts right after the real end record
	inner_eocd.encode_u16(20, inner_comment_len)
	var comment := cd + inner_eocd
	out.encode_u16(eocd + 20, comment.size())
	out.append_array(comment)
	return out


func save(path: String, archive: Dictionary = {}) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(build(archive))
	f.close()


static func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v & 0xFFFF)
	return b


static func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v & 0xFFFFFFFF)
	return b
