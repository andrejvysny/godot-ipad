class_name TexturePreviewController
extends RefCounted
## Fixed-area Texture Preview state machine (docs/rendering-performance-spec.md §11). The area is a
## world-space centre and radius captured at enable time; the controller has no camera or selection
## input, so nothing can retarget it. `generation` increments on every enable, disable and world change
## and tags every cache request, so late results of an older preview are discarded.
## Only the terrain participant exists today; objects join through the same begin/progress/publish/release
## calls. Expected failures are returned or put in status(); nothing here logs errors.

const OFF := "OFF"
const LOADING := "LOADING"
const ACTIVE := "ACTIVE"
const LIMITED := "LIMITED"
const RELEASING := "RELEASING"
const ERROR := "ERROR"
const FEATHER_M := 1.5
const NO_AREA := "Select an object or aim at terrain to preview textures."

var generation := 0

var _live_generation := 0  # generation of the current or last enabled preview; names its cache owner
var _cause := ""

var _cache: RenderAssetCache
var _config: Dictionary
var _sources: Dictionary
var _terrain: TerrainView
var _doc: WorldDocument
var _participant: TerrainPreviewParticipant
var _state := OFF
var _center := Vector3.ZERO
var _radius := 0.0
var _reason := ""
var _progress: Dictionary = {}
var _released_bytes := 0
var _draining := false  # cancelled loads still in flight; the cache must keep being polled
## Process frame of the last release or discard. RELEASING lasts until a later frame so textures dropped
## by a release are never requested again within the same frame.
var _busy_frame := -1


## `preview_config`: the RenderConfig section "texture_preview". `sources` overrides the terrain
## texture paths (tests): slot -> {"albedo": path, "normal": path}.
func _init(cache: RenderAssetCache, preview_config: Dictionary, sources: Dictionary = {}) -> void:
	_cache = cache
	_config = preview_config.duplicate()
	_sources = sources


func bind(terrain: TerrainView, doc: WorldDocument) -> void:
	_terrain = terrain
	_doc = doc


func state() -> String:
	return _state


## {"ok": bool, "message": String}. The centre is clamped into the world rectangle; y is kept for drawing.
func enable_at(center: Vector3, radius: float = -1.0) -> Dictionary:
	if _terrain == null or _doc == null:
		return _refuse("Texture Preview needs an open world.")
	if not center.is_finite():
		return _refuse(NO_AREA)
	if _state == ERROR and Engine.get_process_frames() > _busy_frame:
		_participant = null
		_state = OFF
	if _state == RELEASING or _state == ERROR:
		return _refuse("Texture Preview is still releasing.")
	if _state != OFF:
		return _refuse("Texture Preview is already on.")
	var r := float(_config.get("radius_m", 20.0)) if radius <= 0.0 else radius
	var rect := _doc.layout.world_rect()
	var xz := Vector2(center.x, center.z).clamp(rect.position, rect.end)
	generation += 1
	_live_generation = generation
	_center = Vector3(xz.x, center.y, xz.y)
	_radius = r
	_reason = ""
	_cause = ""
	_released_bytes = 0
	_participant = TerrainPreviewParticipant.new(_cache, _terrain, _doc, _sources)
	_state = LOADING
	var err := _participant.begin(xz, r, minf(FEATHER_M, r), int(_config.get("max_terrain_materials", 4)),
			_owner(), generation)
	if err != "":
		_fail(err)
		return _refuse(err)
	_progress = _participant.progress()
	if int(_progress.pending) == 0:
		_resolve()
	return {"ok": _state != ERROR, "message": _reason}


func disable(reason: String) -> void:
	_release(reason, "")


## Safety hook (memory pressure, lifecycle): same as disable with the state reason "suspended".
func suspend(cause: String) -> void:
	_release("suspended", cause)


func on_world_replaced() -> void:
	_release("world_replaced", "")
	generation += 1
	_terrain = null
	_doc = null


## Polls the cache while a load or a cancelled load is in flight, publishes when everything resolved and
## finishes RELEASING one frame after the release.
func service(budget_ms: float) -> void:
	if _state != LOADING and not _draining:
		if _state == RELEASING and Engine.get_process_frames() > _busy_frame:
			_state = OFF
		return
	_cache.poll(budget_ms)
	if _draining:
		var st := _cache.stats()
		if int(st.queued) + int(st.loading) == 0:
			_draining = false
			_busy_frame = Engine.get_process_frames()
			_released_bytes += _cache.retire_unreferenced("preview_texture")
	if _state != LOADING:
		return
	_progress = _participant.progress()
	if int(_progress.pending) == 0:
		_resolve()


## Immutable copy for UI and tests.
func status() -> Dictionary:
	var p := _progress
	return {"state": _state, "center": _center, "radius": _radius, "generation": generation,
		"requested": int(p.get("requested", 0)), "ready": int(p.get("ready", 0)),
		"missing": (p.get("missing", []) as Array).duplicate(), "reasons": (p.get("reasons", {}) as Dictionary).duplicate(),
		"bytes": int(p.get("bytes", 0)),
		"reason": _reason, "cause": _cause, "released_bytes": _released_bytes,
		"slots": _participant.slots() if _participant != null else PackedInt32Array(),
		"build_ms": _participant.build_ms if _participant != null else 0.0,
		"image_ms": _participant.image_ms if _participant != null else 0.0}


## Text of the Performance menu status line.
static func status_text(st: Dictionary) -> String:
	match str(st.state):
		LOADING:
			return "Loading…"
		ACTIVE:
			return "Active · area %d, %d · r %d m" % [roundi(st.center.x), roundi(st.center.z), roundi(st.radius)]
		LIMITED:
			return "Limited · %d textures missing" % (st.missing as Array).size()
		RELEASING:
			return "Releasing…"
		ERROR:
			return "Error: %s" % st.reason
	return "Off"


func _owner() -> String:
	return "preview:%d" % _live_generation


func _resolve() -> void:
	var missing := (_progress.missing as Array).size()
	var err := _participant.publish()
	if err != "":
		_fail(err)
		return
	_state = LIMITED if missing > 0 else ACTIVE


func _fail(message: String) -> void:
	_reason = message
	_teardown()
	_busy_frame = Engine.get_process_frames()
	_state = ERROR


func _refuse(message: String) -> Dictionary:
	_reason = message
	return {"ok": false, "message": message}


func _release(reason: String, cause: String) -> void:
	if _state == OFF and not _draining and _participant == null:
		return
	_state = RELEASING
	_teardown()
	generation += 1
	_reason = reason
	_cause = cause
	_progress = {}
	_participant = null
	_busy_frame = Engine.get_process_frames()
	_state = RELEASING


## Restores the low tier, drops cache references and cancels this preview's pending loads. Cancelled
## loads still in flight are drained by service(); their results are discarded by the cache.
func _teardown() -> void:
	if _participant != null:
		_participant.release()
	_draining = _cache.cancel_generation("preview_generation", _live_generation) > 0 or _draining
	_cache.release(_owner())
	_released_bytes = _cache.retire_unreferenced("preview_texture")
