class_name ToolContext
extends RefCounted
## Dependencies and callbacks the editor tools need from the session. Plain fields; the session
## owns all lifetimes. `commit(change)` must bump the revision and push history; `request_cancel(reason)`
## must route to InputSystem.cancel_all, which synchronously delivers tool_cancel to the controller.

var document: WorldDocument
var catalog: AssetCatalog
var camera: Camera3D
var terrain: TerrainView
var presenter: ObjectPresenter
var defaults: Dictionary = {}
var commit: Callable = Callable()
var request_cancel: Callable = Callable()
var diagnostic: Callable = Callable()
var units_per_point: Callable = Callable()
var stats: FrameStats
## StrokeProbe.finish() of the most recent paint/sculpt/path stroke; {} before the first.
var last_stroke: Dictionary = {}


func hit_for(sample: PointerSample) -> TerrainHit:
	return hit_at(sample.position_viewport)


## `pos` is in root-viewport coordinates (the space of PointerSample.position_viewport).
func hit_at(pos: Vector2) -> TerrainHit:
	if camera == null or document == null:
		return TerrainHit.miss(TerrainHit.REASON_INVALID_RAY)
	return TerrainPicker.raycast(document, camera.project_ray_origin(pos), camera.project_ray_normal(pos))


func mark_result(res: Dictionary) -> void:
	if terrain == null:
		return
	for loc: Vector2i in res.get("dirty_heights", []):
		terrain.mark_dirty(TerrainView.MAP_HEIGHT, loc)
	for loc: Vector2i in res.get("dirty_controls", []):
		terrain.mark_dirty(TerrainView.MAP_CONTROL, loc)
	for loc: Vector2i in res.get("dirty_colors", []):
		terrain.mark_dirty(TerrainView.MAP_COLOR, loc)


## `touched` is the EditTransaction.rollback() result {heights, controls, objects}.
func mark_touched(touched: Dictionary) -> void:
	if terrain != null:
		for loc: Vector2i in touched.get("heights", []):
			terrain.mark_dirty(TerrainView.MAP_HEIGHT, loc)
		for loc: Vector2i in touched.get("controls", []):
			terrain.mark_dirty(TerrainView.MAP_CONTROL, loc)
		for loc: Vector2i in touched.get("colors", []):
			terrain.mark_dirty(TerrainView.MAP_COLOR, loc)
	if presenter != null:
		for id: String in touched.get("objects", []):
			presenter.sync_object(document, id)


func default(section: String, key: String, fallback: Variant) -> Variant:
	var sec: Variant = defaults.get(section)
	if typeof(sec) == TYPE_DICTIONARY and (sec as Dictionary).has(key):
		return (sec as Dictionary)[key]
	return fallback


func report(message: String) -> void:
	if diagnostic.is_valid():
		diagnostic.call(message)
