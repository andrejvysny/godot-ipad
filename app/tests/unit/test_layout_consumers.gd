extends TestCase
## WP04b: nothing may use the legacy 2x2 layout constants any more; every consumer takes the
## document's WorldLayout. The constants are deleted, so this guards against them returning.

const ROOTS := ["res://src", "res://addons/world_painter", "res://tests", "res://devtools"]


func _gd_files(dir: String, out: PackedStringArray) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_gd_files(dir.path_join(sub), out)
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			out.append(dir.path_join(file))


func test_no_source_uses_the_removed_legacy_layout_constants() -> void:
	# Assembled at run time so this file does not match itself.
	var names := ["WORLD_" + "MIN", "WORLD_MAX_" + "SAMPLE", "REGION_" + "LOCATIONS", "GLOBAL_SAMPLE_" + "M\\w*",
		"is_inside_" + "world", "is_valid_" + "region", "is_valid_" + "sample"]
	var regex := RegEx.create_from_string("WorldConstants\\.(" + "|".join(names) + ")")
	var files := PackedStringArray()
	for root: String in ROOTS:
		_gd_files(root, files)
	assert_true(files.size() > 100, "scanned %d files" % files.size())
	for path in files:
		var hit := regex.search(FileAccess.get_file_as_string(path))
		assert_true(hit == null, "%s still uses %s" % [path, hit.get_string() if hit != null else ""])


func test_world_constants_no_longer_declares_a_fixed_layout() -> void:
	var constants: Dictionary = WorldConstants.new().get_script().get_script_constant_map()
	for name: String in ["WORLD_" + "MIN", "WORLD_MAX_" + "SAMPLE", "REGION_" + "LOCATIONS", "GLOBAL_SAMPLE_" + "MIN", "GLOBAL_SAMPLE_" + "MAX"]:
		assert_false(constants.has(name), "%s was removed" % name)
