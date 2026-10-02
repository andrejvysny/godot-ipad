class_name RenderViewState
extends RefCounted
## Whole-world overview eligibility uses the unclipped footprint and downward camera pitch.

const LOCAL := "local"
const REGIONAL := "regional"
const TERRAIN_ONLY := "terrain_only"

var state := LOCAL
var forced_state := ""
var _settings: Dictionary = {}
var _local_focus := false


func configure(settings: Dictionary) -> void:
	_settings = settings.duplicate()


func force_state(value: String) -> void:
	if value == "" or value in [LOCAL, REGIONAL, TERRAIN_ONLY]:
		forced_state = value
		if value != "":
			state = value


func clear_for_local_focus() -> void:
	forced_state = ""
	_local_focus = true
	state = LOCAL


func update(snapshot: RenderCameraSnapshot, world_bounds: AABB, operation_active: bool = false) -> bool:
	if operation_active:
		return false
	var previous := state
	if forced_state != "":
		state = forced_state
		return state != previous
	var measured := ProjectedBounds.measure(world_bounds, snapshot)
	if not measured.valid or measured.conservative or measured.behind:
		if state == TERRAIN_ONLY:
			state = REGIONAL
		return state != previous
	var extent := float(measured.extent_ratio)
	var pitch := snapshot.downward_pitch_deg
	var exits := extent > float(_settings.get("exit_extent_ratio", 1.30)) \
			or pitch < float(_settings.get("exit_pitch_deg", 35.0))
	if _local_focus:
		if not exits:
			return false
		_local_focus = false
	if state == TERRAIN_ONLY:
		if exits:
			state = REGIONAL
	elif extent <= float(_settings.get("enter_extent_ratio", 1.10)) \
			and pitch >= float(_settings.get("enter_pitch_deg", 45.0)):
		state = TERRAIN_ONLY
	return state != previous
