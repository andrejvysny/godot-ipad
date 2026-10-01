class_name ScatterCellBuilder
extends RefCounted
## Turns a ScatterCell's lists into ScatterBatch nodes under `parent` and owns what decides a batch's
## look: classification (decorative or meaningful, vegetation), the representation through the shared
## RenderWorldResources (coarse-first, placeholder box fitted to the catalog bounds for NOT_READY assets),
## and presentation-only visibility (hidden vegetation, cells covered by an overview group).

const DECORATIVE_ROLE := "mid"

var doc: WorldDocument
var res: ScatterResources
var uploads := 0
var builds := 0
var seed_value := 0
var covered := {}  # Vector2i (object cells) -> true: hidden by an overview group
var veg_hidden := false
var veg_rule: Dictionary = {}

var _parent: Node3D
var _catalog: AssetCatalog
var _registry: RenderAssetRegistry
var _info := {}  # asset_id -> decorative
var _sizes: Array


func _init(parent: Node3D, catalog: AssetCatalog, registry: RenderAssetRegistry, resources: ScatterResources,
		cell_sizes: Array) -> void:
	_parent = parent
	_catalog = catalog
	_registry = registry
	res = resources
	_sizes = cell_sizes


## NOT_READY or unknown assets are meaningful: never thinned.
func is_decorative(asset_id: String) -> bool:
	if not _info.has(asset_id):
		var d := _registry.descriptor(asset_id)
		_info[asset_id] = d != null and d.decorative
	return _info[asset_id]


func reset() -> void:
	_info.clear()
	covered.clear()


func is_vegetation(asset_id: String) -> bool:
	var d := _registry.descriptor(asset_id)
	if d != null:
		return d.vegetation
	return RenderConfig.rule_is_vegetation(veg_rule, _catalog.get_asset(asset_id))


func batch_visible(asset_id: String, cell: ScatterCell) -> bool:
	if veg_hidden and is_vegetation(asset_id):
		return false
	return not (cell.kind == ScatterCell.MEANINGFUL and covered.has(cell.key))


func apply_visibility(cell: ScatterCell) -> void:
	for asset_id: String in cell.batches:
		(cell.batches[asset_id] as ScatterBatch).node.visible = batch_visible(asset_id, cell)


func role_of(cell: ScatterCell) -> String:
	return cell.role if cell.kind == ScatterCell.MEANINGFUL else DECORATIVE_ROLE


## Builds (or refreshes) every asset batch of `cell` at `density` (1.0 for meaningful cells).
func build_cell(cell: ScatterCell, density: float, priority: int) -> void:
	cell.density = density
	cell.drawn = 0
	cell.total = 0
	for asset_id: String in cell.xz:
		_build_batch(cell, asset_id, priority)
		cell.total += (cell.xz[asset_id] as PackedFloat32Array).size() / 2
	for asset_id: String in cell.batches.keys():
		if not cell.xz.has(asset_id):
			_free_batch(cell, asset_id)
	cell.built = true
	builds += 1


## Representation the cell would show now for `asset_id`.
func wanted_rep(cell: ScatterCell, asset_id: String, priority: int) -> String:
	return res.rep_for(asset_id, role_of(cell), priority)


func free_batches(cell: ScatterCell) -> void:
	for asset_id: String in cell.batches.keys():
		_free_batch(cell, asset_id)
	cell.built = false
	cell.drawn = 0
	cell.density = -1.0


func _build_batch(cell: ScatterCell, asset_id: String, priority: int) -> void:
	var rep := wanted_rep(cell, asset_id, priority)
	var mesh := res.mesh_of(asset_id, rep, priority)
	if mesh == null:
		rep = RenderWorldResources.PLACEHOLDER
		mesh = res.box
	var use_place := rep == RenderWorldResources.PLACEHOLDER
	var extent := _bounds(asset_id) if use_place else res.render_aabb(asset_id, rep)
	var place := Transform3D(Basis.from_scale(extent.size), extent.get_center()) if use_place else Transform3D.IDENTITY
	var size: float = _sizes[cell.kind]
	var origin := Vector3(cell.key.x * size, 0.0, cell.key.y * size)
	var out := ScatterBuild.build(doc, cell, asset_id, origin, ScatterBuild.reach_of(extent), use_place, place,
			cell.density, seed_value)
	if int(out.count) == 0:
		_free_batch(cell, asset_id)
		return
	var batch: ScatterBatch = cell.batches.get(asset_id)
	if batch == null:
		batch = ScatterBatch.new(origin)
		cell.batches[asset_id] = batch
		_parent.add_child(batch.node)
	batch.rep = rep
	if batch.apply(out.buffer, out.count, out.aabb, mesh):
		uploads += 1
	batch.node.visible = batch_visible(asset_id, cell)
	cell.drawn += int(out.count)


func _bounds(asset_id: String) -> AABB:
	var asset := _catalog.get_asset(asset_id) if _catalog != null else null
	return asset.bounds if asset != null else RenderWorldResources.UNIT_BOX


func _free_batch(cell: ScatterCell, asset_id: String) -> void:
	var batch: ScatterBatch = cell.batches.get(asset_id)
	if batch != null:
		batch.free_node()
	cell.batches.erase(asset_id)
