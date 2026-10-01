class_name StorageFs
extends RefCounted
## File helpers that report failures as strings instead of logging engine errors.
## Thread-safe: used by the storage worker with plain values only.


## Returns [PackedByteArray, ""] or [PackedByteArray(), error].
static func read_bytes(path: String, max_bytes: int = -1) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [PackedByteArray(), "cannot open '%s' for reading (error %d)" % [path, FileAccess.get_open_error()]]
	var n := f.get_length()
	if max_bytes >= 0 and n > max_bytes:
		return [PackedByteArray(), "'%s' is %d bytes, limit %d" % [path, n, max_bytes]]
	var data := f.get_buffer(n)
	if data.size() != n or f.get_error() != OK:
		return [PackedByteArray(), "short read of '%s' (%d of %d bytes)" % [path, data.size(), n]]
	return [data, ""]


## Writes, flushes, and closes; checks every step.
static func write_bytes(path: String, data: PackedByteArray) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot open '%s' for writing (error %d)" % [path, FileAccess.get_open_error()]
	if not f.store_buffer(data):
		f.close()
		return "write to '%s' failed (error %d)" % [path, f.get_error()]
	f.flush()
	var err := f.get_error()
	f.close()
	if err != OK:
		return "flush of '%s' failed (error %d)" % [path, err]
	return ""


static func make_dir(path: String) -> String:
	# A file in the way makes DirAccess log an engine error; detect it and return a string.
	var p := path
	while not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			return "cannot create directory '%s': '%s' is a file" % [path, p]
		var parent := p.get_base_dir()
		if parent == p or parent == "":
			break
		p = parent
	var err := DirAccess.make_dir_recursive_absolute(path)
	return "" if err == OK else "cannot create directory '%s' (error %d)" % [path, err]


static func list_dirs(path: String) -> PackedStringArray:
	var d := DirAccess.open(path)
	if d == null:
		return PackedStringArray()
	var out := d.get_directories()
	out.sort()
	return out


## Recursively deletes `path`. Returns "" when it no longer exists.
static func remove_tree(path: String) -> String:
	var d := DirAccess.open(path)
	if d == null:
		return "" if not DirAccess.dir_exists_absolute(path) else "cannot open '%s'" % path
	d.include_hidden = true
	for f in d.get_files():
		if d.remove(f) != OK:
			return "cannot delete '%s'" % path.path_join(f)
	for sub in d.get_directories():
		var err := remove_tree(path.path_join(sub))
		if err != "":
			return err
	if DirAccess.remove_absolute(path) != OK:
		return "cannot delete directory '%s'" % path
	return ""


static func random_hex(n_bytes: int = 8) -> String:
	return Crypto.new().generate_random_bytes(n_bytes).hex_encode()
