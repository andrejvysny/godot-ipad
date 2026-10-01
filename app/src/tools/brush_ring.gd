class_name BrushRing
extends Node3D
## Terrain-draped brush outline (spec §12). Purely visual: never pickable, never in history.

const SEGMENTS := 64
const LIFT_M := 0.08
const CROSS_M := 0.4

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


func show_at(doc: WorldDocument, center: Vector3, radius: float, color: Color) -> void:
	if not center.is_finite() or not is_finite(radius) or radius <= 0.0:
		hide_ring()
		return
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_mesh.surface_set_color(color)
	for i in SEGMENTS + 1:
		var a := TAU * float(i) / float(SEGMENTS)
		_mesh.surface_add_vertex(_draped(doc, center, center.x + cos(a) * radius, center.z + sin(a) * radius))
	_mesh.surface_end()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(_draped(doc, center, center.x - CROSS_M, center.z))
	_mesh.surface_add_vertex(_draped(doc, center, center.x + CROSS_M, center.z))
	_mesh.surface_add_vertex(_draped(doc, center, center.x, center.z - CROSS_M))
	_mesh.surface_add_vertex(_draped(doc, center, center.x, center.z + CROSS_M))
	_mesh.surface_end()
	_instance.visible = true


func hide_ring() -> void:
	_instance.visible = false


func is_ring_visible() -> bool:
	return _instance.visible


func _draped(doc: WorldDocument, center: Vector3, x: float, z: float) -> Vector3:
	var h := doc.sample_height(x, z) if doc != null else NAN
	return Vector3(x, (center.y if is_nan(h) else h) + LIFT_M, z)
