class_name ApplyDeliveries
extends RefCounted
## Desktop deliveries of the world's AssetStudio bindings (ADR 0017 A3/A4): checks the project lock and the installed
## directories under the managed root (exact receipt hashes, imports present) and resolves a binding to the scene the
## baked world instances (portable GLB import, or the relocated entry scene of a source delivery). Bundled bindings
## instance their trusted catalog scene. Nothing here touches the network.

const ProjectLock := preload("res://addons/assetstudio/project/as_project_lock.gd")
const ProjectConfig := preload("res://addons/assetstudio/project/as_project_config.gd")
const Installer := preload("res://addons/assetstudio/project/as_installer.gd")
const SourceInstall := preload("res://addons/assetstudio/project/as_srcpkg_install.gd")
const CJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const PORTABLE := "portable_glb_v1"
const SOURCE := "godot_static_source_v1"
const OK := "ok"

var project_root := ""
var lock: RefCounted
var lock_error := ""
## Trusted catalog of bundled bindings.
var catalog: AssetCatalog
var managed_rel := "assets/library"
## Test seam: binding id -> PackedScene returned by scene_for() instead of loading the installed delivery (the
## installation checks of state_of() stay real).
var overrides := {}

var _scenes := {}  # binding_id -> PackedScene


static func for_project(root: String = "") -> ApplyDeliveries:
	var d := ApplyDeliveries.new()
	d.project_root = root if root != "" else ApplyLayout.project_root()
	d.reload()
	return d


## Re-reads the project config and lock from disk (they change under a long-lived context: Apply, AssetStudio).
## Test overrides and the catalog are kept.
func reload() -> void:
	lock = null
	lock_error = ""
	_scenes.clear()
	var cfg: RefCounted = ProjectConfig.load_from(project_root)
	if cfg.ok:
		managed_rel = str(cfg.value.call("managed_rel"))
	var raw := FileAccess.get_file_as_bytes(project_root.path_join(ApplyLayout.LOCK_FILE))
	if raw.is_empty():
		lock_error = "%s is missing" % ApplyLayout.LOCK_FILE
		return
	var parsed: RefCounted = ProjectLock.parse_bytes(raw)
	if parsed.ok:
		lock = parsed.value
	else:
		lock_error = str(parsed.message)


## {state, detail, key, representation, dir_rel, entry_res}: `state` is "ok", "bundled", "not_locked",
## "lock_mismatch", "not_installed", "modified" or "not_imported".
func state_of(binding: AssetBinding) -> Dictionary:
	var out := {"state": OK, "detail": "", "key": "", "representation": "", "dir_rel": "", "entry_res": ""}
	if binding.is_bundled():
		out.state = "bundled"
		return out
	out.key = binding.asset_key
	if lock == null:
		return _fail(out, "not_locked", lock_error)
	var mismatch := _closure_error(binding)
	if mismatch != "":
		return _fail(out, "not_locked" if mismatch.begins_with("not in") else "lock_mismatch", mismatch)
	var rep := _choose_representation(binding)
	var pin: Dictionary = binding.deliveries[PORTABLE] if rep == PORTABLE else binding.deliveries[SOURCE]
	out.representation = rep
	out.dir_rel = Installer.target_rel(managed_rel, binding.asset_key, str(pin.manifest_sha256))
	var dir := project_root.path_join(out.dir_rel)
	if not DirAccess.dir_exists_absolute(dir):
		return _fail(out, "not_installed", "%s is not installed (%s)" % [binding.asset_key.left(12), out.dir_rel])
	var expect := {"asset_key": binding.asset_key, "manifest_sha256": pin.manifest_sha256,
		"delivery_id": pin.delivery_id, "representation": rep}
	var problems := Installer.check_install(dir, expect)
	if not problems.is_empty():
		return _fail(out, "modified", "%s: %s" % [out.dir_rel, problems[0]])
	var entry := _entry_rel(dir, rep)
	if entry == "":
		return _fail(out, "modified", "%s has no entry file in its receipt" % out.dir_rel)
	if rep == PORTABLE and not Installer.missing_import_files(dir).is_empty():
		return _fail(out, "not_imported", "%s is not imported yet (Godot has not reimported it)" % entry)
	out.entry_res = "res://" + out.dir_rel.path_join(entry)
	return out


## [PackedScene, ""] or [null, error]. Bundled bindings give their catalog scene.
func scene_for(binding: AssetBinding) -> Array:
	if _scenes.has(binding.binding_id):
		return [_scenes[binding.binding_id], ""]
	var scene: PackedScene = overrides.get(binding.binding_id)
	if scene == null:
		var found := _load_scene(binding)
		if found[1] != "":
			return found
		scene = found[0]
	_scenes[binding.binding_id] = scene
	return [scene, ""]


func _load_scene(binding: AssetBinding) -> Array:
	if binding.is_bundled():
		var def := catalog.get_asset(binding.asset_id) if catalog != null else null
		var bundled := load(def.preview_scene) as PackedScene if def != null else null
		return [bundled, ""] if bundled != null else [null, "the catalog scene of %s cannot be loaded" % binding.asset_id]
	var state := state_of(binding)
	if state.state != OK:
		return [null, "%s: %s" % [state.state, state.detail]]
	var loaded := ResourceLoader.load(str(state.entry_res), "PackedScene") as PackedScene
	return [loaded, ""] if loaded != null else [null, "cannot load %s" % state.entry_res]


func _closure_error(binding: AssetBinding) -> String:
	var deps: Dictionary = lock.call("dependencies")
	for key: String in binding.dependencies:
		if not deps.has(key):
			return "not in the project lock: %s" % key.left(12)
		var world_dep: Dictionary = binding.dependencies[key]
		for rep: String in world_dep.deliveries:
			var locked: Variant = (deps[key].deliveries as Dictionary).get(rep)
			if locked != null and locked != world_dep.deliveries[rep]:
				return "the project lock pins another %s delivery of %s" % [rep, key.left(12)]
	if not deps.has(binding.asset_key):
		return "not in the project lock: %s" % binding.asset_key.left(12)
	var own: Dictionary = (deps[binding.asset_key].deliveries as Dictionary)
	if not own.has(PORTABLE):
		return "not in the project lock as %s: %s" % [PORTABLE, binding.asset_key.left(12)]
	return ""


func _choose_representation(binding: AssetBinding) -> String:
	if binding.deliveries.has(SOURCE):
		var locked: Variant = (lock.call("dependencies")[binding.asset_key].deliveries as Dictionary).get(SOURCE)
		var pin: Dictionary = binding.deliveries[SOURCE]
		if locked == pin and DirAccess.dir_exists_absolute(project_root.path_join(
				Installer.target_rel(managed_rel, binding.asset_key, str(pin.manifest_sha256)))):
			return SOURCE
	return PORTABLE


static func _entry_rel(dir: String, rep: String) -> String:
	var parsed: RefCounted = CJson.parse_strict_utf8(FileAccess.get_file_as_bytes(dir.path_join(Installer.RECEIPT_NAME)))
	if not parsed.ok or typeof(parsed.value) != TYPE_DICTIONARY:
		return ""
	var receipt: Dictionary = parsed.value
	if rep == SOURCE:
		return SourceInstall.entry_rel(receipt)
	for f: Variant in receipt.get("files", []):
		if typeof(f) == TYPE_DICTIONARY and str(f.get("path", "")).get_extension().to_lower() == "glb":
			return str(f.path)
	return ""


static func _fail(out: Dictionary, state: String, detail: String) -> Dictionary:
	out.state = state
	out.detail = detail
	return out
