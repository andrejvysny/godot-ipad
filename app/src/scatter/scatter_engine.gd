class_name ScatterEngine
extends RefCounted
## Scheduling core of ScatterRenderer: keeps the buckets in sync with the layer, selects which cells are
## drawn and how (ground-cover radius with hysteresis, decorative density, object roles), and builds the
## queued cells nearest first within a per-frame budget. Camera-driven changes follow the stability rules
## of spec §8: size downgrades apply during navigation, upgrades after settling, pins remain stable. The active area is
## frozen for the duration of an operation.

signal overview_changed(rect: Rect2)

const DECO := ScatterCell.DECORATIVE
const MEAN := ScatterCell.MEANINGFUL
const VIEW_MOVE_M := 2.0
const NEAR_PRIORITY_M := 96.0
const RECHECK_MS := 100
const DECO_Y := Vector2(-1.0, 3.0)
const MEAN_Y := Vector2(-2.0, 30.0)
const NO_CELL := Vector3i(0, 0, -1)

var doc: WorldDocument
var buckets: ScatterBuckets
var builder: ScatterCellBuilder
var view := ScatterView.new()
var profile: Dictionary = {}
var built := [{}, {}]  # kind -> {Vector2i: true}
var last_rebuild_ms := 0.0

var _cache: RenderAssetCache
var _own_cache := false
var _hyst := 0.2
var _queued := {}  # Vector3i(cx, cz, kind) -> true
var _order: Array[Vector3i] = []  # queued keys, nearest last
var _order_dirty := false
var _order_focus := Vector3.INF
var _order_sort_ms := 0
var _wanted := {}  # Vector2i -> true: decorative cells inside the ground-cover band
var _view_pos := Vector3.INF
var _view_force := true
var _roles_due := false
var _roles_retry := false
var _role_scan: Array[Vector2i] = []
var _active_due := false
var _reclassify_due := false
var _force_settled := false
var view_suppressed := false
var _building := NO_CELL


func _init(parent: Node3D, catalog: AssetCatalog, registry: RenderAssetRegistry, cache: RenderAssetCache,
		own_cache: bool, config: RenderConfig) -> void:
	_cache = cache
	_own_cache = own_cache
	var cells := config.section("cells")
	var stability := config.section("stability")
	_hyst = float(stability.lod_hysteresis_fraction)
	view.settle_ms = int(stability.settle_ms)
	profile = config.profile(config.startup_profile())
	view.active_radius = float(profile.active_area_radius_m)
	var sizes := [float(cells.ground_cover_m), float(cells.objects_m)]
	builder = ScatterCellBuilder.new(parent, catalog, registry, ScatterResources.new(registry, cache), sizes)
	buckets = ScatterBuckets.new(sizes[0], sizes[1], builder.is_decorative)


func set_profile(p: Dictionary) -> void:
	builder.jobs.clear()
	profile = p.duplicate()
	view.active_radius = float(profile.get("active_area_radius_m", 20.0))
	_view_force = true
	_roles_due = true
	_active_due = true
	_reclassify_due = true


func set_camera(camera: Camera3D) -> void:
	view.camera = camera
	_view_force = true
	_roles_due = true
	_active_due = true


## Frees everything and re-buckets `new_doc.scatter`; cells are built by service_frame()/flush().
func rebuild_all(new_doc: WorldDocument) -> void:
	var t0 := Time.get_ticks_usec()
	for kind in 2:
		for cell: ScatterCell in (buckets.cells[kind] as Dictionary).values():
			builder.free_batches(cell)
	_building = NO_CELL
	_queued.clear()
	_order.clear()
	_role_scan.clear()
	built = [{}, {}]
	_wanted.clear()
	doc = new_doc
	builder.doc = new_doc
	builder.res.next_epoch()
	builder.reset()
	builder.seed_value = ScatterDensity.world_seed(new_doc.world_id)
	buckets.reset()
	view.track(Time.get_ticks_msec())
	_apply_changed(buckets.sync(new_doc.scatter, Rect2(), true))
	_view_force = true
	_roles_due = true
	_active_due = true
	_reclassify_due = true
	last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	overview_changed.emit(new_doc.layout.extent_rect())


## Scatter instances (or, with `heights_only`, the terrain) changed under `rect` (world XZ).
func mark_rect(rect: Rect2, heights_only: bool) -> void:
	if doc == null:
		return
	view.track(Time.get_ticks_msec())
	if heights_only:
		for kind in 2:
			for key in cell_range(kind, rect):
				var cell := buckets.cell(kind, key)
				if cell != null and (cell.built or builder.jobs.has(Vector3i(key.x, key.y, kind))):
					builder.invalidate(cell)
					_enqueue(kind, key)
		if _has_meaningful(rect):
			overview_changed.emit(rect)
		return
	var changed := buckets.sync(doc.scatter, rect, rect.encloses(doc.layout.extent_rect()))
	_apply_changed(changed)
	var moved := _meaningful_rect(changed)
	if moved.has_area():
		overview_changed.emit(moved)


func mark_all() -> void:
	if doc == null:
		return
	builder.jobs.clear()
	view.track(Time.get_ticks_msec())
	_apply_changed(buckets.sync(doc.scatter, Rect2(), true))
	for kind in 2:
		for key: Vector2i in (built[kind] as Dictionary):
			_enqueue(kind, key)
	overview_changed.emit(doc.layout.extent_rect())


func has_dirty() -> bool:
	return _building != NO_CELL or _roles_due or _roles_retry or not _queued.is_empty() or not _role_scan.is_empty() or (_view_force and doc != null)


func has_pending_work() -> bool:
	return has_dirty() or not builder.res.awaiting.is_empty()


func flush() -> void:
	_force_settled = true
	service_frame(INF)
	_force_settled = false


func settle_now(max_ms: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) < max_ms:
		_cache.poll(4.0)
		flush()
		if not has_pending_work():
			return true
		OS.delay_msec(1)
	return false


## The renderer replaces this engine: frees every batch, waits (bounded) for its loads, cancels the rest.
func teardown() -> void:
	for kind in 2:
		for cell: ScatterCell in (buckets.cells[kind] as Dictionary).values():
			builder.free_batches(cell)
	drain(1000.0)
	builder.res.next_epoch()


## Polls the cache until this renderer has no outstanding load, at most `max_ms`.
func drain(max_ms: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not builder.res.awaiting.is_empty() and float(Time.get_ticks_msec() - t0) < max_ms:
		_cache.poll(2.0)
		builder.res.poll_ready()
		OS.delay_msec(1)


func service_frame(budget_ms: float) -> void:
	if doc == null or view_suppressed:
		return
	var t0 := Time.get_ticks_usec()
	if _own_cache:
		_cache.poll(budget_ms)
	var now := Time.get_ticks_msec()
	if view.track(now):
		_view_force = true
		_roles_due = true
		_active_due = true
	builder.snapshot = view.snapshot
	builder.profile = profile
	builder.allow_upgrades = _force_settled or view.is_settled(now)
	_sync_freeze()
	_poll_ready(now)
	_refresh_ground_cover()
	_refresh_active(now)
	_refresh_roles(now, t0, budget_ms)
	if _run_queue(t0, budget_ms) > 0:
		last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func pending_builds() -> int:
	return _queued.size() + (1 if _building != NO_CELL else 0)


## Cells of `kind` overlapping `rect`, clamped to the world extent.
func cell_range(kind: int, rect: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var extent := doc.layout.extent_rect()
	var lo := buckets.key_of(kind, clampf(rect.position.x, extent.position.x, extent.end.x),
			clampf(rect.position.y, extent.position.y, extent.end.y))
	var hi := buckets.key_of(kind, clampf(rect.end.x, extent.position.x, extent.end.x),
			clampf(rect.end.y, extent.position.y, extent.end.y))
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			out.append(Vector2i(cx, cz))
	return out


func _eff(cell: ScatterCell) -> float:
	var size: float = buckets.sizes[cell.kind]
	if is_nan(cell.y_ref):
		var h := doc.sample_height((cell.key.x + 0.5) * size, (cell.key.y + 0.5) * size)
		cell.y_ref = 0.0 if is_nan(h) else h
	return view.effective(cell.key, size, cell.y_ref, DECO_Y if cell.kind == DECO else MEAN_Y)


## Active-area cells use the active density; others the outside density halved per distance band (PREF-08).
## Both factors are monotone per cell, so every density stays a nested superset of the lower ones.
func _density_for(cell: ScatterCell) -> float:
	if view.cell_is_active(cell.key, buckets.sizes[DECO]):
		return float(profile.get("decorative_density_active", 1.0))
	return float(profile.get("decorative_density_outside", 1.0)) * LodPolicy.ground_cover_factor(maxi(cell.band, 0))


## The running operation's pins freeze the active area (and keep pinned cells from leaving) until released.
func _sync_freeze() -> void:
	var pinned := view.area != null and view.area.has_pins()
	if pinned and not view.freezing:
		view.frozen = view.area.pinned_cells(buckets.sizes[DECO])
		view.freezing = true
		_view_force = true
		_reclassify(true)
	elif not pinned and view.freezing:
		_roles_due = true
		view.frozen = {}
		view.freezing = false
		_view_force = true
		_active_due = true
		_reclassify(true)


## Adds or removes decorative cells as they cross the ground-cover radius band (hysteresis in LodPolicy).
func _refresh_ground_cover() -> void:
	if not view.has_camera:
		if _view_force:
			_view_force = false
			for cell: ScatterCell in (buckets.cells[DECO] as Dictionary).values():
				_eval_deco(cell)
		return
	if not _view_force and view.pos.distance_to(_view_pos) < VIEW_MOVE_M:
		return
	_view_pos = view.pos
	_view_force = false
	for key: Vector2i in _wanted.keys():
		_eval_deco(buckets.cell(DECO, key))
	var scale_f := maxf(LodPolicy.effective_distance(1.0, view.fov, view.viewport_h), 0.01)
	var outer := float(profile.get("ground_cover_radius_m", 25.0)) * pow(sqrt(2.0), LodPolicy.GROUND_COVER_BANDS)
	_eval_new_cells(view.pos.x, view.pos.z, minf(outer * 1.1 / scale_f, 1000.0))
	if view.active_valid:
		_eval_new_cells(view.active_center.x, view.active_center.y, view.active_radius)


func _eval_new_cells(cx_m: float, cz_m: float, reach: float) -> void:
	var lo := buckets.key_of(DECO, cx_m - reach, cz_m - reach)
	var hi := buckets.key_of(DECO, cx_m + reach, cz_m + reach)
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var cell := buckets.cell(DECO, Vector2i(cx, cz))
			if cell != null and not cell.wanted:
				_eval_deco(cell)


## Distance band with hysteresis; the active area is drawn densely while it is within twice the outer band
## (beyond that, e.g. at whole-world overview distance, ground cover is sub-pixel anyway).
func _eval_deco(cell: ScatterCell) -> void:
	var band := 0
	if view.has_camera:
		var eff := _eff(cell)
		band = LodPolicy.ground_cover_band(eff, profile, cell.band if cell.wanted else -1, _hyst)
		var radius := float(profile.get("ground_cover_radius_m", 25.0))
		if eff < radius * pow(sqrt(2.0), LodPolicy.GROUND_COVER_BANDS) * 2.0 \
				and view.cell_is_active(cell.key, buckets.sizes[DECO]):
			band = 0
	var want := band >= 0
	if want and cell.wanted and band != cell.band and not view.frozen.has(cell.key):
		cell.band = band
		if cell.built and not is_equal_approx(cell.density, _density_for(cell)):
			_enqueue(DECO, cell.key)
		return
	if want == cell.wanted:
		return
	cell.band = band
	if want:
		cell.wanted = true
		_wanted[cell.key] = true
		_enqueue(DECO, cell.key)
	elif not view.frozen.has(cell.key):
		cell.wanted = false
		_wanted.erase(cell.key)
		_free_cell(cell)
		if cell.count() == 0:
			buckets.erase(DECO, cell.key)


## Moves the pivot-circle active area once the camera has settled, and re-evaluates densities.
func _refresh_active(now: int) -> void:
	if view.freezing:
		return
	if view.has_camera and _active_due and (_force_settled or view.is_settled(now)):
		_active_due = false
		var pivot := view.ground_pivot(doc)
		var center := Vector2(pivot.x, pivot.z)
		if not view.active_valid or center.distance_to(view.active_center) >= view.active_radius * 0.25:
			view.active_center = center
			view.active_valid = true
			_reclassify_due = true
			_view_force = true  # cells newly inside the active area are drawn even beyond the distance bands
	if _reclassify_due:
		_reclassify_due = false
		_reclassify(false)


func _reclassify(allow_pinned: bool) -> void:
	for key: Vector2i in (built[DECO] as Dictionary):
		var cell := buckets.cell(DECO, key)
		if not is_equal_approx(cell.density, _density_for(cell)) and (allow_pinned or not view.frozen.has(key)):
			_enqueue(DECO, key)


## Projection changes can reduce submissions immediately; upgrades wait for settle.
func _refresh_roles(now: int, t0: int, budget_ms: float) -> void:
	if _roles_retry and (_force_settled or view.is_settled(now)):
		_roles_due = true
		_roles_retry = false
	if _role_scan.is_empty() and _roles_due:
		_roles_due = false
		_roles_retry = not (_force_settled or view.is_settled(now))
		for kind in 2:
			for key: Vector2i in (built[kind] as Dictionary):
				_role_scan.append(Vector2i(key.x, key.y))
		# Both kinds may share a key; enqueueing is idempotent.
	while not _role_scan.is_empty():
		var key: Vector2i = _role_scan.pop_back()
		for kind in 2:
			var cell := buckets.cell(kind, key)
			if cell != null and cell.built and not (view.is_pinned(key) if kind == MEAN else view.frozen.has(key)):
				_enqueue(kind, key)
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return


func _poll_ready(_now: int, recheck: bool = false) -> void:
	var ready := builder.res.poll_ready()
	if ready.is_empty() and not recheck:
		return
	for kind in 2:
		for key: Vector2i in (built[kind] as Dictionary):
			var cell := buckets.cell(kind, key)
			for batch: ScatterBatch in cell.batches.values():
				if not recheck and not ready.has(batch.asset_id):
					continue
				if builder.res.rep_for(batch.asset_id, batch.wanted_role, _priority(cell)) != batch.rep:
					if not view.is_pinned(key) and builder.allow_upgrades:
						_enqueue(kind, key)
					else:
						_roles_due = true


func _has_meaningful(rect: Rect2) -> bool:
	for key in cell_range(MEAN, rect):
		var cell := buckets.cell(MEAN, key)
		if cell != null and cell.count() > 0:
			return true
	return false


func _meaningful_rect(changed: Dictionary) -> Rect2:
	var size: float = buckets.sizes[MEAN]
	var out := Rect2()
	for key3: Vector3i in changed:
		if key3.z == MEAN:
			var r := Rect2(Vector2(key3.x, key3.y) * size, Vector2(size, size))
			out = r if not out.has_area() else out.merge(r)
	return out


func _apply_changed(changed: Dictionary) -> void:
	for key3: Vector3i in changed:
		var cell := buckets.cell(key3.z, Vector2i(key3.x, key3.y))
		if cell == null:
			continue
		builder.invalidate(cell)
		cell.y_ref = NAN
		if key3.z == DECO and not cell.wanted:
			_eval_deco(cell)
		else:
			_enqueue(key3.z, cell.key)


func _enqueue(kind: int, key: Vector2i) -> void:
	var key3 := Vector3i(key.x, key.y, kind)
	if _queued.has(key3):
		return
	_queued[key3] = true
	_order.append(key3)
	_order_dirty = true


func _run_queue(t0: int, budget_ms: float) -> int:
	var n := 0
	while not _queued.is_empty() or _building != NO_CELL:
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			break
		if _building == NO_CELL:
			_building = _pop()
		if _build_cell(_building):
			_building = NO_CELL
		n += 1
	return n


func _pop() -> Vector3i:
	if _order.is_empty() or ((_order_dirty or view.focus.distance_to(_order_focus) > buckets.sizes[MEAN]) \
			and Time.get_ticks_msec() - _order_sort_ms >= RECHECK_MS):
		_sort_order()
	while not _order.is_empty():
		var key: Vector3i = _order.pop_back()
		if _queued.erase(key):
			return key
	return NO_CELL


func _sort_order() -> void:
	_order_sort_ms = Time.get_ticks_msec()
	_order_dirty = false
	_order_focus = view.focus
	_order.assign(_queued.keys())
	var focus := view.focus
	var sizes: Array = buckets.sizes
	_order.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var sa: float = sizes[a.z]
		var sb: float = sizes[b.z]
		return Vector2((a.x + 0.5) * sa - focus.x, (a.y + 0.5) * sa - focus.z).length_squared() \
				> Vector2((b.x + 0.5) * sb - focus.x, (b.y + 0.5) * sb - focus.z).length_squared())


func _priority(cell: ScatterCell) -> int:
	var size: float = buckets.sizes[cell.kind]
	var center := Vector2((cell.key.x + 0.5) * size - view.focus.x, (cell.key.y + 0.5) * size - view.focus.z)
	return 1 if center.length() <= NEAR_PRIORITY_M else 2


func _build_cell(key3: Vector3i) -> bool:
	if key3.z < 0:
		return true
	var kind := key3.z
	var cell := buckets.cell(kind, Vector2i(key3.x, key3.y))
	if cell == null:
		return true
	if cell.count() == 0:
		_wanted.erase(cell.key)
		_free_cell(cell)
		buckets.erase(kind, cell.key)
		return true
	if kind == DECO and not cell.wanted:
		return true
	if kind == MEAN and (cell.role == "" or builder.allow_upgrades):
		cell.role = LodPolicy.individual_role(_eff(cell) if view.has_camera else 0.0, profile, cell.role, _hyst)
	builder.pinned = view.is_pinned(cell.key) if kind == MEAN else view.frozen.has(cell.key)
	if not builder.build_cell(cell, _density_for(cell) if kind == DECO else 1.0, _priority(cell)):
		return false
	(built[kind] as Dictionary)[cell.key] = true
	if builder.refresh_needed:
		_enqueue(kind, cell.key)
	return true


func _free_cell(cell: ScatterCell) -> void:
	builder.free_batches(cell)
	(built[cell.kind] as Dictionary).erase(cell.key)
