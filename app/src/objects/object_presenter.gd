class_name ObjectPresenter
extends Node3D
## Projects WorldDocument object records into scene nodes. Never mutates the document.
## Picking is pure math against each object's oriented catalog bounds (no physics bodies).
## `_xforms[id]` is the scene-node transform actually applied: record.node_transform(anchor_local),
## i.e. the anchor is applied after rotation+scale, so `_xforms[id] * anchor_local == record.position`.
## A grid index over world bounds limits picking and proximity queries to nearby candidates.

const GHOST_VALID := Color(0.30, 0.90, 0.40, 0.45)
const GHOST_INVALID := Color(0.95, 0.30, 0.25, 0.45)
const SELECT_COLOR := Color(1.0, 0.85, 0.1)
const ANCHOR_COLOR := Color(1.0, 0.0, 1.0)
const PICK_MAX_DISTANCE_M := 100000.0
const PICK_TIE_M := 1e-9

var _catalog: AssetCatalog
var _nodes: Dictionary = {}  # id -> Node3D
var _xforms: Dictionary = {}  # id -> Transform3D
var _inverses: Dictionary = {}  # id -> affine_inverse of _xforms[id]
var _index := RenderSpatialIndex.new(32.0)
var _revision: int = 0
var _veg_hidden: bool = false
var _veg_categories: Dictionary = {}
var _veg_excluded: Dictionary = {}
var _asset_of: Dictionary = {}  # id -> asset_id
var _selected: String = ""
var _ghost: Node3D
var _ghost_asset: String = ""
var _ghost_valid: bool = false
var _ghost_material := StandardMaterial3D.new()
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
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.albedo_color = GHOST_INVALID
	_overlay_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_material.no_depth_test = true
	_overlay_material.albedo_color = SELECT_COLOR
	_anchor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_anchor_material.no_depth_test = true
	_anchor_material.albedo_color = ANCHOR_COLOR
	_decor = PresenterDebugDecor.new(self, _anchor_material)


func setup(catalog: AssetCatalog) -> void:
	_catalog = catalog


func _process(delta: float) -> void:
	_decor.tick(delta)


func rebuild(doc: WorldDocument) -> void:
	var keep := _selected
	for id: String in _nodes.keys():
		_remove(id)
	_set_selected_raw("")
	_revision += 1
	for id in doc.sorted_object_ids():
		sync_object(doc, id)
	if keep != "" and _nodes.has(keep):
		set_selected(keep)


func sync_object(doc: WorldDocument, id: String) -> void:
	var record := doc.get_object(id)
	var asset: AssetDefinition = null
	if record != null:
		asset = _catalog.get_asset(record.asset_id)
	_revision += 1
	if record == null or asset == null:
		_remove(id)
		return
	if not _nodes.has(id) or _asset_of[id] != record.asset_id:
		if not _instantiate(id, record.asset_id):
			_remove(id)
			return
	var xf := record.node_transform(asset.anchor_local)
	var node := _nodes[id] as Node3D
	node.transform = xf
	node.visible = not _is_hidden(id)
	_xforms[id] = xf
	_inverses[id] = xf.affine_inverse()
	_index.put(id, xf * asset.bounds)
	_refresh_decor(id)


func sync_objects(doc: WorldDocument, ids: Array) -> void:
	for id: String in ids:
		sync_object(doc, id)


func node_for(id: String) -> Node3D:
	return _nodes.get(id)


func object_count() -> int:
	return _nodes.size()


## Records currently presented; becomes distinct from node_count in WP03.
func authored_object_count() -> int:
	return _nodes.size()


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
	var ids := PackedStringArray(_nodes.keys())
	ids.sort()
	return ids


## Nearest hit in front of `origin`. `distance` is in world units along the ray.
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {"id": "", "distance": INF}
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-12:
		return best
	var dir_len := dir.length()
	for id in _index.query_ray(origin, dir, PICK_MAX_DISTANCE_M):
		if _is_hidden(id):
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


func set_vegetation_hidden(hidden: bool, rule: Dictionary) -> void:
	_veg_hidden = hidden
	_veg_categories.clear()
	_veg_excluded.clear()
	for c: Variant in rule.get("categories", []):
		_veg_categories[str(c)] = true
	for a: Variant in rule.get("excluded_asset_ids", []):
		_veg_excluded[str(a)] = true
	for id: String in _nodes:
		(_nodes[id] as Node3D).visible = not _is_hidden(id)
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
	if _ghost == null or _ghost_asset != record.asset_id:
		_free_ghost()
		var node := _catalog.instantiate_preview(record.asset_id)
		if node == null:
			return
		_ghost = node
		_ghost_asset = record.asset_id
		_style_ghost(_ghost)
		add_child(_ghost)
	_ghost.transform = record.node_transform(asset.anchor_local)
	_ghost.visible = true
	_ghost_valid = valid
	_ghost_material.albedo_color = GHOST_VALID if valid else GHOST_INVALID


func hide_ghost() -> void:
	if _ghost != null:
		_ghost.visible = false


func has_ghost_visible() -> bool:
	return _ghost != null and _ghost.visible


func ghost_valid() -> bool:
	return has_ghost_visible() and _ghost_valid


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


func _instantiate(id: String, asset_id: String) -> bool:
	_free_node(id)
	var node := _catalog.instantiate_preview(asset_id)
	if node == null:
		return false
	node.name = "obj_" + id
	_disable_shadows(node)
	add_child(node)
	_nodes[id] = node
	_asset_of[id] = asset_id
	return true


func _free_node(id: String) -> void:
	var node: Node3D = _nodes.get(id)
	if node != null:
		remove_child(node)
		node.free()
	_nodes.erase(id)


func _remove(id: String) -> void:
	_free_node(id)
	_xforms.erase(id)
	_inverses.erase(id)
	_index.remove(id)
	_asset_of.erase(id)
	if _selected == id:
		_set_selected_raw("")
	_decor.object_removed(id)


func _free_ghost() -> void:
	if _ghost != null:
		remove_child(_ghost)
		_ghost.free()
	_ghost = null
	_ghost_asset = ""


func _style_ghost(node: Node) -> void:
	_disable_shadows(node)
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = _ghost_material
	for child in node.get_children():
		_style_ghost(child)


func _disable_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadows(child)


func _set_selected_raw(id: String) -> void:
	var changed := _selected != id
	_selected = id
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
