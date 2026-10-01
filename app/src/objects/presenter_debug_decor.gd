class_name PresenterDebugDecor
extends RefCounted
## Bounded anchor/ID debug decoration for ObjectPresenter (spec §8.4): fixed pools of at most
## `limit` Label3D / marker nodes reassigned to the nearest visible objects, never one per object.

const REFRESH_S := 0.25
const DEBUG_RADIUS_M := 200.0
const CANDIDATE_FACTOR := 4

var _host: ObjectPresenter
var _material: Material
var _markers: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []
var _assigned := PackedStringArray()
var _anchors: bool = false
var _ids: bool = false
var _limit: int = 64
var _camera: Camera3D
var _since: float = 0.0


func _init(host: ObjectPresenter, material: Material) -> void:
	_host = host
	_material = material


func configure(anchors: bool, ids: bool) -> void:
	_anchors = anchors
	_ids = ids
	refresh()


func set_limit(n: int) -> void:
	_limit = maxi(n, 0)
	refresh()


func set_camera(camera: Camera3D) -> void:
	_camera = camera


func tick(delta: float) -> void:
	if not (_anchors or _ids):
		return
	_since += delta
	if _since >= REFRESH_S:
		refresh()


func object_changed(id: String) -> void:
	var slot := _assigned.find(id)
	if slot >= 0:
		_place(slot)


func object_removed(id: String) -> void:
	if _assigned.has(id):
		refresh()


func refresh() -> void:
	_since = 0.0
	_assigned = _choose() if (_anchors or _ids) else PackedStringArray()
	_trim_pool(_markers, _assigned.size() if _anchors else 0)
	_trim_pool(_labels, _assigned.size() if _ids else 0)
	for slot in _assigned.size():
		_place(slot)


func marker_count() -> int:
	return _visible_count(_markers)


func label_count() -> int:
	return _visible_count(_labels)


func label_ids() -> PackedStringArray:
	var out := PackedStringArray()
	if _ids:
		out.append_array(_assigned)
	out.sort()
	return out


func marker_for(id: String) -> Node3D:
	var slot := _assigned.find(id)
	return _markers[slot] if _anchors and slot >= 0 and slot < _markers.size() else null


func label_for(id: String) -> Label3D:
	var slot := _assigned.find(id)
	return _labels[slot] if _ids and slot >= 0 and slot < _labels.size() else null


func _choose() -> PackedStringArray:
	var out := PackedStringArray()
	if _limit <= 0:
		return out
	var selected := _host.selected_id()
	if _camera == null or not _camera.is_inside_tree():
		var all := _host.object_ids()
		if selected != "":
			out.append(selected)
		for id in all:
			if out.size() >= _limit:
				break
			if id != selected:
				out.append(id)
		return out
	if selected != "":
		out.append(selected)
	var near := _host.objects_near(_camera.global_position, DEBUG_RADIUS_M, _limit * CANDIDATE_FACTOR)
	for id in near:
		if out.size() >= _limit:
			break
		if id != selected and _camera.is_position_in_frustum(_host.anchor_position(id)):
			out.append(id)
	return out


func _place(slot: int) -> void:
	var id := _assigned[slot]
	if _anchors:
		var marker := _pool_marker(slot)
		marker.position = _host.anchor_position(id)
		marker.visible = true
	if _ids:
		var label := _pool_label(slot)
		var wb := _host.world_bounds(id)
		label.position = Vector3(wb.position.x + wb.size.x * 0.5, wb.end.y + 0.5, wb.position.z + wb.size.z * 0.5)
		if label.text != id.left(8):
			label.text = id.left(8)
		label.visible = true


## Pool nodes are created on first use and reused; unused ones are hidden, never freed per refresh.
func _pool_marker(slot: int) -> MeshInstance3D:
	while _markers.size() <= slot:
		var node := _make_marker()
		node.visible = false
		_host.add_child(node)
		_markers.append(node)
	return _markers[slot]


func _pool_label(slot: int) -> Label3D:
	while _labels.size() <= slot:
		var node := _make_label()
		node.visible = false
		_host.add_child(node)
		_labels.append(node)
	return _labels[slot]


func _trim_pool(pool: Array, used: int) -> void:
	for i in range(used, pool.size()):
		(pool[i] as Node3D).visible = false


func _visible_count(pool: Array) -> int:
	var n := 0
	for node: Node3D in pool:
		if node.visible:
			n += 1
	return n


func _make_marker() -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _make_label() -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.01
	label.font_size = 48
	return label
