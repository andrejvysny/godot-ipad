class_name ScatterRenderer
extends Node3D
## Draws the document's scatter layer through prepared registry tiers in spatial batches (spec §7, §10;
## docs/editor-v2.md §6). Never mutates the document; saved scatter data is the only authority.
## - Decorative assets (descriptor.decorative: grass, ferns, pebbles) live in 16 m ground-cover cells, drawn only
##   inside the profile's ground-cover radius, thinned by a deterministic nested subset (ScatterDensity) whose
##   density is higher inside the active area (ScatterView).
## - Everything else (trees, rocks) is meaningful: 32 m cells, LodPolicy individual roles (near/mid/far), never
##   thinned. The overview interface (overview_members / set_cells_covered / overview_changed) lets the HLOD
##   overview group them; decorative cells are never covered.
## Meshes come from the shared RenderAssetCache through ScatterResources (coarse-first, shared placeholder box
## for NOT_READY assets); the catalog scatter_mesh is not used. Instance Y follows the terrain. Nothing casts
## shadows. All work happens in service_frame(budget_ms); there is no _process. Scheduling lives in
## ScatterEngine, batch construction in ScatterCellBuilder.

## Meaningful instances changed inside `rect` (scatter edits, re-drape, rebuild_all/mark_all: the whole layout).
## Not emitted for density, visibility or camera-driven changes.
signal overview_changed(rect: Rect2)

const CELL_M := 32.0  # object cell size of the static cell_of()

var last_rebuild_ms: float:
	get:
		return _engine.last_rebuild_ms

var _engine: ScatterEngine
# Re-applied when setup() replaces the engine (render bench catalog swaps).
var _camera: Camera3D
var _area: ActiveEditArea
var _profile: Dictionary = {}
var _catalog_id := ""


## Without a registry/cache (tests, tools) the committed registry is loaded and a default cache is owned and
## polled by service_frame().
func setup(catalog: AssetCatalog, registry: RenderAssetRegistry = null, cache: RenderAssetCache = null,
		config: RenderConfig = null) -> void:
	var cfg := config if config != null else RenderConfig.load_from()
	var reg := registry if registry != null else RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	var budgets := cfg.section("budgets")
	if RenderingServer.get_rendering_device() == null:
		budgets.inflight_loads = 1  # the dummy renderer's storage is not thread-safe (as in SessionRender)
	var shared := cache if cache != null else RenderAssetCache.new(budgets)
	if _engine != null:
		_engine.overview_changed.disconnect(overview_changed.emit)
		_engine.teardown()
	_engine = ScatterEngine.new(self, catalog, reg, shared, cache == null, cfg)
	_catalog_id = catalog.catalog_id if catalog != null else ""
	_engine.overview_changed.connect(overview_changed.emit)
	if _camera != null:
		_engine.set_camera(_camera)
	_engine.view.area = _area
	if not _profile.is_empty():
		_engine.set_profile(_profile)


## Waits (bounded) for the mesh loads this renderer started: a threaded load still running when the owner goes
## away races with whatever creates meshes next (the dummy renderer's storage is not thread-safe).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _engine != null:
		_engine.drain(1000.0)


## The explicit manual profile (RenderConfig.profile()); never chosen automatically.
## Logical catalog the scatter is drawn with (render bench attachment checks).
func catalog_id() -> String:
	return _catalog_id


func set_lod_profile(profile: Dictionary) -> void:
	_profile = profile
	_engine.set_profile(profile)


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_engine.set_camera(camera)


func set_active_area(area: ActiveEditArea) -> void:
	_area = area
	_engine.view.area = area


## Frees everything and re-buckets `doc.scatter`; cells are built by service_frame()/flush().
func rebuild_all(doc: WorldDocument) -> void:
	_engine.rebuild_all(doc)


## Scatter instances (or, with `heights_only`, the terrain) changed under `rect` (world XZ).
func mark_rect(rect: Rect2, heights_only: bool = false) -> void:
	_engine.mark_rect(rect, heights_only)


## Membership may have changed anywhere and every built cell re-drapes.
func mark_all() -> void:
	_engine.mark_all()


func has_dirty() -> bool:
	return _engine.has_dirty()


## True while meshes are still loading (cells show the coarse or placeholder representation meanwhile).
func has_pending_work() -> bool:
	return _engine.has_pending_work()


## Applies all pending work now, unbudgeted and treating the camera as settled (tests, benchmarks).
func flush() -> void:
	_engine.flush()


## Flushes and polls the cache until nothing is pending, at most `max_ms`. Headless tests and the Mac consumer.
func settle_now(max_ms: float = 2000.0) -> bool:
	return _engine.settle_now(max_ms)


## Once per frame, after the cache poll: view selection, then scheduled cell builds within `budget_ms`
## (at least one cell per call while any is queued).
func service_frame(budget_ms: float = 1.0) -> void:
	_engine.service_frame(budget_ms)


func stats() -> Dictionary:
	var instances := 0
	var multimeshes := 0
	var cells := 0
	var placeholders := 0
	for kind in 2:
		for key: Vector2i in (_engine.built[kind] as Dictionary):
			var cell := _engine.buckets.cell(kind, key)
			cells += 1
			instances += cell.drawn
			multimeshes += cell.batches.size()
			for batch: ScatterBatch in cell.batches.values():
				placeholders += 1 if batch.rep == RenderWorldResources.PLACEHOLDER else 0
	var doc := _engine.doc
	return {"instances": instances, "authored": doc.scatter.count() if doc != null else 0, "cells": cells,
			"multimeshes": multimeshes, "placeholder_batches": placeholders, "uploads": _engine.builder.uploads,
			"cell_builds": _engine.builder.builds, "pending_builds": _engine.pending_builds(),
			"scatter_epoch": _engine.builder.res.epoch, "last_rebuild_ms": _engine.last_rebuild_ms}


## Decorative diagnostics: instances bucketed in the drawn ground-cover cells, how many of them survive
## thinning, the drawn cell count and the profile's two densities.
func density_stats() -> Dictionary:
	var total := 0
	var drawn := 0
	var cells := 0
	for key: Vector2i in (_engine.built[ScatterCell.DECORATIVE] as Dictionary):
		var cell := _engine.buckets.cell(ScatterCell.DECORATIVE, key)
		total += cell.total
		drawn += cell.drawn
		cells += 1
	var p := _engine.profile
	return {"decorative_total": total, "decorative_drawn": drawn, "cells_drawn": cells,
			"density_outside": float(p.get("decorative_density_outside", 1.0)),
			"density_active": float(p.get("decorative_density_active", 1.0))}


# --- Test and overview interface -----------------------------------------------------------

## Drawn instances of the batch of `asset_id` in `cell` (a 16 m cell for decorative assets, a 32 m cell
## for the others, see cell_for()).
func rendered_count(cell: Vector2i, asset_id: String) -> int:
	var batch := _batch(cell, asset_id)
	return 0 if batch == null else batch.count


## World transform of instance `k` of that batch as last uploaded (a headless MultiMesh cannot be read back).
func instance_transform(cell: Vector2i, asset_id: String, k: int) -> Transform3D:
	var batch := _batch(cell, asset_id)
	var local := batch.local_transform(k)
	return Transform3D(local.basis, local.origin + batch.origin)


func multimesh_for(cell: Vector2i, asset_id: String) -> MultiMeshInstance3D:
	var batch := _batch(cell, asset_id)
	return null if batch == null else batch.node


## The cell of the asset's class that holds an instance at (x, z).
func cell_for(asset_id: String, x: float, z: float) -> Vector2i:
	return _engine.buckets.key_of(_kind_of(asset_id), x, z)


static func cell_of(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / CELL_M), floori(z / CELL_M))


## [{"asset_id": String, "xf": Transform3D}] of the meaningful instances whose XZ lies in `rect` (half-open),
## with terrain Y, yaw, tilt and scale; instances without a terrain sample are left out.
func overview_members(rect: Rect2) -> Array:
	var out := []
	if _engine.doc == null:
		return out
	for key in _engine.cell_range(ScatterCell.MEANINGFUL, rect):
		var cell := _engine.buckets.cell(ScatterCell.MEANINGFUL, key)
		if cell == null:
			continue
		for asset_id: String in cell.xz:
			var xz: PackedFloat32Array = cell.xz[asset_id]
			var attr: PackedFloat32Array = cell.attr[asset_id]
			for i in xz.size() / 2:
				if not rect.has_point(Vector2(xz[i * 2], xz[i * 2 + 1])):
					continue
				var xf: Variant = ScatterBuild.world_transform(_engine.doc, xz[i * 2], xz[i * 2 + 1], attr[i * 3],
						attr[i * 3 + 1], int(attr[i * 3 + 2]))
				if xf != null:
					out.append({"asset_id": asset_id, "xf": xf})
	return out


## Hides or shows the meaningful batches of the object cells whose centre lies in `rect`; they stay built.
func set_cells_covered(rect: Rect2, covered: bool) -> void:
	if _engine.doc == null:
		return
	var size: float = _engine.buckets.sizes[ScatterCell.MEANINGFUL]
	for key in _engine.cell_range(ScatterCell.MEANINGFUL, rect):
		if not rect.has_point((Vector2(key) + Vector2(0.5, 0.5)) * size):
			continue
		if covered:
			_engine.builder.covered[key] = true
		else:
			_engine.builder.covered.erase(key)
		var cell := _engine.buckets.cell(ScatterCell.MEANINGFUL, key)
		if cell != null:
			_engine.builder.apply_visibility(cell)


## Presentation only: hides vegetation scatter (descriptor.vegetation; `rule` classifies NOT_READY assets).
func set_vegetation_hidden(hidden: bool, rule: Dictionary) -> void:
	_engine.builder.veg_hidden = hidden
	_engine.builder.veg_rule = rule.duplicate(true)
	for kind in 2:
		for key: Vector2i in (_engine.built[kind] as Dictionary):
			_engine.builder.apply_visibility(_engine.buckets.cell(kind, key))


func _kind_of(asset_id: String) -> int:
	return ScatterCell.DECORATIVE if _engine.builder.is_decorative(asset_id) else ScatterCell.MEANINGFUL


func _batch(cell_key: Vector2i, asset_id: String) -> ScatterBatch:
	var cell := _engine.buckets.cell(_kind_of(asset_id), cell_key)
	return null if cell == null else cell.batches.get(asset_id)
