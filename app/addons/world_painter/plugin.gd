@tool
extends EditorPlugin
## Editor entry only. Runtime code under core/, terrain/ and presentation/ never depends on this script.
## Registers the "World Painter" dock and owns the preview launcher and its loopback broker (ADR 0016 P1). It also
## registers the world_painter/apply/* and world_painter/terrain/material project settings and completes or rolls back an interrupted Apply before the
## editor uses the project and before every run (ADR 0017 A5).

var _launcher: PreviewLauncher
var _dock: PreviewDock


func _enter_tree() -> void:
	_register_apply_settings()
	var recovered := ApplyTransaction.recover()
	if not recovered.ok:
		push_warning("World Painter: transaction recovery did not run: %s" % recovered.error)
	_launcher = PreviewLauncher.new()
	add_child(_launcher)
	_dock = PreviewDock.new()
	_dock.setup(_launcher)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)


## Before the project runs: an interrupted Apply ends in the old or the new complete state. False stops the run.
func _build() -> bool:
	var open_review := PackedStringArray()
	if _dock != null and _dock.controller != null and _dock.controller.review != null:
		open_review.append(_dock.controller.review.staging_id)
	var recovered := ApplyTransaction.recover("", open_review)
	if not recovered.ok:
		push_error("World Painter: cannot run, transaction recovery failed: %s" % recovered.error)
	return recovered.ok


static func _register_apply_settings() -> void:
	var settings := [
		[ApplyLayout.SETTING_ROOT, ApplyLayout.DEFAULT_ROOT, TYPE_STRING, PROPERTY_HINT_DIR, ""],
		[ApplyLayout.SETTING_COLLISION, PackedStringArray(), TYPE_PACKED_STRING_ARRAY, PROPERTY_HINT_NONE, ""],
		[ApplyLayout.SETTING_MAPPING, "", TYPE_STRING, PROPERTY_HINT_FILE, "*.tres,*.res,*.gdshader"],
		[ApplyLayout.SETTING_TERRAIN_COLLISION, "dynamic", TYPE_STRING, PROPERTY_HINT_ENUM, "dynamic,full,disabled"],
		[WPMaterialMapper.SETTING, "", TYPE_STRING, PROPERTY_HINT_FILE, "*.gd"],
		[TerrainMaterials.SETTING, "", TYPE_STRING, PROPERTY_HINT_FILE, "*.tres,*.res"]]
	for s: Array in settings:
		if not ProjectSettings.has_setting(s[0]):
			ProjectSettings.set_setting(s[0], s[1])
		ProjectSettings.set_initial_value(s[0], s[1])
		ProjectSettings.add_property_info({"name": s[0], "type": s[2], "hint": s[3], "hint_string": s[4]})


func _exit_tree() -> void:
	if _launcher != null:
		_launcher.stop()
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.free()
		_dock = null
	if _launcher != null:
		_launcher.free()
		_launcher = null
