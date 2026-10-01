class_name RenderConfig
extends RefCounted
## Versioned rendering configuration (docs/rendering-performance-spec.md §4.2, §4.3, §22.1). Loading never
## fails: any problem yields safe_default() with `error` set, so resource limits are never disabled.
## Expected failures are returned as strings; nothing here calls push_error.

const PATH := "res://config/rendering_profiles.json"
const SCHEMA_VERSION := 1
const STARTUP_PROFILE := "performance"
const PROFILE_NAMES: Array[String] = ["performance", "balanced", "detailed"]
const PROFILE_KEYS: Array[String] = ["label", "target_fps", "scale_3d", "scaling_mode", "msaa", "texture_tier",
		"low_texture_max_edge_px", "near_min_role", "selected_role", "tree_detail_radius_m", "ground_cover_radius_m",
		"decorative_density_outside", "decorative_density_active", "active_area_radius_m", "mesh_lod_threshold_px",
		"shadows", "complex_effects"]
const SECTION_KEYS := {
	"cells": ["objects_m", "ground_cover_m", "overview_levels_m"],
	"budgets": ["managed_soft_mib", "managed_ceiling_mib", "preview_mib", "main_thread_soft_ms",
			"main_thread_max_scheduled_ms", "upload_soft_mib_per_frame", "inflight_loads"],
	"texture_preview": ["radius_m", "max_texture_edge_px", "fallback_texture_edge_px", "max_terrain_materials"],
	"stability": ["lod_hysteresis_fraction", "settle_ms"],
	"ui": ["diagnostics_refresh_hz", "inspector_candidates", "max_debug_labels"],
	"vegetation": ["categories", "excluded_asset_ids"],
}

## "" when the file loaded and validated, otherwise why the safe default is in use.
var error := ""
var _data: Dictionary = {}


## Never fails; see the class comment.
static func load_from(path := PATH) -> RenderConfig:
	if not FileAccess.file_exists(path):
		return _fallback("Cannot read %s." % path)
	var json := JSON.new()  # parse() reports failure by code; parse_string() would log an engine error
	if json.parse(FileAccess.get_file_as_string(path)) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return _fallback("%s is not a JSON object." % path.get_file())
	var parsed: Dictionary = json.data
	var problem := validate(parsed)
	if problem != "":
		return _fallback("%s: %s" % [path.get_file(), problem])
	var config := RenderConfig.new()
	config._data = parsed
	return config


static func safe_default() -> RenderConfig:
	var config := RenderConfig.new()
	# Same number typing as a parsed file (JSON numbers are floats).
	config._data = JSON.parse_string(JSON.stringify(_default_data()))
	return config


static func _fallback(message: String) -> RenderConfig:
	var config := safe_default()
	config.error = "Rendering config invalid, using safe Performance defaults: " + message
	return config


func profile(name: String) -> Dictionary:
	return (_data.profiles.get(name, {}) as Dictionary).duplicate(true)


func profile_names() -> Array[String]:
	return PROFILE_NAMES.duplicate()


func startup_profile() -> String:
	return str(_data.startup_profile)


func section(name: String) -> Dictionary:
	return (_data.get(name, {}) as Dictionary).duplicate(true)


func vegetation_rule() -> Dictionary:
	return section("vegetation")


func is_vegetation(asset: AssetDefinition) -> bool:
	return rule_is_vegetation(_data.vegetation, asset)


## rule: {"categories": [...], "excluded_asset_ids": [...]}.
static func rule_is_vegetation(rule: Dictionary, asset: AssetDefinition) -> bool:
	if asset == null:
		return false
	return (rule.get("categories", []) as Array).has(asset.category) \
			and not (rule.get("excluded_asset_ids", []) as Array).has(asset.asset_id)


# --- validation ----------------------------------------------------------------------------

## "" when `data` is a valid configuration.
static func validate(data: Dictionary) -> String:
	var keys: Array = ["schema_version", "startup_profile", "profiles"] + SECTION_KEYS.keys()
	var problem := _exact_keys(data, keys, "config")
	if problem != "":
		return problem
	if not _is_int(data.schema_version) or int(data.schema_version) != SCHEMA_VERSION:
		return "schema_version must be %d." % SCHEMA_VERSION
	if data.startup_profile != STARTUP_PROFILE:
		return "startup_profile must be \"%s\"." % STARTUP_PROFILE
	problem = _validate_profiles(data.profiles)
	if problem != "":
		return problem
	for name: String in SECTION_KEYS:
		if typeof(data[name]) != TYPE_DICTIONARY:
			return "%s must be an object." % name
		problem = _exact_keys(data[name], SECTION_KEYS[name], name)
		if problem != "":
			return problem
	return _validate_sections(data)


static func _validate_profiles(profiles: Variant) -> String:
	if typeof(profiles) != TYPE_DICTIONARY:
		return "profiles must be an object."
	var problem := _exact_keys(profiles, PROFILE_NAMES, "profiles")
	if problem != "":
		return problem
	for name in PROFILE_NAMES:
		if typeof(profiles[name]) != TYPE_DICTIONARY:
			return "profiles.%s must be an object." % name
		problem = _exact_keys(profiles[name], PROFILE_KEYS, "profiles." + name)
		if problem == "":
			problem = _validate_profile(profiles[name], "profiles." + name)
		if problem != "":
			return problem
	return ""


static func _validate_profile(p: Dictionary, at: String) -> String:
	var checks: Array[String] = [
		"" if typeof(p.label) == TYPE_STRING and str(p.label) != "" else "label must be a non-empty string",
		"" if _is_int(p.target_fps) and [30, 60].has(int(p.target_fps)) else "target_fps must be 30 or 60",
		_in_range(p.scale_3d, 0.5, 1.0, "scale_3d"),
		"" if p.scaling_mode == "bilinear" else "scaling_mode must be \"bilinear\"",
		"" if p.msaa == "off" else "msaa must be \"off\"",
		"" if p.texture_tier == "low" else "texture_tier must be \"low\"",
		_power_of_two(p.low_texture_max_edge_px, 128, 2048, "low_texture_max_edge_px"),
		"" if ["near", "mid"].has(p.near_min_role) else "near_min_role must be \"near\" or \"mid\"",
		"" if p.selected_role == "selected" else "selected_role must be \"selected\"",
		_in_range(p.tree_detail_radius_m, 0.0, 1000.0, "tree_detail_radius_m", true),
		_in_range(p.ground_cover_radius_m, 0.0, 1000.0, "ground_cover_radius_m", true),
		_in_range(p.decorative_density_outside, 0.0, 1.0, "decorative_density_outside"),
		_in_range(p.decorative_density_active, 0.0, 1.0, "decorative_density_active"),
		_in_range(p.active_area_radius_m, 5.0, 100.0, "active_area_radius_m"),
		_in_range(p.mesh_lod_threshold_px, 0.5, 16.0, "mesh_lod_threshold_px"),
		"" if typeof(p.shadows) == TYPE_BOOL and not p.shadows else "shadows is prohibited (must be false)",
		"" if typeof(p.complex_effects) == TYPE_BOOL and not p.complex_effects \
				else "complex_effects is prohibited (must be false)",
	]
	for message in checks:
		if message != "":
			return "%s: %s." % [at, message]
	if float(p.decorative_density_outside) > float(p.decorative_density_active):
		return "%s: decorative_density_outside must not exceed decorative_density_active." % at
	return ""


static func _validate_sections(d: Dictionary) -> String:
	var cells: Dictionary = d.cells
	var budgets: Dictionary = d.budgets
	var preview: Dictionary = d.texture_preview
	var stability: Dictionary = d.stability
	var ui: Dictionary = d.ui
	var veg: Dictionary = d.vegetation
	var checks: Array[String] = [
		_in_range(cells.objects_m, 8.0, 128.0, "cells.objects_m"),
		_in_range(cells.ground_cover_m, 4.0, 64.0, "cells.ground_cover_m"),
		_overview_levels(cells),
		_in_range(budgets.managed_soft_mib, 0.0, 1e6, "budgets.managed_soft_mib", true),
		_in_range(budgets.managed_ceiling_mib, 0.0, 1e6, "budgets.managed_ceiling_mib", true),
		_in_range(budgets.preview_mib, 0.0, 1e6, "budgets.preview_mib", true),
		_in_range(budgets.main_thread_soft_ms, 0.0, 4.0, "budgets.main_thread_soft_ms", true),
		_in_range(budgets.main_thread_max_scheduled_ms, 0.0, 4.0, "budgets.main_thread_max_scheduled_ms", true),
		_in_range(budgets.upload_soft_mib_per_frame, 0.0, 16.0, "budgets.upload_soft_mib_per_frame", true),
		_int_range(budgets.inflight_loads, 1, 8, "budgets.inflight_loads"),
		_in_range(preview.radius_m, 5.0, 100.0, "texture_preview.radius_m"),
		"" if _is_int(preview.max_texture_edge_px) and [1024, 2048].has(int(preview.max_texture_edge_px)) \
				else "texture_preview.max_texture_edge_px must be 1024 or 2048",
		_int_range(preview.max_terrain_materials, 1, 4, "texture_preview.max_terrain_materials"),
		_in_range(stability.lod_hysteresis_fraction, 0.0, 0.5, "stability.lod_hysteresis_fraction"),
		_int_range(stability.settle_ms, 0, 2000, "stability.settle_ms"),
		_in_range(ui.diagnostics_refresh_hz, 1.0, 10.0, "ui.diagnostics_refresh_hz"),
		_int_range(ui.inspector_candidates, 8, 256, "ui.inspector_candidates"),
		_int_range(ui.max_debug_labels, 8, 256, "ui.max_debug_labels"),
		_string_array(veg.categories, "vegetation.categories", false),
		_string_array(veg.excluded_asset_ids, "vegetation.excluded_asset_ids", true),
	]
	for message in checks:
		if message != "":
			return message + "."
	return _validate_dependencies(budgets, preview)


static func _validate_dependencies(budgets: Dictionary, preview: Dictionary) -> String:
	if float(budgets.managed_soft_mib) >= float(budgets.managed_ceiling_mib):
		return "budgets.managed_soft_mib must be below managed_ceiling_mib."
	if float(budgets.preview_mib) > float(budgets.managed_ceiling_mib):
		return "budgets.preview_mib must not exceed managed_ceiling_mib."
	if float(budgets.main_thread_soft_ms) > float(budgets.main_thread_max_scheduled_ms):
		return "budgets.main_thread_soft_ms must not exceed main_thread_max_scheduled_ms."
	var fallback: Variant = preview.fallback_texture_edge_px
	if not _is_int(fallback) or int(fallback) != 1024 or int(fallback) > int(preview.max_texture_edge_px):
		return "texture_preview.fallback_texture_edge_px must be 1024 and at most max_texture_edge_px."
	return ""


static func _overview_levels(cells: Dictionary) -> String:
	var levels: Variant = cells.overview_levels_m
	if typeof(levels) != TYPE_ARRAY or (levels as Array).is_empty():
		return "cells.overview_levels_m must be a non-empty array"
	var previous := 0.0
	for level: Variant in levels:
		if typeof(level) not in [TYPE_FLOAT, TYPE_INT] or float(level) <= previous:
			return "cells.overview_levels_m must be strictly ascending numbers"
		var ratio := float(level) / float(cells.objects_m)
		if not is_equal_approx(ratio, roundf(ratio)):
			return "cells.overview_levels_m must be multiples of objects_m"
		previous = float(level)
	return ""


static func _exact_keys(d: Variant, keys: Array, at: String) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return "%s must be an object." % at
	for key: Variant in keys:
		if not (d as Dictionary).has(key):
			return "%s is missing key \"%s\"." % [at, key]
	for key: Variant in d:
		if not keys.has(key):
			return "%s has unknown key \"%s\"." % [at, key]
	return ""


static func _is_int(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or (typeof(v) == TYPE_FLOAT and is_finite(v) and v == floorf(v))


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or (typeof(v) == TYPE_FLOAT and is_finite(v))


## `open_low`: the lower bound itself is excluded.
static func _in_range(v: Variant, lo: float, hi: float, name: String, open_low := false) -> String:
	if not _is_number(v):
		return "%s must be a number" % name
	var x := float(v)
	if x > hi or x < lo or (open_low and x <= lo):
		return "%s must be in %s%s, %s]" % [name, "(" if open_low else "[", lo, hi]
	return ""


static func _int_range(v: Variant, lo: int, hi: int, name: String) -> String:
	if not _is_int(v) or int(v) < lo or int(v) > hi:
		return "%s must be an integer in [%d, %d]" % [name, lo, hi]
	return ""


static func _power_of_two(v: Variant, lo: int, hi: int, name: String) -> String:
	var problem := _int_range(v, lo, hi, name)
	if problem == "" and (int(v) & (int(v) - 1)) != 0:
		return "%s must be a power of two" % name
	return problem


static func _string_array(v: Variant, name: String, may_be_empty: bool) -> String:
	if typeof(v) != TYPE_ARRAY or (not may_be_empty and (v as Array).is_empty()):
		return "%s must be %s array of strings" % [name, "an" if may_be_empty else "a non-empty"]
	for item: Variant in v:
		if typeof(item) != TYPE_STRING:
			return "%s must contain only strings" % name
	return ""


static func _default_data() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION, "startup_profile": STARTUP_PROFILE,
		"profiles": {
			"performance": _default_profile("Performance", 60, 0.65, 512, "mid", 80, 25, 0.25, 0.75, 20, 4),
			"balanced": _default_profile("Balanced", 60, 0.75, 512, "near", 120, 40, 0.5, 1.0, 25, 2),
			"detailed": _default_profile("Detailed", 30, 1.0, 1024, "near", 160, 60, 0.75, 1.0, 30, 1),
		},
		"cells": {"objects_m": 32, "ground_cover_m": 16, "overview_levels_m": [128, 256]},
		"budgets": {"managed_soft_mib": 384, "managed_ceiling_mib": 512, "preview_mib": 128,
				"main_thread_soft_ms": 1.0, "main_thread_max_scheduled_ms": 2.0, "upload_soft_mib_per_frame": 2,
				"inflight_loads": 2},
		"texture_preview": {"radius_m": 20, "max_texture_edge_px": 2048, "fallback_texture_edge_px": 1024,
				"max_terrain_materials": 4},
		"stability": {"lod_hysteresis_fraction": 0.2, "settle_ms": 250},
		"ui": {"diagnostics_refresh_hz": 4, "inspector_candidates": 64, "max_debug_labels": 64},
		"vegetation": {"categories": ["trees", "shrubs", "ground_cover"], "excluded_asset_ids": ["nature.rock.pebbles_a"]},
	}


static func _default_profile(label: String, fps: int, scale: float, low_edge: int, near_role: String, tree_m: int,
		cover_m: int, outside: float, active: float, active_m: int, lod_px: int) -> Dictionary:
	return {"label": label, "target_fps": fps, "scale_3d": scale, "scaling_mode": "bilinear", "msaa": "off",
			"texture_tier": "low", "low_texture_max_edge_px": low_edge, "near_min_role": near_role,
			"selected_role": "selected", "tree_detail_radius_m": tree_m, "ground_cover_radius_m": cover_m,
			"decorative_density_outside": outside, "decorative_density_active": active,
			"active_area_radius_m": active_m, "mesh_lod_threshold_px": lod_px, "shadows": false,
			"complex_effects": false}
