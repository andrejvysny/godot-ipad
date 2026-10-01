class_name PickOperation
extends RefCounted
## Pick tool (docs/editor-v2.md §4): a tap reads the visible material layer under the Pencil. It
## never edits the document or history; ToolController applies picked_layer() to `paint.layer`.

var error: String = ""

var _ctx: ToolContext
var _layer := -1
var _id := ObjectRecord.new_uuid_v4()


func _init(ctx: ToolContext) -> void:
	_ctx = ctx


func operation_id() -> String:
	return _id


## The picked layer 0-3, or -1 when the tap hit no terrain (reported by end()).
func picked_layer() -> int:
	return _layer


func begin(_sample: PointerSample, _hit: TerrainHit) -> void:
	pass


func move(_sample: PointerSample, _hit: TerrainHit) -> void:
	pass


func resume(_sample: PointerSample, _hit: TerrainHit) -> void:
	pass


func pause(_sample: PointerSample) -> void:
	pass


func advance(_now: float) -> void:
	pass


func cancel() -> void:
	pass


func is_moving() -> bool:
	return false


func end(_sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if over_ui:
		return null
	if hit.ok:
		_layer = layer_at(_ctx.document, hit.position.x, hit.position.z)
	if _layer < 0:
		_ctx.report("No terrain under the Pencil.")
	return null


## Visible layer at (x, z): the overlay once its blend reaches one half, otherwise the manual
## base, otherwise the auto-paint rule material. -1 without a terrain sample.
static func layer_at(doc: WorldDocument, x: float, z: float) -> int:
	if is_nan(doc.sample_height(x, z)):
		return -1
	var sp := WorldConstants.SAMPLE_SPACING
	var control := doc.get_control_at_sample(roundi(x / sp), roundi(z / sp))
	if control < 0:
		return -1
	if float(ControlCodec.get_blend(control)) / 255.0 >= 0.5:
		return ControlCodec.get_overlay(control)
	if (control & ControlCodec.AUTO_BIT) == 0:
		return ControlCodec.get_base(control)
	return TerrainRules.material_at(doc, x, z)
