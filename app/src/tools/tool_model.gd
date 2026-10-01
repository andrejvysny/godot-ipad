class_name ToolModel
extends Node
## The Editor v2 tool model (docs/editor-v2.md §1, §2): modes, per-mode tools, invert, settings
## namespaces, armed Library asset, flatten height pick and the scatter source. Pure state plus
## signals; ToolController adds operations, selection and document edits on top.

signal tool_changed(tool_id: String)
signal settings_changed(ns: String)
signal dismissed()  # Esc: the UI closes its popover and menu

const TOOL_RAISE := "raise"
const TOOL_PAINT := "paint"
const TOOL_SELECT := "select"
const TOOL_PATH := "path"
const TOOL_FLATTEN := "flatten"
const MODES: Array[String] = ["sculpt", "paint", "place"]
const TOOLS_BY_MODE := {
	"sculpt": ["raise", "flatten", "noise"],
	"paint": ["paint", "spray", "tint", "pick"],
	"place": ["select", "scatter", "erase", "fill", "path"],
}
const TOOL_LABELS := {"raise": "Raise", "flatten": "Flatten", "noise": "Noise", "paint": "Paint",
		"spray": "Spray", "tint": "Tint", "pick": "Pick", "select": "Select", "scatter": "Scatter",
		"erase": "Erase", "fill": "Fill", "path": "Path"}
const INVERT_LABELS := {"raise": "Lower", "noise": "Smooth", "paint": "Erase", "spray": "Erase",
		"tint": "Remove", "scatter": "Erase", "fill": "Clear"}
const DEFAULT_TOOLS := {"sculpt": "raise", "paint": "paint", "place": "scatter"}
const STRENGTH_MIN := ToolSettings.STRENGTH_MIN
const STRENGTH_MAX := ToolSettings.STRENGTH_MAX
const BUSY := "Another operation is in progress."

var editing_enabled := true

var _ctx: ToolContext
var _values: ToolSettings
var _store: ScatterSetStore
var _mix := PackedStringArray()
var _mode := "paint"
var _tool_by_mode: Dictionary = DEFAULT_TOOLS.duplicate()
var _inverted := false
var _armed := ""
var _picking := false
var _pick_contact := false
var _snap := true
var _rule_edits: RuleEdits


## Overridden by ToolController: a world operation or object edit is open.
func has_active_operation() -> bool:
	return false


func _setup_model(ctx: ToolContext) -> void:
	_ctx = ctx
	_values = ToolSettings.new(ctx)
	if _store == null:
		_store = ScatterSetStore.new()
	_mix = PackedStringArray()
	_snap = true
	_mode = "paint"
	_tool_by_mode = DEFAULT_TOOLS.duplicate()
	_inverted = false
	_armed = ""
	_picking = false
	_rule_edits = RuleEdits.new(ctx, has_active_operation)


# --- Modes, tools, invert ----------------------------------------------------------------

func mode() -> String:
	return _mode


func tool_of(mode_id: String) -> String:
	return str(_tool_by_mode.get(mode_id, ""))


func active_tool() -> String:
	return str(_tool_by_mode[_mode])


func set_mode(mode_id: String) -> String:
	if mode_id not in MODES:
		return "Unknown mode '%s'." % mode_id
	return set_tool(tool_of(mode_id))


## Switches mode too. Clears invert, cancels height picking and hides the ghost on a change.
func set_tool(tool_id: String) -> String:
	var target := _mode_of(tool_id)
	if target == "":
		return "Unknown tool '%s'." % tool_id
	if has_active_operation():
		return BUSY
	if target == _mode and tool_id == active_tool():
		return ""
	_mode = target
	_tool_by_mode[target] = tool_id
	_inverted = false
	_cancel_height_pick()
	_ctx.presenter.hide_ghost()
	tool_changed.emit(tool_id)
	return ""


## Kept for older callers; identical to set_tool().
func set_active_tool(tool_id: String) -> String:
	return set_tool(tool_id)


static func _mode_of(tool_id: String) -> String:
	for mode_id: String in MODES:
		if tool_id in (TOOLS_BY_MODE[mode_id] as Array):
			return mode_id
	return ""


func inverted() -> bool:
	return _inverted


## A no-op (stays false) for tools without an invert behaviour.
func set_inverted(on: bool) -> String:
	var target := on and active_tool() in INVERT_LABELS
	if target != _inverted:
		_inverted = target
		settings_changed.emit("invert")
	return ""


## Auto-paint rule edits (toggle, scrub) of the current document's rules (docs/editor-v2.md §9).
func rule_edits() -> RuleEdits:
	return _rule_edits


# --- Settings ----------------------------------------------------------------------------

func settings(ns: String) -> Dictionary:
	return _values.values(ns)


func set_setting(ns: String, key: String, value: Variant) -> String:
	var err := _values.set_value(ns, key, value)
	if err == "":
		settings_changed.emit(ns)
	return err


func snap_enabled() -> bool:
	return _snap


func set_snap_enabled(on: bool) -> void:
	if on != _snap:
		_snap = on
		settings_changed.emit(TOOL_SELECT)


# --- Armed asset, height pick, ghost -----------------------------------------------------

func arm_asset(asset_id: String) -> String:
	var asset := _ctx.catalog.get_asset(asset_id)
	if asset == null:
		return "Unknown asset '%s'." % asset_id
	var not_ready := _ctx.not_ready_error(asset)
	if not_ready != "":
		return not_ready
	if has_active_operation():
		return BUSY
	_cancel_height_pick()
	if _armed != asset_id:
		_armed = asset_id
		settings_changed.emit("armed")
	return ""


func armed_asset() -> String:
	return _armed


func disarm() -> void:
	if _armed != "":
		_armed = ""
		settings_changed.emit("armed")


## The next tap on the terrain becomes flatten.target. Only while the Flatten tool is active.
func begin_height_pick() -> String:
	if active_tool() != TOOL_FLATTEN:
		return "Select the Flatten tool first."
	if not editing_enabled:
		return "Editing is disabled."
	if has_active_operation():
		return BUSY
	if not _picking:
		_picking = true
		settings_changed.emit(TOOL_FLATTEN)
	return ""


func is_picking_height() -> bool:
	return _picking


func cancel_height_pick() -> void:
	_cancel_height_pick()


## Esc on Mac development input: disarm, cancel height picking and tell the UI to close its popups.
func dismiss() -> void:
	disarm()
	_cancel_height_pick()
	dismissed.emit()


func _cancel_height_pick() -> void:
	_pick_contact = false
	if _picking:
		_picking = false
		settings_changed.emit(TOOL_FLATTEN)


# --- Scatter source ----------------------------------------------------------------------

func set_store() -> ScatterSetStore:
	return _store


func scatter_config() -> Dictionary:
	return ToolCommands.scatter_config(str(_values.values("scatter").source), _store, _mix, _ctx.catalog)


func quick_mix() -> PackedStringArray:
	return _mix.duplicate()


## Only scatter_allowed assets are accepted; on any other id nothing changes.
func set_quick_mix(asset_ids: PackedStringArray) -> String:
	var clean := PackedStringArray()
	for id in asset_ids:
		var asset := _ctx.catalog.get_asset(id)
		if asset == null or not asset.scatter_allowed:
			return "'%s' cannot be scattered." % id
		if not clean.has(id):
			clean.append(id)
	_mix = clean
	settings_changed.emit("scatter")
	return ""
