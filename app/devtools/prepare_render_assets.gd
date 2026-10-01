extends SceneTree
## Offline render-asset preparation (docs/render-assets.md §6). Run from the repo root:
##   godot --headless --path app --script res://devtools/prepare_render_assets.gd -- <manifest> [--require-import]
## <manifest> is a res:// path, e.g. res://devtools/render_prep/poc_nature.json. Texture import runs
## outside this process (godot --import); scripts/dev.py prepare-render-assets orchestrates both
## and passes --require-import on the verification pass. Exit code 1 on any error.

const Baker := preload("res://devtools/render_prep/baker.gd")
const Writer := preload("res://devtools/render_prep/descriptor_writer.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: prepare_render_assets.gd -- <manifest res path> [--require-import]")
		quit(2)
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(args[0])) != OK or typeof(json.data) != TYPE_DICTIONARY:
		printerr("cannot read manifest %s" % args[0])
		quit(2)
		return
	var manifest: Dictionary = json.data
	var baker := Baker.new()
	baker.require_import = args.has("--require-import")
	var report := baker.prepare_catalog(manifest)
	var report_path := Baker.resolve_input(str(manifest.report))
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var f := FileAccess.open(report_path, FileAccess.WRITE)
	f.store_string(Writer.to_json(report) + "\n")
	f.close()
	for a: Dictionary in report.assets:
		var parts: PackedStringArray = []
		for role in Baker.ROLES:
			parts.append("%s=%s" % [role, str(a.roles[role].triangles) if a.roles.has(role) else "alias"])
		print("%s: %s gpu=%d B" % [a.asset_id, " ".join(parts), a.gpu_bytes])
	for w in report.warnings:
		print("warning: " + str(w))
	for e in report.errors:
		printerr("ERROR: " + str(e))
	print("report: %s (%d assets, %d errors, total gpu %d B)" % [report_path, report.assets.size(), report.errors.size(), report.total_gpu_bytes])
	quit(1 if not report.errors.is_empty() else 0)
