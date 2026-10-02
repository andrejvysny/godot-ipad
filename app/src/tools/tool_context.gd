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
## `render_ready(asset_id) -> bool`: whether the asset has prepared render derivatives. Unset means ready.
var render_ready: Callable = Callable()
## `scatter_changed(rect: Rect2, heights_only: bool)`: world-XZ rect whose scatter instances need
## redrawing; heights_only when only terrain heights changed (instance membership is unchanged).
var scatter_changed: Callable = Callable()
## `path_changed(ids: Array)`: paths edited live by a tool whose ribbons need redrawing.
var path_changed: Callable = Callable()
## `area_pick(origin, dir) -> Dictionary`: overview group under the ray ({"area": AABB, ...}) or {}.
## `focus_area(area: AABB)`: zooms the camera onto a grouped area (PICK-03). Unset = no overview.
var area_pick: Callable = Callable()
var focus_area: Callable = Callable()
## Returns true after focusing an overview area; the current contact must not edit.
var focus_before_object_action: Callable = Callable()
## StrokeProbe.finish() of the most recent paint/sculpt/path stroke; {} before the first.
var last_stroke: Dictionary = {}


func hit_for(sample: PointerSample) -> TerrainHit:
	return hit_at(sample.position_viewport)


## `pos` is in root-viewport coordinates (the space of PointerSample.position_viewport).
func hit_at(pos: Vector2) -> TerrainHit:
	if camera == null or document == null:
		return TerrainHit.miss(TerrainHit.REASON_INVALID_RAY)
	return TerrainPicker.raycast(document, camera.project_ray_origin(pos), camera.project_ray_normal(pos),
			maxf(TerrainPicker.DEFAULT_MAX_DISTANCE, camera.far))


func notify_scatter(rect: Rect2, heights_only: bool = false) -> void:
	if scatter_changed.is_valid():
		scatter_changed.call(rect, heights_only)


func notify_path(ids: Array) -> void:
	if path_changed.is_valid():
		path_changed.call(ids)


## Height results re-drape scatter: the kernel rect when it has one, else every dirty region.
func _notify_heights(heights: Array, rect: Rect2) -> void:
	if heights.is_empty():
		return
	if rect.has_area():
		notify_scatter(rect, true)
		return
	var span := WorldConstants.REGION_SAMPLES * WorldConstants.SAMPLE_SPACING
	for loc: Vector2i in heights:
		notify_scatter(Rect2(Vector2(loc) * span, Vector2(span, span)), true)


func mark_result(res: Dictionary) -> void:
	_notify_heights(res.get("dirty_heights", []), res.get("rect", Rect2()))
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
	_notify_heights(touched.get("heights", []), Rect2())
	if touched.get("scatter", false):
		notify_scatter(document.layout.extent_rect())
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


## "" when `asset` may be armed, dropped, duplicated or placed; otherwise why not (spec §6.6, PREF-15).
func not_ready_error(asset: AssetDefinition) -> String:
	if render_ready.is_valid() and not bool(render_ready.call(asset.asset_id)):
		return "%s is not ready: render derivatives missing." % asset.display_name
	return ""


func default(section: String, key: String, fallback: Variant) -> Variant:
	var sec: Variant = defaults.get(section)
	if typeof(sec) == TYPE_DICTIONARY and (sec as Dictionary).has(key):
		return (sec as Dictionary)[key]
	return fallback


func report(message: String) -> void:
	if diagnostic.is_valid():
		diagnostic.call(message)
