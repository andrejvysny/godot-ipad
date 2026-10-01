class_name TexturePreviewController
extends RefCounted
## Fixed-area Texture Preview state machine (docs/rendering-performance-spec.md §11). The area is a
## world-space centre and radius captured at enable time; the controller has no camera or selection
## input, so nothing can retarget it. `generation` increments on every enable, disable and world change
## and tags every cache request, so late results of an older preview are discarded.
## The terrain participant comes first, the object participant (when a presenter is bound) second; both use the
## same begin/progress/publish/release calls and state, missing and bytes aggregate both. Expected failures are returned or put in status(); nothing here logs errors.

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
var _presenter: ObjectPresenter
var _objects: ObjectPreviewParticipant
var _object_progress: Dictionary = {}
var _retiring: Array[ObjectPreviewParticipant] = []  # released, still waiting for pinned cells
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


func bind_objects(presenter: ObjectPresenter) -> void:
	_presenter = presenter


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
	if _state == RELEASING or _state == ERROR or not _retiring.is_empty():
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
	if _presenter != null:
		_objects = ObjectPreviewParticipant.new(_cache, _presenter)
		_objects.begin(xz, r, _owner(), generation)
	_progress = _gather()
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
	_service_objects()
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
	_progress = _gather()
	if int(_progress.pending) == 0:
		_resolve()


## Immutable copy for UI and tests.
func status() -> Dictionary:
	var p := _progress
	return {"state": _state, "center": _center, "radius": _radius, "generation": generation,
		"requested": int(p.get("requested", 0)), "ready": int(p.get("ready", 0)),
		"missing": (p.get("missing", []) as Array).duplicate(), "reasons": (p.get("reasons", {}) as Dictionary).duplicate(),
		"bytes": int(p.get("bytes", 0)),
		"objects_previewed": _objects.previewed_count() if _objects != null else 0,
		"objects_truncated": _objects != null and _objects.truncated(),
		"objects_build_ms": _objects.build_ms if _objects != null else 0.0,
		"objects_deferred": int(_object_progress.get("deferred", 0)),
		"object_textures_requested": int(_object_progress.get("requested", 0)),
		"object_textures_ready": int(_object_progress.get("ready", 0)),
		"object_textures_missing": (_object_progress.get("missing", []) as Array).duplicate(),
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


## Terrain progress plus the object participant's: missing and bytes aggregate, `pending` sums.
func _gather() -> Dictionary:
	var p := _participant.progress()
	if _objects == null:
		return p
	var o := _objects.progress()
	_object_progress = o
	p.pending = int(p.pending) + int(o.pending)
	p.missing = (p.missing as Array) + (o.missing as Array)
	p.reasons = (p.reasons as Dictionary).merged(o.reasons as Dictionary)
	p.bytes = int(p.bytes) + int(o.bytes)
	return p


## Object bindings that waited for pins, membership changes, and released participants still waiting for pins.
func _service_objects() -> void:
	if _objects != null and (_state == ACTIVE or _state == LIMITED):
		_objects.service()
		_progress = _gather()
	for p in _retiring.duplicate():
		p.service_release()
		if not p.release_pending():
			_retiring.erase(p)


func _resolve() -> void:
	var missing := (_progress.missing as Array).size()
	var err := _participant.publish()
	if err == "" and _objects != null:
		err = _objects.publish()
		_object_progress = _objects.progress()
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
	_object_progress = {}
	_participant = null
	_objects = null
	_busy_frame = Engine.get_process_frames()
	_state = RELEASING


## Restores the low tier, drops cache references and cancels this preview's pending loads. Cancelled
## loads still in flight are drained by service(); their results are discarded by the cache.
func _teardown() -> void:
	if _participant != null:
		_participant.release()
	if _objects != null:
		_objects.release()
		if _objects.release_pending():
			_retiring.append(_objects)
	_draining = _cache.cancel_generation("preview_generation", _live_generation) > 0 or _draining
	_cache.release(_owner())
	_released_bytes = _cache.retire_unreferenced("preview_texture")
