class_name TerrainHit
extends RefCounted
## Typed terrain pick result (spec §11.3). A miss never carries a zero/origin position:
## position, normal and distance are NAN and region is NO_REGION. A grazing hit keeps
## its position and normal for diagnostics but has ok = false.

const REASON_HIT := "hit"
const REASON_NO_HIT := "no_hit"
const REASON_OUTSIDE := "outside"
const REASON_GRAZING := "grazing"
const REASON_INVALID_RAY := "invalid_ray"
## Same sentinel Terrain3DRegion uses for an unset location; never a loadable region.
const NO_REGION := Vector2i(2147483647, 2147483647)

var ok: bool = false
var reason: String = REASON_NO_HIT
var position: Vector3 = Vector3(NAN, NAN, NAN)
var normal: Vector3 = Vector3(NAN, NAN, NAN)
var distance: float = NAN
var region: Vector2i = NO_REGION


static func miss(miss_reason: String) -> TerrainHit:
	var h := TerrainHit.new()
	h.reason = miss_reason
	return h


static func surface(pos: Vector3, surface_normal: Vector3, dist: float, loc: Vector2i, grazing: bool) -> TerrainHit:
	var h := TerrainHit.new()
	h.ok = not grazing
	h.reason = REASON_GRAZING if grazing else REASON_HIT
	h.position = pos
	h.normal = surface_normal
	h.distance = dist
	h.region = loc
	return h


func _to_string() -> String:
	return "TerrainHit(%s ok=%s pos=%s d=%.4f region=%s)" % [reason, ok, position, distance, region]
