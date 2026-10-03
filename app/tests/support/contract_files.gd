class_name ContractFiles
extends RefCounted
## Locates the repo's contracts/world-painter/world-v4 files from the project directory, which is app/ in the
## checkout and build/test_sandboxes/<name>/app in a sandbox copy.

const WORLD_V4 := "contracts/world-painter/world-v4"


## Absolute path of `rel` below contracts/world-painter/world-v4/ ("" is the directory itself).
static func path(rel: String = "") -> String:
	var project := ProjectSettings.globalize_path("res://")
	for up in ["../", "../../../../"]:
		var dir := project.path_join(up + WORLD_V4).simplify_path()
		if DirAccess.dir_exists_absolute(dir):
			return dir.path_join(rel) if rel != "" else dir
	return project.path_join("../" + WORLD_V4 + "/" + rel).simplify_path()
