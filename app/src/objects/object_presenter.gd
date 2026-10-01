class_name ObjectPresenter
extends Node3D
## Projects WorldDocument object records into scene nodes. Never mutates the document.
## Picking is pure math against each object's oriented catalog bounds (no physics bodies).
## `_xforms[id]` is the scene-node transform actually applied: record.node_transform(anchor_local),
## i.e. the anchor is applied after rotation+scale, so `_xforms[id] * anchor_local == record.position`.

const GHOST_VALID := Color(0.30, 0.90, 0.40, 0.45)
const GHOST_INVALID := Color(0.95, 0.30, 0.25, 0.45)
const SELECT_COLOR := Color(1.0, 0.85, 0.1)
const ANCHOR_COLOR := Color(1.0, 0.0, 1.0)

var _catalog: AssetCatalog
var _nodes: Dictionary = {}  # id -> Node3D
var _xforms: Dictionary = {}  # id -> Transform3D
var _asset_of: Dictionary = {}  # id -> asset_id
var _selected: String = ""
var _ghost: Node3D
var _ghost_asset: String = ""
var _ghost_valid: bool = false
var _ghost_material := StandardMaterial3D.new()
var _overlay: Node3D
var _overlay_material := StandardMaterial3D.new()
var _show_anchors: bool = false
var _show_ids: bool = false
var _markers: Dictionary = {}  # id -> MeshInstance3D
var _labels: Dictionary = {}  # id -> Label3D
var _anchor_material := StandardMaterial3D.new()


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


func setup(catalog: AssetCatalog) -> void:
	_catalog = catalog


func rebuild(doc: WorldDocument) -> void:
	var keep := _selected
	for id: String in _nodes.keys():
		_remove(id)
	_set_selected_raw("")
	for id in doc.sorted_object_ids():
		sync_object(doc, id)
	if keep != "" and _nodes.has(keep):
		set_selected(keep)


func sync_object(doc: WorldDocument, id: String) -> void:
	var record := doc.get_object(id)
	var asset: AssetDefinition = null
	if record != null:
		asset = _catalog.get_asset(record.asset_id)
	if record == null or asset == null:
		_remove(id)
		return
	if not _nodes.has(id) or _asset_of[id] != record.asset_id:
		if not _instantiate(id, record.asset_id):
			_remove(id)
			return
	var xf := record.node_transform(asset.anchor_local)
	(_nodes[id] as Node3D).transform = xf
	_xforms[id] = xf
	_refresh_decor(id)


func sync_objects(doc: WorldDocument, ids: Array) -> void:
	for id: String in ids:
		sync_object(doc, id)


func node_for(id: String) -> Node3D:
	return _nodes.get(id)


func object_count() -> int:
	return _nodes.size()


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
	for id: String in _xforms:
		var asset := _catalog.get_asset(_asset_of[id])
		var inv := (_xforms[id] as Transform3D).affine_inverse()
		var lo := inv * origin
		# Not renormalized: the ray parameter t is identical in local and world space.
		var ld := inv.basis * dir
		var t := 0.0
		if not asset.bounds.has_point(lo):
			var hit: Variant = asset.bounds.intersects_ray(lo, ld)
			if hit == null:
				continue
			t = ((hit as Vector3) - lo).dot(ld) / ld.length_squared()
			if t < 0.0:
				continue
		var dist := t * dir_len
		if dist < (best["distance"] as float):
			best = {"id": id, "distance": dist}
	return best


func world_bounds(id: String) -> AABB:
	if not _xforms.has(id):
		return AABB()
	return (_xforms[id] as Transform3D) * _catalog.get_asset(_asset_of[id]).bounds


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
	for id: String in _xforms:
		_refresh_decor(id)


func set_show_ids(on: bool) -> void:
	_show_ids = on
	for id: String in _xforms:
		_refresh_decor(id)


func _instantiate(id: String, asset_id: String) -> bool:
	_free_node(id)
	var node := _catalog.instantiate_preview(asset_id)
	if node == null:
		return false
	node.name = "obj_" + id
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
	_asset_of.erase(id)
	_free_decor(_markers, id)
	_free_decor(_labels, id)
	if _selected == id:
		_set_selected_raw("")


func _free_decor(store: Dictionary, id: String) -> void:
	var node: Node3D = store.get(id)
	if node != null:
		remove_child(node)
		node.free()
	store.erase(id)


func _free_ghost() -> void:
	if _ghost != null:
		remove_child(_ghost)
		_ghost.free()
	_ghost = null
	_ghost_asset = ""


func _style_ghost(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.material_override = _ghost_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_style_ghost(child)


func _set_selected_raw(id: String) -> void:
	_selected = id
	if _overlay != null:
		remove_child(_overlay)
		_overlay.free()
		_overlay = null
	if id != "":
		_build_overlay(id)


func _build_overlay(id: String) -> void:
	var asset := _catalog.get_asset(_asset_of[id])
	var xf: Transform3D = _xforms[id]
	_overlay = Node3D.new()
	_overlay.name = "selection_overlay"
	var holder := Node3D.new()
	holder.transform = xf
	_overlay.add_child(holder)
	var box := MeshInstance3D.new()
	box.mesh = _wire_box(asset.bounds.grow(0.1))
	box.material_override = _overlay_material
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(box)
	# Sphere lives outside the scaled holder so its radius stays in metres.
	var sphere := _sphere_marker(0.25, _overlay_material)
	sphere.position = xf * asset.anchor_local
	_overlay.add_child(sphere)
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
		_set_selected_raw(id)
	var asset := _catalog.get_asset(_asset_of[id])
	if _show_anchors:
		if not _markers.has(id):
			var marker := _sphere_marker(0.2, _anchor_material)
			add_child(marker)
			_markers[id] = marker
		(_markers[id] as Node3D).position = (_xforms[id] as Transform3D) * asset.anchor_local
	else:
		_free_decor(_markers, id)
	if _show_ids:
		if not _labels.has(id):
			_labels[id] = _make_label(id)
			add_child(_labels[id])
		var wb := world_bounds(id)
		(_labels[id] as Node3D).position = Vector3(
			wb.position.x + wb.size.x * 0.5, wb.end.y + 0.5, wb.position.z + wb.size.z * 0.5)
	else:
		_free_decor(_labels, id)


func _make_label(id: String) -> Label3D:
	var label := Label3D.new()
	label.text = id.left(8)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.01
	label.font_size = 48
	return label
