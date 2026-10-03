class_name LiveSpool
extends RefCounted
## Bounded chain of committed delta archives that the receiver has not acknowledged (ADR 0015 L4): at most
## `max_ops` operations and `max_bytes` bytes in total. Small entries stay in memory (up to `memory_bytes` in
## total); everything else stays in the file it was built in, under `<root>/<stream>/` (disk spill, user://live/spool
## by default). Entries are contiguous: each base_revision is the previous target_revision.

const DEFAULT_ROOT := "user://live/spool"

var max_ops := 128
var max_bytes := 128 * 1024 * 1024
var memory_bytes := 8 * 1024 * 1024
var root := DEFAULT_ROOT

var _stream := ""
var _entries: Array = []  # {base_revision, target_revision, base_hash, target_hash, operation_id, size, bytes|path}
var _total := 0
var _resident := 0


func _init(p_root: String = DEFAULT_ROOT) -> void:
	root = p_root


func stream_dir(stream_id: String) -> String:
	return root.path_join(stream_id)


## Directory entries of `stream_id` are written to (created on demand).
func entry_path(stream_id: String, target_revision: int) -> String:
	StorageFs.make_dir(stream_dir(stream_id))
	return stream_dir(stream_id).path_join("%010d.delta" % target_revision)


## Takes ownership of the archive at `path`; small ones are read into memory and the file is deleted.
## Returns false (nothing stored) when the file cannot be read. Check overflowed() afterwards.
func add(stream_id: String, meta: Dictionary, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var entry := meta.duplicate()
	entry["size"] = f.get_length()
	_stream = stream_id
	if int(entry.size) * 8 <= memory_bytes and _resident + int(entry.size) <= memory_bytes:
		entry["bytes"] = f.get_buffer(f.get_length())
		f.close()
		DirAccess.remove_absolute(path)
		_resident += int(entry.size)
	else:
		f.close()
		entry["path"] = path
	_entries.append(entry)
	_total += int(entry.size)
	return true


func count() -> int:
	return _entries.size()


func total_bytes() -> int:
	return _total


func resident_bytes() -> int:
	return _resident


func overflowed() -> bool:
	return _entries.size() > max_ops or _total > max_bytes


func entry_for(target_revision: int) -> Dictionary:
	for e: Dictionary in _entries:
		if int(e.target_revision) == target_revision:
			return e
	return {}


## The contiguous entries after (revision, hash), or null when the chain cannot continue exactly from there.
func chain_after(revision: int, hash: String, current_revision: int) -> Variant:
	if revision == current_revision:
		return []
	var out: Array = []
	var want_rev := revision
	var want_hash := hash
	for e: Dictionary in _entries:
		if int(e.target_revision) <= revision:
			continue
		if int(e.base_revision) != want_rev or e.base_hash != want_hash:
			return null
		out.append(e)
		want_rev = int(e.target_revision)
		want_hash = e.target_hash
	return out if want_rev == current_revision else null


## Framer over an entry's archive (memory or file); null when the file vanished.
static func framer_of(entry: Dictionary, transfer_id: String) -> LiveBlobFramer:
	if entry.has("bytes"):
		return LiveBlobFramer.from_bytes(transfer_id, entry.bytes)
	return LiveBlobFramer.from_file(transfer_id, entry.path)


## Drops every entry up to and including `revision` (the receiver installed it).
func ack(revision: int) -> void:
	while not _entries.is_empty() and int((_entries[0] as Dictionary).target_revision) <= revision:
		_drop(_entries.pop_front())


func clear() -> void:
	for e: Dictionary in _entries:
		_drop(e)
	_entries.clear()
	if _stream != "":
		StorageFs.remove_tree(stream_dir(_stream))
	_total = 0
	_resident = 0


func _drop(entry: Dictionary) -> void:
	_total -= int(entry.size)
	if entry.has("bytes"):
		_resident -= int(entry.size)
	elif FileAccess.file_exists(entry.path):
		DirAccess.remove_absolute(entry.path)
