class_name PointerSample
extends RefCounted
## Normalized pointer record (spec §6.1). Providers fill the raw fields; the input system maps
## `position_raw` to `position_viewport` exactly once via CoordinateMapper and stamps
## `mapping_generation`. Source identity comes from the platform's contact type only.

enum Source { UNKNOWN, PENCIL, FINGER, MOUSE_DEV }
enum Phase { BEGIN, MOVE, END, CANCEL }

var source: int = Source.UNKNOWN
var pointer_id: int = -1  ## session-local, stable for the contact's lifetime
var phase: int = Phase.MOVE
var timestamp_s: float = 0.0  ## provider clock; see InputProvider.now_seconds()
var position_raw := Vector2.ZERO  ## provider space (InputProvider.coordinate_space())
var position_viewport := Vector2.ZERO  ## root-viewport canvas coordinates (logical points)
var pressure_valid := false
var pressure: float = 0.0  ## [0, 1], meaningful only when pressure_valid
var tilt_valid := false
var tilt := Vector2.ZERO
var is_predicted := false  ## predicted samples may move a cursor only; never edit
var is_coalesced := false
var sample_sequence: int = 0  ## monotonic per provider
var mapping_generation: int = -1
var cancel_reason: String = ""  ## set on CANCEL
var major_radius_valid := false
var major_radius: float = 0.0  ## UITouch.majorRadius in points; meaningful only when major_radius_valid


func is_pencil_like() -> bool:
	return source == Source.PENCIL or source == Source.MOUSE_DEV


func is_terminal() -> bool:
	return phase == Phase.END or phase == Phase.CANCEL


func clone() -> PointerSample:
	var s := PointerSample.new()
	s.source = source
	s.pointer_id = pointer_id
	s.phase = phase
	s.timestamp_s = timestamp_s
	s.position_raw = position_raw
	s.position_viewport = position_viewport
	s.pressure_valid = pressure_valid
	s.pressure = pressure
	s.tilt_valid = tilt_valid
	s.tilt = tilt
	s.is_predicted = is_predicted
	s.is_coalesced = is_coalesced
	s.sample_sequence = sample_sequence
	s.mapping_generation = mapping_generation
	s.cancel_reason = cancel_reason
	s.major_radius_valid = major_radius_valid
	s.major_radius = major_radius
	return s


func to_dict() -> Dictionary:
	return {
		"source": Source.keys()[source], "id": pointer_id, "phase": Phase.keys()[phase],
		"t": timestamp_s, "raw": [position_raw.x, position_raw.y],
		"vp": [position_viewport.x, position_viewport.y],
		"pressure": pressure if pressure_valid else null,
		"tilt": [tilt.x, tilt.y] if tilt_valid else null,
		"predicted": is_predicted, "coalesced": is_coalesced, "seq": sample_sequence,
		"gen": mapping_generation, "cancel_reason": cancel_reason,
	}


static func source_name(s: int) -> String:
	return Source.keys()[s] if s >= 0 and s < Source.size() else "INVALID"


static func phase_name(p: int) -> String:
	return Phase.keys()[p] if p >= 0 and p < Phase.size() else "INVALID"
