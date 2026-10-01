class_name SetPreview
extends Control
## 420 x 294 top-down preview of the set being edited: a green field and the set's thumbnails at the
## ScatterPreview positions. Redraws on the next frame after any change; `generated(count)` reports the
## instance count once the layout was computed.

signal generated(count: int)

const SIZE := Vector2(420, 294)
const FIELD := Color("5b9a40")
const PX_PER_M := 8.4

var _catalog: AssetCatalog
var _set := {}
var _seed := 1
var _instances: Array[Dictionary] = []
var _stale := true
var _textures: Dictionary = {}


func _init() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func setup(catalog: AssetCatalog) -> void:
	_catalog = catalog


func set_data(set_data: Dictionary, seed_value: int) -> void:
	_set = set_data.duplicate(true)
	_seed = seed_value
	_stale = true
	queue_redraw()


func instances() -> Array[Dictionary]:
	_ensure()
	return _instances


func instance_count() -> int:
	return instances().size()


func _ensure() -> void:
	if not _stale or _catalog == null or _set.is_empty():
		return
	_stale = false
	_instances = ScatterPreview.generate(_set, _catalog, _seed)
	generated.emit(_instances.size())


func _texture(asset_id: String) -> Texture2D:
	if not _textures.has(asset_id):
		_textures[asset_id] = load(_catalog.get_asset(asset_id).thumbnail) as Texture2D
	return _textures[asset_id]


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), FIELD)
	_ensure()
	var scale_px := size.x / ScatterPreview.PATCH.x
	for inst in _instances:
		var asset := _catalog.get_asset(str(inst.asset_id))
		var side := clampf(asset.footprint_radius_m * 2.0 * PX_PER_M * 1.5, 14.0, 70.0) * float(inst.scale)
		var at := Vector2(float(inst.x), float(inst.z)) * scale_px
		draw_texture_rect(_texture(str(inst.asset_id)), Rect2(at - Vector2(side * 0.5, side * 0.85), Vector2(side, side)), false)
