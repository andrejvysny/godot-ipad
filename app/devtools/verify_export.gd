extends SceneTree
## Export verification (dev.py verify-export, spec §17). Run in an EMPTY temporary project so that res:// holds
## only the mounted pack: `-- <pck> <required.json>`. required.json: {"required": [{"label", "any_of": [res://..]}],
## "forbidden_dirs": [res://..]}. An entry passes when any alternative (or its .remap) is in the pack. Exits 1 on a
## missing required entry or a forbidden directory, 2 on unusable input. Excluded from the export (devtools/*).


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		print("VERIFY_EXPORT error: expected <pck> <required.json>")
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	if typeof(parsed) != TYPE_DICTIONARY:
		print("VERIFY_EXPORT error: unreadable %s" % args[1])
		quit(2)
		return
	if not ProjectSettings.load_resource_pack(args[0], false):
		print("VERIFY_EXPORT error: cannot mount %s" % args[0])
		quit(2)
		return
	var spec: Dictionary = parsed
	var missing := 0
	var checked := 0
	for item: Dictionary in spec.required:
		checked += 1
		if not _present(item.any_of):
			missing += 1
			print("VERIFY_EXPORT MISSING %s: %s" % [item.label, ", ".join(item.any_of)])
	var unexpected := 0
	for dir: String in spec.forbidden_dirs:
		if DirAccess.dir_exists_absolute(dir):
			unexpected += 1
			print("VERIFY_EXPORT UNEXPECTED %s is in the pack" % dir)
	print("VERIFY_EXPORT %s checked=%d missing=%d unexpected=%d" % [
			"OK" if missing + unexpected == 0 else "FAILED", checked, missing, unexpected])
	quit(0 if missing + unexpected == 0 else 1)


func _present(candidates: Array) -> bool:
	for path: String in candidates:
		if FileAccess.file_exists(path) or FileAccess.file_exists(path + ".remap"):
			return true
	return false
