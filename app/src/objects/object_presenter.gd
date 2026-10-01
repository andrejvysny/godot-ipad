class_name ObjectPresenter
extends Node3D
## Projects WorldDocument object records into render state. Never mutates the document. Logical state lives
## here; visuals are drawn by ObjectRenderWorld (spatial MultiMesh batches, one promoted node for the selection).
## Picking is pure math against each object's oriented catalog bounds (no physics bodies).
## `_xforms[id]` is the scene-node transform actually applied: record.node_transform(anchor_local),
## i.e. the anchor is applied after rotation+scale, so `_xforms[id] * anchor_local == record.position`.
## A grid index over world bounds limits picking and proximity queries to nearby candidates.

signal placeholders_reported(text: String)

const ROLE_CELL_M := 32.0
const REGISTRY_INDEX := "res://assets/render_assets/index.json"
const DEFAULT_BUDGET_MS := 1.0
const SELECT_COLOR := Color(1.0, 0.85, 0.1)
const ANCHOR_COLOR := Color(1.0, 0.0, 1.0)
const PICK_MAX_DISTANCE_M := 100000.0
const PICK_TIE_M := 1e-9

var _catalog: AssetCatalog
var _registry: RenderAssetRegistry
var _cache: RenderAssetCache
var _own_cache: bool = false  # the presenter polls a cache it created itself
var _world: ObjectRenderWorld
var _profile: Dictionary = {}
var _pin_check := Callable()
var _xforms: Dictionary = {}  # id -> Transform3D
var _inverses: Dictionary = {}  # id -> affine_inverse of _xforms[id]
var _index := RenderSpatialIndex.new(32.0)
var _revision: int = 0
var _veg_hidden: bool = false
var _veg_categories: Dictionary = {}
var _veg_excluded: Dictionary = {}
var _asset_of: Dictionary = {}  # id -> asset_id
var _selected: String = ""
var _ghost: PresenterGhost
var _overlay: Node3D
var _overlay_holder: Node3D
var _overlay_box: MeshInstance3D
var _overlay_sphere: MeshInstance3D
var _wire_meshes: Dictionary = {}  # asset_id -> ImmediateMesh
var _overlay_material := StandardMaterial3D.new()
var _show_anchors: bool = false
var _show_ids: bool = false
var _anchor_material := StandardMaterial3D.new()
var _decor: PresenterDebugDecor


func _init() -> void:
	_overlay_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_material.no_depth_test = true
	_overlay_material.albedo_color = SELECT_COLOR
	_anchor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_anchor_material.no_depth_test = true
	_anchor_material.albedo_color = ANCHOR_COLOR
	_decor = PresenterDebugDecor.new(self, _anchor_material)


## Without a registry/cache (tests, tools) the presenter loads the committed registry and owns a default cache.
func setup(catalog: AssetCatalog, registry: RenderAssetRegistry = null, cache: RenderAssetCache = null) -> void:
	_catalog = catalog
	_registry = registry if registry != null else RenderAssetRegistry.load_from(REGISTRY_INDEX, catalog)
	_own_cache = cache == null
	_cache = cache if cache != null else RenderAssetCache.new(RenderConfig.load_from().section("budgets"))
	_world = ObjectRenderWorld.new()
	_world.name = "render_world"
	_world.setup(_registry, _cache, ROLE_CELL_M, _is_hidden, catalog)
	if not _profile.is_empty():
		_world.set_lod_profile(_profile)
	_world.set_pin_check(_pin_check)
	_world.placeholders_reported.connect(placeholders_reported.emit)
	add_child(_world)
	_ghost = PresenterGhost.new(_registry, _cache)


func _process(delta: float) -> void:
	_decor.tick(delta)


func rebuild(doc: WorldDocument) -> void:
	var keep := _selected
	_world.clear()
	for id: String in _xforms.keys():
		_remove(id, false)
	_set_selected_raw("")
	_revision += 1
	for id in doc.sorted_object_ids():
		sync_object(doc, id)
	if keep != "" and _xforms.has(keep):
		set_selected(keep)


## True while scheduled rendering still has work queued (batch builds, mesh loads, uploads).
func has_pending_work() -> bool:
	return _world.has_pending_work()


## Once per frame, after the tools: polls the cache when this presenter owns it, then applies render work.
func service_frame(budget_ms: float = DEFAULT_BUDGET_MS) -> void:
	if _own_cache:
		_cache.poll(budget_ms)
	_world.service_frame(budget_ms)


## Services until no work is pending, at most `max_ms`. Headless tests and the Mac consumer only.
func settle_now(max_ms: float = 2000.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		service_frame(4.0)
		if not has_pending_work():
			return true
		OS.delay_msec(1)
	return not has_pending_work()


## LOD profile of the active render profile (see ObjectRenderWorld.set_lod_profile).
func set_lod_profile(profile: Dictionary) -> void:
	_profile = profile
	if _world != null:
		_world.set_lod_profile(profile)


## Compatibility: changes only the minimum unselected role of the current profile.
func set_default_role(role: String) -> void:
	set_lod_profile(_profile.merged({"near_min_role": role}, true))


func set_pin_check(check: Callable) -> void:
	_pin_check = check
	_world.set_pin_check(check)


func is_asset_ready(asset_id: String) -> bool:
	return _registry.is_ready(asset_id)


## ObjectRenderWorld counters (cells, batches, instances, estimated_triangles, uploads, world_epoch, ...).
func render_stats() -> Dictionary:
	return _world.stats()


func render_world() -> ObjectRenderWorld:
	return _world


func ghost_material() -> Material:
	return _ghost.material


func sync_object(doc: WorldDocument, id: String) -> void:
	var record := doc.get_object(id)
	var asset: AssetDefinition = null
	if record != null:
		asset = _catalog.get_asset(record.asset_id)
	_revision += 1
	if record == null or asset == null:
		_remove(id)
		return
	var xf := record.node_transform(asset.anchor_local)
	_asset_of[id] = record.asset_id
	_xforms[id] = xf
	_inverses[id] = xf.affine_inverse()
	_index.put(id, xf * asset.bounds)
	_world.upsert(id, record.asset_id, xf)
	_refresh_decor(id)


func sync_objects(doc: WorldDocument, ids: Array) -> void:
	for id: String in ids:
		sync_object(doc, id)


## Debug query: the promoted node of the selected record, else null. Unselected records have no node.
func node_for(id: String) -> MeshInstance3D:
	return _world.promoted_node() if id != "" and id == _selected else null


## Records presented logically (§7.1).
func authored_object_count() -> int:
	return _xforms.size()


## Records currently drawn by a batch, placeholder or the promoted node.
func represented_object_count() -> int:
	return int(_world.stats().instances)


## Batch instances plus the promoted node.
func individual_instance_count() -> int:
	return int(_world.stats().instances)


## Renderer scene nodes of the presenter: batch MultiMeshInstance3Ds, pooled promoted nodes and the ghost.
func node_count() -> int:
	return int(_world.stats().nodes) + (1 if _ghost.node != null else 0)


func registry() -> RenderAssetRegistry:
	return _registry


## Asset id of a presented record ("" when absent).
func asset_of(id: String) -> String:
	return str(_asset_of.get(id, ""))


func has_object(id: String) -> bool:
	return _xforms.has(id)


func applied_transform(id: String) -> Transform3D:
	return _xforms.get(id, Transform3D.IDENTITY)


func anchor_position(id: String) -> Vector3:
	if not _xforms.has(id):
		return Vector3.ZERO
	return (_xforms[id] as Transform3D) * _catalog.get_asset(_asset_of[id]).anchor_local


func presentation_revision() -> int:
	return _revision


func object_ids() -> PackedStringArray:
	var ids := PackedStringArray(_xforms.keys())
	ids.sort()
	return ids


## Nearest hit in front of `origin`. `distance` is in world units along the ray. Objects in cells an overview
## group covers are not individually visible and never hit (PICK-03).
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {"id": "", "distance": INF}
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-12:
		return best
	var dir_len := dir.length()
	for id in _index.query_ray(origin, dir, PICK_MAX_DISTANCE_M):
		if _is_hidden(id) or _world.is_object_covered(id):
			continue
		var bounds := _catalog.get_asset(_asset_of[id]).bounds
		var inv: Transform3D = _inverses[id]
		var lo := inv * origin
		# Not renormalized: the ray parameter t is identical in local and world space.
		var ld := inv.basis * dir
		var t := 0.0
		if not bounds.has_point(lo):
			var hit: Variant = bounds.intersects_ray(lo, ld)
			if hit == null:
				continue
			t = ((hit as Vector3) - lo).dot(ld) / ld.length_squared()
			if t < 0.0:
				continue
		var dist := t * dir_len
		var best_dist: float = best["distance"]
		# Candidates arrive sorted by id, so an equal hit never displaces a smaller id.
		if dist < best_dist - PICK_TIE_M or (best["id"] == "" and dist < best_dist):
			best = {"id": id, "distance": dist}
	return best


## Objects whose bounds centre is within `radius` of `point`, nearest first. Hidden vegetation is skipped.
func objects_near(point: Vector3, radius: float, max_count: int) -> PackedStringArray:
	if not _veg_hidden:
		return _index.query_near(point, radius, max_count)
	var out := PackedStringArray()
	for id in _index.query_near(point, radius, 1 << 30):
		if out.size() >= max_count:
			break
		if not _is_hidden(id):
			out.append(id)
	return out


## Objects whose world bounds intersect the XZ circle (any height), nearest bounds centre first; ties by id.
## Hidden vegetation is skipped.
func objects_in_circle(center: Vector2, radius: float) -> PackedStringArray:
	var out := PackedStringArray()
	if not center.is_finite() or not is_finite(radius) or radius < 0.0:
		return out
	var tall := 1.0e6
	var box := AABB(Vector3(center.x - radius, -tall, center.y - radius), Vector3(radius * 2.0, tall * 2.0, radius * 2.0))
	var items: Array = []
	for id in _index.query_aabb(box):
		var b := _index.bounds_of(id)
		var nearest := Vector2(clampf(center.x, b.position.x, b.end.x), clampf(center.y, b.position.z, b.end.z))
		if nearest.distance_squared_to(center) > radius * radius or _is_hidden(id):
			continue
		var c := b.get_center()
		items.append([Vector2(c.x, c.z).distance_squared_to(center), id])
	items.sort_custom(RenderSpatialIndex._near_less)
	for item: Array in items:
		out.append(item[1])
	return out


func set_vegetation_hidden(hidden: bool, rule: Dictionary) -> void:
	_veg_hidden = hidden
	_veg_categories.clear()
	_veg_excluded.clear()
	for c: Variant in rule.get("categories", []):
		_veg_categories[str(c)] = true
	for a: Variant in rule.get("excluded_asset_ids", []):
		_veg_excluded[str(a)] = true
	_world.set_vegetation_visibility_changed()
	_revision += 1
	_decor.refresh()


func vegetation_hidden() -> bool:
	return _veg_hidden


func _is_hidden(id: String) -> bool:
	if not _veg_hidden:
		return false
	var asset := _catalog.get_asset(_asset_of.get(id, ""))
	return asset != null and _veg_categories.has(asset.category) and not _veg_excluded.has(asset.asset_id)


func world_bounds(id: String) -> AABB:
	return _index.bounds_of(id)


func show_ghost(record: ObjectRecord, valid: bool) -> void:
	var asset := _catalog.get_asset(record.asset_id)
	if asset == null:
		hide_ghost()
		return
	_ghost.show(self, asset, record.node_transform(asset.anchor_local), valid)


func hide_ghost() -> void:
	_ghost.hide()


func has_ghost_visible() -> bool:
	return _ghost.is_visible()


func ghost_valid() -> bool:
	return has_ghost_visible() and _ghost.valid


func ghost() -> PresenterGhost:
	return _ghost


func set_selected(id: String) -> void:
	_set_selected_raw(id if _xforms.has(id) else "")


func selected_id() -> String:
	return _selected


func set_show_anchors(on: bool) -> void:
	_show_anchors = on
	_decor.configure(_show_anchors, _show_ids)


func set_show_ids(on: bool) -> void:
	_show_ids = on
	_decor.configure(_show_anchors, _show_ids)


func set_debug_limit(n: int) -> void:
	_decor.set_limit(n)


func set_camera(camera: Camera3D) -> void:
	_decor.set_camera(camera)
	_world.set_camera(camera)


func debug_marker_count() -> int:
	return _decor.marker_count()


func debug_label_count() -> int:
	return _decor.label_count()


func debug_label_ids() -> PackedStringArray:
	return _decor.label_ids()


func debug_marker_for(id: String) -> Node3D:
	return _decor.marker_for(id)


func debug_label_for(id: String) -> Label3D:
	return _decor.label_for(id)


func selection_overlay_visible() -> bool:
	return _overlay != null and _overlay.visible


func selection_overlay_nodes() -> Array[Node3D]:
	var nodes: Array[Node3D] = []
	if _overlay != null:
		nodes.append_array([_overlay_holder, _overlay_box, _overlay_sphere])
	return nodes


func _remove(id: String, visual := true) -> void:
	if visual:
		_world.remove(id)
	_xforms.erase(id)
	_inverses.erase(id)
	_index.remove(id)
	_asset_of.erase(id)
	if _selected == id:
		_set_selected_raw("")
	_decor.object_removed(id)


func _set_selected_raw(id: String) -> void:
	var changed := _selected != id
	_selected = id
	_world.set_selected(id)
	_update_overlay()
	if changed:
		_decor.refresh()


## The overlay tree and wire meshes are built once and only re-posed afterwards (EDIT-02).
func _update_overlay() -> void:
	if _selected == "":
		if _overlay != null:
			_overlay.visible = false
		return
	if _overlay == null:
		_build_overlay()
	var asset := _catalog.get_asset(_asset_of[_selected])
	var xf: Transform3D = _xforms[_selected]
	if not _wire_meshes.has(asset.asset_id):
		_wire_meshes[asset.asset_id] = _wire_box(asset.bounds.grow(0.1))
	if _overlay_box.mesh != _wire_meshes[asset.asset_id]:
		_overlay_box.mesh = _wire_meshes[asset.asset_id]
	_overlay_holder.transform = xf
	# Sphere lives outside the scaled holder so its radius stays in metres.
	_overlay_sphere.position = xf * asset.anchor_local
	_overlay.visible = true


func _build_overlay() -> void:
	_overlay = Node3D.new()
	_overlay.name = "selection_overlay"
	_overlay_holder = Node3D.new()
	_overlay.add_child(_overlay_holder)
	_overlay_box = MeshInstance3D.new()
	_overlay_box.material_override = _overlay_material
	_overlay_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay_holder.add_child(_overlay_box)
	_overlay_sphere = _sphere_marker(0.25, _overlay_material)
	_overlay.add_child(_overlay_sphere)
	add_child(_overlay)


func _wire_box(box: AABB) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	# get_endpoint bits: 1 = z, 2 = y, 4 = x.
	for i in 8:
		for bit in [1, 2, 4]:
			if i & bit == 0:
				mesh.surface_add_vertex(box.get_endpoint(i))
				mesh.surface_add_vertex(box.get_endpoint(i | bit))
	mesh.surface_end()
	return mesh


func _sphere_marker(radius: float, material: Material) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _refresh_decor(id: String) -> void:
	if _selected == id:
		_update_overlay()
	_decor.object_changed(id)
