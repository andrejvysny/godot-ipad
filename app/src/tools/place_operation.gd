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
var _over_ui := false
var _max_other_m := -1.0  # largest footprint x scale_max in the catalog (conflict query radius)


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
	_over_ui = true
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
	var limit := ToolCommands.object_limit_error(doc)
	if limit != "":
		cancel()
		_ctx.report(limit)
		return null
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


## Turns the candidate yaw; snaps to the placement yaw snap when snapping is on.
func rotate_yaw(delta_deg: float) -> void:
	var snap := float(_ctx.default("placement", "yaw_snap_deg", 15.0)) if _snap else 0.0
	ObjectEdits.apply_yaw(_record, rad_to_deg(_record.get_yaw()) + delta_deg, snap)
	_show()


func yaw_deg() -> float:
	return rad_to_deg(_record.get_yaw())


func _update(hit: TerrainHit) -> void:
	_over_ui = false
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
	if not _ctx.document.layout.is_inside_world(x, z):
		return null
	var h := _ctx.document.sample_height(x, z)
	if is_nan(h):
		return null
	return Vector3(x, h + _record.height_offset_m, z)


func _show() -> void:
	if _ever_valid:
		_ctx.presenter.show_ghost(_record, _valid_now)


static func empty_preview() -> Dictionary:
	return {"active": false, "asset_name": "", "world_pos": Vector3.ZERO, "valid": false, "over_ui": false,
			"slope_deg": 0.0, "yaw_deg": 0.0, "conflict": ""}


## Ghost label state (ToolController.place_preview()). Active once the ghost has been shown.
func preview() -> Dictionary:
	var pos := _record.get_position_v3()
	var normal := _ctx.document.sample_normal(pos.x, pos.z)
	return {"active": _ever_valid, "asset_name": _asset.display_name, "world_pos": pos, "valid": _valid_now,
			"over_ui": _over_ui, "slope_deg": rad_to_deg(acos(clampf(normal.y, -1.0, 1.0))) if normal.is_finite() else 0.0,
			"yaw_deg": yaw_deg(), "conflict": _conflict(pos)}


## Name of the first manual object whose footprint overlaps the candidate (distance < 0.8 (r_a s_a + r_b s_b)).
func _conflict(pos: Vector3) -> String:
	var mine := _asset.footprint_radius_m * _record.uniform_scale
	var reach_max := 0.8 * (mine + _max_other_footprint())
	for id in _ctx.presenter.objects_in_rect(Rect2(pos.x - reach_max, pos.z - reach_max, reach_max * 2.0, reach_max * 2.0)):
		var other := _ctx.document.get_object(id)
		var asset := _ctx.catalog.get_asset(other.asset_id) if other != null else null
		if other == null or other.origin != WorldConstants.ORIGIN_MANUAL or asset == null:
			continue
		var reach := 0.8 * (mine + asset.footprint_radius_m * other.uniform_scale)
		if Vector2(pos.x - other.position[0], pos.z - other.position[2]).length() < reach:
			return asset.display_name
	return ""


func _max_other_footprint() -> float:
	if _max_other_m < 0.0:
		_max_other_m = 0.0
		for asset_id in _ctx.catalog.sorted_ids():
			var a := _ctx.catalog.get_asset(asset_id)
			_max_other_m = maxf(_max_other_m, a.footprint_radius_m * a.scale_max)
	return _max_other_m
