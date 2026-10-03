class_name SnapshotIdentity
extends RefCounted
## Identities of an Apply (ADR 0017 A2, INT-SPEC-1.1 §11): the source snapshot hash of a frozen generation, the
## consumer-profile hash and the generation id. Encodings are frozen by
## contracts/world-painter/world-v4/fixtures/generation-vectors.json (Python reference: scripts/world_v4_generation_vectors.py).

const CJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const Installer := preload("res://addons/assetstudio/project/as_installer.gd")
const SNAPSHOT_MAGIC := "WPSNAPSHOT1\n"
const BAKE_MAGIC := "WPBAKE1\n"
const PIN_KEYS := ["installer_version", "godot_build", "terrain3d_build", "assetstudio_pin", "world_painter_pin"]
const ADDON_DIR := "res://addons/world_painter"
const INTEGRATION_LOCK := "res://integration.lock.json"
const MAPPING_FILES := ["res://addons/world_painter/terrain/world_terrain.gdshader",
	"res://addons/world_painter/terrain/world_terrain_material.gdshaderinc",
	"res://addons/world_painter/terrain/world_terrain_region.gdshaderinc",
	"res://addons/world_painter/terrain/terrain_materials.gd"]

static var _tree_hash := ""


## `digests`: relative path -> raw 32-byte SHA-256. Paths are hashed in code point order.
const EMPTY_SHA256 := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

static func snapshot_hash_of_digests(digests: Dictionary) -> String:
	var paths := PackedStringArray(digests.keys())
	paths.sort()
	var e := CanonicalEncoder.new()
	e.put_raw(SNAPSHOT_MAGIC.to_ascii_buffer())
	for path in paths:
		e.put_str(path)
		e.put_raw(digests[path])
	return CanonicalEncoder.sha256_hex(e.bytes())


## [{path: raw sha256}, ""] of manifest.json and every payload the manifest declares (nothing else).
static func digests_of_dir(dir: String) -> Array:
	var manifest_path := dir.path_join(WorldCodec.MANIFEST_FILE)
	if not FileAccess.file_exists(manifest_path):
		return [{}, "'%s' has no manifest.json" % dir]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if typeof(parsed) != TYPE_DICTIONARY or typeof((parsed as Dictionary).get("payload_files")) != TYPE_ARRAY:
		return [{}, "manifest.json of '%s' is not a world manifest" % dir]
	var out := {WorldCodec.MANIFEST_FILE: _sha_raw(manifest_path)}
	for entry: Variant in (parsed as Dictionary).payload_files:
		var rel: String = str(entry.get("path", "")) if typeof(entry) == TYPE_DICTIONARY else ""
		if not _is_safe_rel(rel) or not FileAccess.file_exists(dir.path_join(rel)):
			return [{}, "payload '%s' of '%s' is missing or unsafe" % [rel.left(80), dir]]
		out[rel] = _sha_raw(dir.path_join(rel))
	return [out, ""]


## [hex, ""] or ["", error].
static func source_snapshot_hash(dir: String) -> Array:
	var digests := digests_of_dir(dir)
	if digests[1] != "":
		return ["", digests[1]]
	return [snapshot_hash_of_digests(digests[0]), ""]


static func profile_canonical(profile: Dictionary) -> PackedByteArray:
	var enc: RefCounted = CJson.encode(profile)
	return enc.value if enc.ok else PackedByteArray()


static func profile_hash(profile: Dictionary) -> String:
	return CanonicalEncoder.sha256_hex(profile_canonical(profile))


## Full 64-hex digest; the directory name is its first 32 digits (dir_name).
static func generation_id(snapshot_hex: String, profile_hex: String, pins: Dictionary) -> String:
	var e := CanonicalEncoder.new()
	e.put_raw(BAKE_MAGIC.to_ascii_buffer())
	e.put_raw(snapshot_hex.hex_decode())
	e.put_raw(profile_hex.hex_decode())
	for key: String in PIN_KEYS:
		e.put_str(str(pins.get(key, "")))
	return CanonicalEncoder.sha256_hex(e.bytes())


static func dir_name(generation_hex: String) -> String:
	return generation_hex.left(32)


## The toolchain pins of this machine's project (order = PIN_KEYS).
static func current_pins() -> Dictionary:
	return {"installer_version": Installer.INSTALLER_VERSION,
		"godot_build": str(Engine.get_version_info().hash),
		"terrain3d_build": WorldCodec.TERRAIN3D_VERSION,
		"assetstudio_pin": assetstudio_pin(),
		"world_painter_pin": world_painter_pin()}


static func assetstudio_pin() -> String:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(INTEGRATION_LOCK))
	if typeof(parsed) == TYPE_DICTIONARY:
		var addons: Variant = (parsed as Dictionary).get("addons")
		var entry: Variant = (addons as Dictionary).get("assetstudio") if typeof(addons) == TYPE_DICTIONARY else null
		if typeof(entry) == TYPE_DICTIONARY and typeof((entry as Dictionary).get("archive_sha256")) == TYPE_STRING:
			return (entry as Dictionary).archive_sha256
	return "unpinned"


## plugin.cfg version plus a hash of every addon file (.uid and .import files are machine state and excluded).
static func world_painter_pin() -> String:
	if _tree_hash == "":
		var cfg := ConfigFile.new()
		cfg.load(ADDON_DIR.path_join("plugin.cfg"))
		var digests := {}
		_collect(ADDON_DIR, "", digests)
		_tree_hash = "%s:%s" % [str(cfg.get_value("plugin", "version", "0")), snapshot_hash_of_digests(digests)]
	return _tree_hash


static func consumer_profile() -> Dictionary:
	var collision := PackedStringArray(ProjectSettings.get_setting(ApplyLayout.SETTING_COLLISION, PackedStringArray()))
	collision.sort()
	var profile := {"accepted_world_root": ApplyLayout.accepted_root(),
		"scatter_collision_bindings": Array(collision),
		"terrain_collision": str(ProjectSettings.get_setting(ApplyLayout.SETTING_TERRAIN_COLLISION, "dynamic")),
		"terrain_mapping_sha256": mapping_hash()}
	# Present only when the consumer opts in, so a default profile keeps its hash.
	var mapper := WPMaterialMapper.configured_path()
	if mapper != "":
		profile["material_mapper"] = {"path": mapper, "sha256": closure_hash([mapper])}
	var terrain_material := TerrainMaterials.custom_path()
	if terrain_material != "":
		profile["terrain_material"] = {"path": terrain_material, "sha256": closure_hash([terrain_material], true)}
	return profile


## Hash of the terrain material mapping inputs: the consumer's mapping resource when the project names one, else
## the World Painter terrain shader and material preparation sources.
static func mapping_hash() -> String:
	var files: Array = []
	var custom := str(ProjectSettings.get_setting(ApplyLayout.SETTING_MAPPING, ""))
	files = [custom] if custom != "" else MAPPING_FILES
	var digests := {}
	for path: String in files:
		# SHA-256 of empty input, as a constant: HashingContext logs an error when updated with no bytes.
		digests[path] = _sha_raw(path) if FileAccess.file_exists(path) else EMPTY_SHA256.hex_decode()
	return snapshot_hash_of_digests(digests)


## SHA-256 hex over the given files and, with `follow`, everything they depend on (resource dependencies and shader
## #include files, transitively). Missing files hash as 32 zero bytes.
static func closure_hash(paths: Array, follow: bool = false) -> String:
	var seen := {}
	var absent := PackedByteArray()
	absent.resize(32)
	var queue: Array = paths.duplicate()
	while not queue.is_empty():
		var path: String = queue.pop_back()
		if seen.has(path):
			continue
		seen[path] = _sha_raw(path) if FileAccess.file_exists(path) else absent
		if follow and FileAccess.file_exists(path):
			queue.append_array(_dependencies_of(path))
	return snapshot_hash_of_digests(seen)


static func _dependencies_of(path: String) -> Array:
	var out := []
	if path.get_extension() in ["gdshader", "gdshaderinc"]:
		var rx := RegEx.create_from_string("#include\\s+\"(res://[^\"]+)\"")
		for m in rx.search_all(FileAccess.get_file_as_string(path)):
			out.append(m.get_string(1))
	else:
		for dep in ResourceLoader.get_dependencies(path):
			var target := str(dep).get_slice("::", 2) if str(dep).contains("::") else str(dep)
			if target.begins_with("res://"):
				out.append(target)
	return out


static func _collect(base: String, rel: String, digests: Dictionary) -> void:
	var here := base.path_join(rel) if rel != "" else base
	for f in DirAccess.get_files_at(here):
		if f.ends_with(".uid") or f.ends_with(".import"):
			continue
		var r := rel.path_join(f) if rel != "" else f
		digests[r] = _sha_raw(base.path_join(r))
	for d in DirAccess.get_directories_at(here):
		_collect(base, rel.path_join(d) if rel != "" else d, digests)


static func _sha_raw(path: String) -> PackedByteArray:
	return FileAccess.get_sha256(path).hex_decode()


static func _is_safe_rel(rel: String) -> bool:
	if rel.is_empty() or rel.begins_with("/") or rel.contains("\\") or rel.contains(":"):
		return false
	for seg in rel.split("/"):
		if seg.is_empty() or seg == "." or seg == "..":
			return false
	return true
