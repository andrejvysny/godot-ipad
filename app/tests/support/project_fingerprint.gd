class_name ProjectFingerprint
extends RefCounted
## Cheap change detector for a directory tree: path, size and modification time of every file (the engine's own
## `.godot` cache excluded). Used to prove a live session writes nothing under res://.


static func of(root: String) -> String:
	var lines := PackedStringArray()
	_walk(root, "", lines)
	lines.sort()
	return "\n".join(lines).sha256_text()


static func _walk(root: String, rel: String, lines: PackedStringArray) -> void:
	var dir := root.path_join(rel)
	for name in DirAccess.get_files_at(dir):
		var path := dir.path_join(name)
		var f := FileAccess.open(path, FileAccess.READ)
		lines.append("%s|%d|%d" % [rel.path_join(name), f.get_length() if f != null else -1, FileAccess.get_modified_time(path)])
	for name in DirAccess.get_directories_at(dir):
		if rel == "" and name == ".godot":
			continue
		_walk(root, rel.path_join(name), lines)


static func file_count(root: String) -> int:
	var lines := PackedStringArray()
	_walk(root, "", lines)
	return lines.size()
