class_name PlaceOperation
extends RefCounted
## Drag-to-place (spec §14.2). The document is untouched until a valid release: the drag only
## drives the presenter ghost. Terrain-only picking means objects never influence placement (OB-04).

var error: String = ""

var _ctx: ToolContext
var _asset: AssetDefinition
var _snap: bool
var _record := ObjectRecord.new()
var _id := ObjectRecord.new_uuid_v4()
var _ever_valid := false
var _valid_now := false
var _created := ""


func _init(ctx: ToolContext, asset: AssetDefinition, snap: bool) -> void:
	_ctx = ctx
	_asset = asset
	_snap = snap
	_record.object_id = ObjectRecord.new_uuid_v4()
	_record.asset_id = asset.asset_id
	_record.asset_version = asset.version
	_record.grounding = asset.default_grounding
	_record.uniform_scale = clampf(1.0, asset.scale_min, asset.scale_max)
	_record.height_offset_m = 0.0
	_record.origin = WorldConstants.ORIGIN_MANUAL


func operation_id() -> String:
	return _id


func created_id() -> String:
	return _created


func begin(_sample: PointerSample, hit: TerrainHit) -> void:
	_update(hit)


func move(_sample: PointerSample, hit: TerrainHit) -> void:
	_update(hit)


func resume(_sample: PointerSample, hit: TerrainHit) -> void:
	_update(hit)


func pause(_sample: PointerSample) -> void:
	_valid_now = false
	_show()


func advance(_now: float) -> void:
	pass


func end(sample: PointerSample, hit: TerrainHit, over_ui: bool) -> WorldChange:
	if not over_ui:
		_update(hit)
	if over_ui or not _valid_now or not _ever_valid:
		cancel()
		_ctx.report("Placement cancelled: lift the Pencil over terrain to place.")
		return null
	var doc := _ctx.document
	var tx := EditTransaction.new()
	tx.begin(doc, "place", "Place %s" % _asset.display_name)
	if not tx.capture_object(_record.object_id):
		tx.rollback()
		error = BrushKernels.ERROR_BUDGET
		return null
	doc.put_object(_record.clone())
	_ctx.presenter.sync_object(doc, _record.object_id)
	_ctx.presenter.hide_ghost()
	_created = _record.object_id
	return tx.finish()


func cancel() -> void:
	_ctx.presenter.hide_ghost()


func _update(hit: TerrainHit) -> void:
	var p: Variant = _candidate(hit)
	_valid_now = p != null
	if _valid_now:
		var v: Vector3 = p
		_record.set_position(v.x, v.y, v.z)
		_ever_valid = true
	_show()


func _candidate(hit: TerrainHit) -> Variant:
	if not hit.ok:
		return null
	var x: float = hit.position.x
	var z: float = hit.position.z
	if _snap:
		var step := float(_ctx.default("placement", "move_snap_m", 0.5))
		x = snappedf(x, step)
		z = snappedf(z, step)
	if not WorldConstants.is_inside_world(x, z):
		return null
	var h := _ctx.document.sample_height(x, z)
	if is_nan(h):
		return null
	return Vector3(x, h + _record.height_offset_m, z)


func _show() -> void:
	if _ever_valid:
		_ctx.presenter.show_ghost(_record, _valid_now)
