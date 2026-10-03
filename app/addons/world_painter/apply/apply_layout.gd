class_name ApplyLayout
extends RefCounted
## Where accepted worlds live (ADR 0017 A4/A5). Scenes store res:// paths; the AssetStudio coordinator takes
## project-relative paths; file access takes absolute ones. All three derive from the same few functions.

const SETTING_ROOT := "world_painter/apply/accepted_world_root"
const SETTING_COLLISION := "world_painter/apply/scatter_collision_bindings"
const SETTING_MAPPING := "world_painter/apply/terrain_mapping"
const SETTING_TERRAIN_COLLISION := "world_painter/apply/terrain_collision"
const DEFAULT_ROOT := "res://worlds"
const STAGING_REL := ".world_painter/staging"
const RECEIPTS_REL := ".world_painter/receipts"
const REVISIONS := "revisions"
const SOURCE_DIR := "source"
const GENERATED_DIR := "generated"
const WORLD_SCENE := "world.tscn"
const RECEIPT_FILE := "apply_receipt.json"
const BINDING_FILE := "binding.tres"
const LOCK_FILE := "assetstudio.lock.json"


## Absolute project directory without a trailing slash.
static func project_root() -> String:
	return ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")


static func accepted_root() -> String:
	return str(ProjectSettings.get_setting(SETTING_ROOT, DEFAULT_ROOT)).trim_suffix("/")


## "" when `root` can hold accepted worlds: a res:// directory below the project that is not hidden and not the
## AssetStudio managed tree.
static func root_error(root: String) -> String:
	if not root.begins_with("res://") or root.length() <= 6 or root.contains("\\") or root.substr(6).contains(":"):
		return "accepted_world_root '%s' is not a res:// directory" % root
	for seg in root.substr(6).split("/"):
		if seg.is_empty() or seg == "." or seg == ".." or seg.begins_with("."):
			return "accepted_world_root '%s' has an unsafe segment" % root
	if root.begins_with("res://addons") or root.begins_with("res://assets/library"):
		return "accepted_world_root '%s' lies inside a managed directory" % root
	return ""


static func is_world_id(s: String) -> bool:
	return ObjectRecord.is_uuid(s)


static func is_generation_dir_name(s: String) -> bool:
	if s.length() != 32:
		return false
	for i in 32:
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


static func world_res(world_id: String, root: String = "") -> String:
	return (root if root != "" else accepted_root()).path_join(world_id)


static func generation_res(world_id: String, dir_name: String, root: String = "") -> String:
	return world_res(world_id, root).path_join(REVISIONS).path_join(dir_name)


static func binding_res(world_id: String, root: String = "") -> String:
	return world_res(world_id, root).path_join(BINDING_FILE)


static func staging_rel(staging_id: String) -> String:
	return STAGING_REL.path_join(staging_id)


static func staging_res(staging_id: String) -> String:
	return "res://" + staging_rel(staging_id)


static func rel_of(res_path: String) -> String:
	return res_path.trim_prefix("res://")


static func abs_of(res_or_rel: String) -> String:
	return project_root().path_join(rel_of(res_or_rel))


static func receipt_abs(dir_name: String) -> String:
	return project_root().path_join(RECEIPTS_REL).path_join(dir_name + ".json")


## Owner id of a generation's root in the AssetStudio lock (`slug`: no "/", at most 64 characters): the world id
## (36) plus the first 27 hex digits of the generation directory name.
static func lock_owner_id(world_id: String, dir_name: String) -> String:
	return "%s.%s" % [world_id, dir_name.left(27)]
