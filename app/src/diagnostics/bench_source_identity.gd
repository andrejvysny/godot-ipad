class_name BenchSourceIdentity
extends RefCounted
## Runtime source identity is distinct from the installed export fingerprint. Capture outside timing windows.

const ROOTS: Array[String] = ["src", "scenes", "assets", "config"]
const SCOPE := "res://src,scenes,assets,config,project.godot; excludes uid/import/cache/build_fingerprint"


static func capture(project_root: String = "res://", local_sources: bool = OS.has_feature("editor")) -> Dictionary:
	var result := {"live_source_sha256": null, "live_source_validity": "UNAVAILABLE_EXPORTED_BUILD",
		"live_source_scope": SCOPE, "source_commit": null, "source_dirty": null, "git_validity": "UNAVAILABLE"}
	if not local_sources:
		return result
	var files: Array[String] = []
	for folder in ROOTS:
		_collect(project_root.path_join(folder), files)
	files.append(project_root.path_join("project.godot"))
	var digest := digest_files(project_root, files)
	result.live_source_sha256 = digest.sha256
	result.live_source_validity = digest.validity
	var root := ProjectSettings.globalize_path(project_root).trim_suffix("/")
	var repo := root.get_base_dir()
	# A copied benchmark sandbox has no repository identity, even if an ancestor is a checkout.
	if not DirAccess.dir_exists_absolute(repo.path_join(".git")) and not FileAccess.file_exists(repo.path_join(".git")):
		return result
	var output: Array = []
	if OS.execute("git", ["-C", repo, "rev-parse", "HEAD"], output, true) != 0:
		return result
	result.source_commit = str(output[0]).strip_edges() if not output.is_empty() else null
	output.clear()
	if OS.execute("git", ["-C", repo, "status", "--porcelain", "--untracked-files=normal"], output, true) == 0:
		result.source_dirty = not output.is_empty() and not str(output[0]).strip_edges().is_empty()
		result.git_validity = "AVAILABLE"
	return result


static func digest_files(project_root: String, paths: Array[String]) -> Dictionary:
	var sorted := paths.duplicate()
	sorted.sort()
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for path in sorted:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return {"sha256": null, "validity": "UNAVAILABLE_SOURCE_READ"}
		var bytes := file.get_buffer(file.get_length())
		if bytes.size() != file.get_length():
			return {"sha256": null, "validity": "UNAVAILABLE_SOURCE_READ"}
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(bytes)
		context.update(path.trim_prefix(project_root.trim_suffix("/") + "/").to_utf8_buffer())
		context.update(PackedByteArray([0]))
		context.update(hash.finish())
	return {"sha256": context.finish().hex_encode(), "validity": "AVAILABLE_LOCAL_SOURCE"}


static func _collect(folder: String, files: Array[String]) -> void:
	var directory := DirAccess.open(folder)
	if directory == null:
		return
	for name in directory.get_files():
		if name.ends_with(".uid") or name.ends_with(".import") or name.ends_with(".pyc") \
				or name in ["build_fingerprint.json", "local.signing.json"]:
			continue
		files.append(folder.path_join(name))
	for name in directory.get_directories():
		if name not in [".godot", "__pycache__", ".git"]:
			_collect(folder.path_join(name), files)
