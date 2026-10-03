class_name ScatterSubmission
extends RefCounted
## Source chunks bound classification and uploads; identity-based thinning stays stable across edits.

const CHUNK_INSTANCES := 128

var kept := {}
var drawn := 0
var _cell: ScatterCell
var density: float
var initial_snapshot: RenderCameraSnapshot
var initial_upgrades := false
var started := false
var _presentation := {}
var _retire: Array
var _retire_offset := 0
var _assets: Array
var _asset := 0
var _offset := 0


func _init(cell: ScatterCell, density: float) -> void:
	_cell = cell
	self.density = density
	_assets = cell.xz.keys()
	_retire = cell.batches.keys()


func advance(builder: ScatterCellBuilder, priority: int) -> bool:
	if not started:
		started = true
		initial_snapshot = builder.snapshot
		initial_upgrades = builder.allow_upgrades
	if _asset >= _assets.size():
		return _cleanup(builder)
	var asset_id: String = _assets[_asset]
	var xz: PackedFloat32Array = _cell.xz[asset_id]
	var attr: PackedFloat32Array = _cell.attr[asset_id]
	var end := mini(_offset + CHUNK_INSTANCES, xz.size() / 2)
	var parts := {}
	for i in range(_offset, end):
		var xf: Variant = ScatterBuild.world_transform(builder.doc, xz[i * 2], xz[i * 2 + 1],
				attr[i * 3], attr[i * 3 + 1], int(attr[i * 3 + 2]))
		if xf == null:
			continue
		var key := ScatterDensity.key(asset_id, xz[i * 2], xz[i * 2 + 1], builder.seed_value)
		var identity := asset_id + "|" + PackedFloat32Array([xz[i * 2], xz[i * 2 + 1],
				attr[i * 3], attr[i * 3 + 1], attr[i * 3 + 2]]).to_byte_array().hex_encode()
		var choice := _choose(builder, asset_id, xf, identity)
		if not choice.visible or not ScatterDensity.keeps(key, float(choice.density)):
			continue
		var role: String = choice.role
		var part: ScatterCell = parts.get(role)
		if part == null:
			part = ScatterCell.new(_cell.key, _cell.kind)
			parts[role] = part
		part.add(asset_id, xz[i * 2], xz[i * 2 + 1], attr[i * 3], attr[i * 3 + 1], int(attr[i * 3 + 2]))
	var submitted := {}
	for role: String in parts:
		var batch_key := builder.submit(_cell, parts[role], asset_id, role, _offset / CHUNK_INSTANCES, priority)
		if batch_key != "":
			submitted[batch_key] = true
			kept[batch_key] = true
			drawn += (_cell.batches[batch_key] as ScatterBatch).count
	builder.retire_chunk(_cell, asset_id, _offset / CHUNK_INSTANCES, submitted)
	_offset = end
	if _offset >= xz.size() / 2:
		_asset += 1
		_offset = 0
	return false


func _cleanup(builder: ScatterCellBuilder) -> bool:
	var end := mini(_retire_offset + CHUNK_INSTANCES, _retire.size())
	for index in range(_retire_offset, end):
		var key: String = _retire[index]
		if not kept.has(key):
			builder.retire_batch(_cell, key)
	_retire_offset = end
	if end == _retire.size():
		_cell.presentation = _presentation
		return true
	return false


func _choose(builder: ScatterCellBuilder, asset_id: String, xf: Transform3D, identity: String) -> Dictionary:
	var previous: Dictionary = _cell.presentation.get(identity, {})
	if builder.pinned and not previous.is_empty():
		var frozen := previous.duplicate()
		frozen.density = self.density
		_presentation[identity] = frozen
		return frozen
	var decorative := _cell.kind == ScatterCell.DECORATIVE
	var role := builder.role_of(_cell)
	var visible := true
	var density := self.density
	var conservative := not bool(builder.profile.get("size_policy_enabled", true)) or builder.snapshot == null or not builder.snapshot.valid
	if not builder.pinned and bool(builder.profile.get("size_policy_enabled", true)) and builder.snapshot != null and builder.snapshot.valid:
		var projected := ProjectedBounds.measure(xf * builder.bounds(asset_id), builder.snapshot)
		conservative = not projected.valid or projected.conservative
		if not conservative:
			visible = not projected.behind and LodPolicy.size_visible(projected.reference_px,
					bool(previous.get("visible", true)), decorative, builder.profile)
			if not decorative:
				role = LodPolicy.size_role(projected.reference_px, builder.profile, str(previous.get("role", "")))
	if not builder.allow_upgrades and not previous.is_empty():
		if not conservative:
			visible = visible and bool(previous.visible)
		var roles := [LodPolicy.NEAR, LodPolicy.MID, LodPolicy.FAR]
		if roles.find(role) < roles.find(str(previous.role)):
			role = str(previous.role)
		density = minf(density, float(previous.density))
	var choice := {"visible": visible, "role": role, "density": density}
	_presentation[identity] = choice
	return choice
