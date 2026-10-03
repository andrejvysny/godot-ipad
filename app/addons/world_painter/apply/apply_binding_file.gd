class_name ApplyBindingFile
extends RefCounted
## binding.tres of an accepted world: a text resource of WPAcceptedWorldBinding (INT-SPEC-1.1 §11). Written by hand so
## the tracked bytes are deterministic; read with a line parser so the CLI works while the generated scene is
## absent (git-ignored) and loading the resource would fail.

const SCRIPT_PATH := "res://addons/world_painter/runtime/accepted_world_binding.gd"
const KEYS := ["world_id", "source_snapshot_hash", "authored_hash", "generation_id"]


static func encode(world_id: String, source_snapshot_hash: String, authored_hash: String, generation_id: String,
		scene_res: String) -> PackedByteArray:
	var text := '[gd_resource type="Resource" script_class="WPAcceptedWorldBinding" format=3]\n\n'
	text += '[ext_resource type="Script" path="%s" id="1_binding"]\n' % SCRIPT_PATH
	text += '[ext_resource type="PackedScene" path="%s" id="2_scene"]\n\n' % scene_res
	text += '[resource]\nscript = ExtResource("1_binding")\n'
	text += 'world_id = "%s"\nsource_snapshot_hash = "%s"\nauthored_hash = "%s"\ngeneration_id = "%s"\n' % [
		world_id, source_snapshot_hash, authored_hash, generation_id]
	text += 'scene = ExtResource("2_scene")\n'
	return text.to_utf8_buffer()


## {world_id, source_snapshot_hash, authored_hash, generation_id, scene} or {} when `text` is not a binding.
static func parse(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n"):
		if line.begins_with("[ext_resource type=\"PackedScene\""):
			var start := line.find('path="') + 6
			out["scene"] = line.substr(start, line.find('"', start) - start)
		for key: String in KEYS:
			if line.begins_with(key + ' = "'):
				out[key] = line.trim_prefix(key + ' = "').trim_suffix('"')
	for key: String in KEYS + ["scene"]:
		if not out.has(key):
			return {}
	return out


static func read(path_abs: String) -> Dictionary:
	if not FileAccess.file_exists(path_abs):
		return {}
	return parse(FileAccess.get_file_as_string(path_abs))
