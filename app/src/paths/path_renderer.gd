class_name PathRenderer
extends Node3D
## Draws the document's paths as terrain-draped ribbons, one MeshInstance3D per path
## (docs/editor-v2.md §7), plus the selection overlay of the Path tool. Ribbons re-drape when
## their path changes or a terrain edit rect intersects their curve; dirty ones rebuild once per
## frame in flush(). Never mutates the document.

const CURVE_STEP_M := 0.5
const BOUNDS_MARGIN_M := 1.0  # beyond the sampled curve: ribbon half-width never exceeds 3 m

var _doc: WorldDocument
var _nodes := {}  # path_id -> MeshInstance3D
var _bounds := {}  # path_id -> Rect2 (curve bounds grown by the half width)
var _dirty := {}  # path_id -> true
var _material := PathRibbon.material(false)
var _overlay := PathOverlay.new()
var _selected := ""
var _show_handles := false


func _init() -> void:
	add_child(_overlay)


func _process(_delta: float) -> void:
	flush()


## Frees everything and draws every path of `doc` from scratch.
func rebuild(doc: WorldDocument) -> void:
	_doc = doc
	for id: String in _nodes.keys():
		_free_path(id)
	_dirty.clear()
	for id in doc.sorted_path_ids():
		_build(id)
	_refresh_overlay()


## Redraws the listed paths now (added, edited or removed).
func sync(doc: WorldDocument, ids: Array) -> void:
	_doc = doc
	for id: String in ids:
		_dirty.erase(id)
		_build(id)
	if _selected in ids:
		_refresh_overlay()


## sync() against the document last given to rebuild()/sync().
func resync(ids: Array) -> void:
	sync(_doc, ids)


## Marks every path whose bounds intersect `rect` (world XZ) for a re-drape.
func mark_rect(rect: Rect2) -> void:
	for id: String in _bounds:
		if (_bounds[id] as Rect2).intersects(rect, true):
			_dirty[id] = true


func has_dirty() -> bool:
	return not _dirty.is_empty()


func flush() -> void:
	if _dirty.is_empty() or _doc == null:
		return
	var ids := _dirty.keys()
	_dirty.clear()
	for id: String in ids:
		_build(id)
	if _selected in ids:
		_refresh_overlay()


func set_selection(id: String, show_handles: bool) -> void:
	_selected = id
	_show_handles = show_handles
	_refresh_overlay()


func path_count() -> int:
	return _nodes.size()


func node_for(id: String) -> MeshInstance3D:
	return _nodes.get(id)


func selected_id() -> String:
	return _selected


func overlay() -> PathOverlay:
	return _overlay


func _build(id: String) -> void:
	var rec := _doc.get_path_record(id) if _doc != null else null
	if rec == null:
		_free_path(id)
		return
	var curve := PathSpline.sample(rec.points, CURVE_STEP_M)
	var box := Rect2(curve[0], Vector2.ZERO)
	for p in curve:
		box = box.expand(p)
	_bounds[id] = box.grow(rec.width_m * 0.5 + BOUNDS_MARGIN_M)
	var mesh := PathRibbon.build(_doc, curve, rec.width_m)
	var node: MeshInstance3D = _nodes.get(id)
	if mesh == null:
		if node != null:
			node.mesh = null
		return
	if node == null:
		node = MeshInstance3D.new()
		node.material_override = _material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		_nodes[id] = node
	node.mesh = mesh


func _free_path(id: String) -> void:
	var node: MeshInstance3D = _nodes.get(id)
	if node != null:
		remove_child(node)
		node.free()
	_nodes.erase(id)
	_bounds.erase(id)
	_dirty.erase(id)
	if id == _selected:
		_refresh_overlay()


func _refresh_overlay() -> void:
	var rec := _doc.get_path_record(_selected) if _doc != null and _selected != "" else null
	if rec != null and _show_handles:
		_overlay.show_path(_doc, rec)
	else:
		_overlay.hide_overlay()
