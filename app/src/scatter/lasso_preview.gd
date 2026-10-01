class_name LassoPreview
extends Node3D
## Terrain-draped dashed loop shown while the Fill tool draws (docs/editor-v2.md §6). Purely
## visual: never pickable, never in history. The loop closes back to its first point.

const LIFT_M := 0.12
const DASH_M := 0.6
const GAP_M := 0.4

var _mesh := ImmediateMesh.new()
var _instance := MeshInstance3D.new()


func _init() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	_instance.mesh = _mesh
	_instance.material_override = mat
	_instance.visible = false
	add_child(_instance)


func show_loop(doc: WorldDocument, points: PackedVector2Array, color: Color) -> void:
	if points.size() < 2:
		hide_loop()
		return
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_mesh.surface_set_color(color)
	var carried := 0.0
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		carried = _dash_edge(doc, a, b, carried)
	_mesh.surface_end()
	_instance.visible = true


func hide_loop() -> void:
	_instance.visible = false


func is_loop_visible() -> bool:
	return _instance.visible


## Emits the dashes of edge a -> b, which starts `d0` metres into the loop; returns where it ends.
## Dashes are the first DASH_M of every DASH_M + GAP_M cycle of the loop's running length.
func _dash_edge(doc: WorldDocument, a: Vector2, b: Vector2, d0: float) -> float:
	var length := a.distance_to(b)
	var d1 := d0 + length
	var cycle := DASH_M + GAP_M
	if length < 1e-6:
		return d1
	for k in range(floori(d0 / cycle), floori(d1 / cycle) + 1):
		var from := maxf(d0, float(k) * cycle)
		var to := minf(d1, float(k) * cycle + DASH_M)
		if to > from:
			_mesh.surface_add_vertex(_draped(doc, a.lerp(b, (from - d0) / length)))
			_mesh.surface_add_vertex(_draped(doc, a.lerp(b, (to - d0) / length)))
	return d1


func _draped(doc: WorldDocument, p: Vector2) -> Vector3:
	var h := doc.sample_height(p.x, p.y) if doc != null else NAN
	return Vector3(p.x, (0.0 if is_nan(h) else h) + LIFT_M, p.y)
