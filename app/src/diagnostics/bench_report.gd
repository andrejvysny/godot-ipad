class_name BenchReport
extends RefCounted
## Evidence identity and report writing for RenderBench (spec §19.2, §19.3 item 10). Platform class,
## target-device match, build type and acceptance are separate fields; acceptance is never claimed here.

const TARGET_MODELS: Array[String] = ["iPad13,1", "iPad13,2"]
const CONFIG_PATH := "res://config/poc_defaults.json"
const PROFILES_PATH := "res://config/rendering_profiles.json"
const FINGERPRINT_PATH := "res://config/build_fingerprint.json"


static func platform_class() -> String:
	if OS.has_feature("ios"):
		return "SIMULATOR" if OS.has_feature("simulator") else "DEVICE"
	return "HEADLESS" if DisplayServer.get_name() == "headless" else "HOST"


static func evidence() -> Dictionary:
	var model := OS.get_model_name()
	return {"platform_class": platform_class(), "device_model": model,
		"is_target_device": model in TARGET_MODELS,
		"build": "debug" if OS.is_debug_build() else "release", "acceptance": "NOT_ACCEPTANCE_RUN"}


static func _file_sha256(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return CanonicalEncoder.sha256_hex(FileAccess.get_file_as_bytes(path))


static func fingerprints(catalog: AssetCatalog) -> Dictionary:
	var source := "unknown"
	if FileAccess.file_exists(FINGERPRINT_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FINGERPRINT_PATH))
		if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("source_sha256"):
			source = str(parsed.source_sha256)
	return {"source_sha256": source, "godot": WorldCodec.default_created_with().godot,
		"config_sha256": _file_sha256(CONFIG_PATH), "rendering_profiles_sha256": _file_sha256(PROFILES_PATH),
		"catalog_sha256": catalog.sha256}


## State that a rendering-only benchmark must leave untouched.
static func authored_state(session: EditorSession) -> Dictionary:
	return {"hash": session.authored_hash(), "revision": session.document.document_revision,
		"history": session.history.size()}


static func correctness(before: Dictionary, after: Dictionary, restored: bool) -> Dictionary:
	return {"authored_hash_before": before.hash, "authored_hash_after": after.hash,
		"revision_before": before.revision, "revision_after": after.revision,
		"history_size_before": before.history, "history_size_after": after.history, "restored": restored}


## True when a regular file sits where a parent directory of `dir` must be (avoids an engine error log).
static func _blocked_by_file(dir: String) -> bool:
	var p := dir
	while p.contains("/") and p != "user://" and p != "res://":
		if DirAccess.dir_exists_absolute(p):
			return false
		if FileAccess.file_exists(p):
			return true
		p = p.get_base_dir()
	return false


## Returns [path, error]; error is "" on success.
static func write(report: Dictionary, output_dir: String) -> Array:
	if _blocked_by_file(output_dir) or (DirAccess.make_dir_recursive_absolute(output_dir) != OK
			and not DirAccess.dir_exists_absolute(output_dir)):
		return ["", "Render bench report could not be written: cannot create " + output_dir]
	var path := output_dir.path_join("render-bench-%d.json" % int(Time.get_unix_time_from_system()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ["", "Render bench report could not be written."]
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return [path, ""]
