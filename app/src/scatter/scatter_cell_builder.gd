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
var refresh_needed := false
var seed_value := 0
var covered := {}  # Vector2i (object cells) -> true: hidden by an overview group
var view_suppressed := false
var snapshot: RenderCameraSnapshot
var profile: Dictionary = {}
var allow_upgrades := true
var pinned := false
var jobs := {}
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
	jobs.clear()


func is_vegetation(asset_id: String) -> bool:
	var d := _registry.descriptor(asset_id)
	if d != null:
		return d.vegetation
	return RenderConfig.rule_is_vegetation(veg_rule, _catalog.get_asset(asset_id))


func batch_visible(asset_id: String, cell: ScatterCell) -> bool:
	if view_suppressed or (veg_hidden and is_vegetation(asset_id)):
		return false
	return not (cell.kind == ScatterCell.MEANINGFUL and covered.has(cell.key))


func apply_visibility(cell: ScatterCell) -> void:
	for batch: ScatterBatch in cell.batches.values():
		batch.node.visible = batch_visible(batch.asset_id, cell)


func role_of(cell: ScatterCell) -> String:
	return cell.role if cell.kind == ScatterCell.MEANINGFUL else DECORATIVE_ROLE


## Advances one bounded source chunk; logical cell membership is never compacted.
func build_cell(cell: ScatterCell, density: float, priority: int) -> bool:
	var id := Vector3i(cell.key.x, cell.key.y, cell.kind)
	var job: ScatterSubmission = jobs.get(id)
	if job == null:
		job = ScatterSubmission.new(cell, density)
		jobs[id] = job
	if not job.advance(self, priority):
		return false
	refresh_needed = not is_equal_approx(job.density, density) or (allow_upgrades and not job.initial_upgrades)
	if snapshot != null:
		refresh_needed = refresh_needed or not snapshot.same_inputs(job.initial_snapshot)
	cell.density = job.density
	cell.total = cell.count()
	cell.drawn = job.drawn
	cell.built = true
	jobs.erase(id)
	builds += 1
	return true


func invalidate(cell: ScatterCell) -> void:
	jobs.erase(Vector3i(cell.key.x, cell.key.y, cell.kind))


func wanted_rep(cell: ScatterCell, asset_id: String, priority: int) -> String:
	return res.rep_for(asset_id, role_of(cell), priority)


func free_batches(cell: ScatterCell) -> void:
	invalidate(cell)
	for key: String in cell.batches.keys():
		_free_batch(cell, key)
	cell.batch_chunks.clear()
	cell.built = false
	cell.drawn = 0
	cell.density = -1.0


func bounds(asset_id: String) -> AABB:
	return _bounds(asset_id)


func submit(cell: ScatterCell, part: ScatterCell, asset_id: String, role: String, chunk: int,
		priority: int) -> String:
	var key := "%s|%s|%d" % [asset_id, role, chunk]
	var rep := res.rep_for(asset_id, role, priority)
	if rep != role:
		for previous_key: String in cell.batch_chunks.get("%s|%d" % [asset_id, chunk], []):
			var previous: ScatterBatch = cell.batches[previous_key]
			if previous.rep != RenderWorldResources.PLACEHOLDER:
				rep = previous.rep
				break
	var mesh := res.mesh_of(asset_id, rep, priority)
	if mesh == null:
		rep = RenderWorldResources.PLACEHOLDER
		mesh = res.box
	var use_place := rep == RenderWorldResources.PLACEHOLDER
	var extent := _bounds(asset_id) if use_place else res.render_aabb(asset_id, rep)
	var place := Transform3D(Basis.from_scale(extent.size), extent.get_center()) if use_place else Transform3D.IDENTITY
	var size: float = _sizes[cell.kind]
	var origin := Vector3(cell.key.x * size, 0.0, cell.key.y * size)
	var out := ScatterBuild.build(doc, part, asset_id, origin, ScatterBuild.reach_of(extent), use_place, place,
			1.0, seed_value)
	if int(out.count) == 0:
		return ""
	var batch: ScatterBatch = cell.batches.get(key)
	if batch == null:
		batch = ScatterBatch.new(origin)
		cell.batches[key] = batch
		_parent.add_child(batch.node)
	batch.chunk = chunk
	batch.asset_id = asset_id
	batch.wanted_role = role
	batch.rep = rep
	if batch.apply(out.buffer, out.count, out.aabb, mesh):
		uploads += 1
	batch.node.visible = batch_visible(asset_id, cell)
	return key


## Replaces a source chunk as one synchronous step, including instances now culled.
func retire_chunk(cell: ScatterCell, asset_id: String, chunk: int, submitted: Dictionary) -> void:
	var index := "%s|%d" % [asset_id, chunk]
	for key: String in cell.batch_chunks.get(index, []):
		if not submitted.has(key):
			_free_batch(cell, key)
	if submitted.is_empty():
		cell.batch_chunks.erase(index)
	else:
		cell.batch_chunks[index] = submitted.keys()


func retire_batch(cell: ScatterCell, key: String) -> void:
	var batch: ScatterBatch = cell.batches.get(key)
	if batch == null:
		return
	var index := "%s|%d" % [batch.asset_id, batch.chunk]
	var keys: Array = cell.batch_chunks.get(index, [])
	keys.erase(key)
	if keys.is_empty():
		cell.batch_chunks.erase(index)
	_free_batch(cell, key)


func _bounds(asset_id: String) -> AABB:
	var asset := _catalog.get_asset(asset_id) if _catalog != null else null
	return asset.bounds if asset != null else RenderWorldResources.UNIT_BOX


func _free_batch(cell: ScatterCell, asset_id: String) -> void:
	var batch: ScatterBatch = cell.batches.get(asset_id)
	if batch != null:
		batch.free_node()
	cell.batches.erase(asset_id)
