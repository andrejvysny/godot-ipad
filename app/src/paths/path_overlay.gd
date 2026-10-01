class_name PathOverlay
extends Node3D
## Selection overlay of the Path tool (docs/editor-v2.md §7): white dashed centreline and one
## handle (white disc, accent outline) per control point, all lifted above the terrain.
## Purely visual: never pickable, never in history.

const LINE_LIFT_M := 0.14
const HANDLE_LIFT_M := 0.24
const DASH_M := 0.6
const GAP_M := 0.4
const STEP_M := 0.25
const HANDLE_R := 0.22  # white disc; the accent ring ends at RING_R, so the marker is 0.6 m across
const RING_R := 0.3
const DISC_SEGMENTS := 20
const COLOR_ACCENT := Color("f2bf33")

var _line_mesh := ImmediateMesh.new()
var _handle_mesh := ImmediateMesh.new()
var _line := MeshInstance3D.new()
var _handles := MeshInstance3D.new()
var _handle_positions: Array[Vector3] = []


func _init() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for pair: Array in [[_line, _line_mesh], [_handles, _handle_mesh]]:
		var node: MeshInstance3D = pair[0]
		node.mesh = pair[1]
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
	visible = false


func show_path(doc: WorldDocument, rec: PathRecord) -> void:
	_line_mesh.clear_surfaces()
	_handle_mesh.clear_surfaces()
	_handle_positions.clear()
	if rec == null or rec.points.size() < 2:
		visible = false
		return
	_build_line(doc, PathSpline.sample(rec.points, STEP_M))
	_build_handles(doc, rec.points)
	visible = true


func hide_overlay() -> void:
	visible = false


## World positions of the handle markers (lift included), in control-point order.
func handle_positions() -> Array[Vector3]:
	return _handle_positions.duplicate()


func _build_line(doc: WorldDocument, curve: PackedVector2Array) -> void:
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_line_mesh.surface_set_color(Color.WHITE)
	var cycle := DASH_M + GAP_M
	var run := 0.0
	for i in range(1, curve.size()):
		var a := curve[i - 1]
		var b := curve[i]
		var length := a.distance_to(b)
		if length < 1e-6:
			continue
		for k in range(floori(run / cycle), floori((run + length) / cycle) + 1):
			var from := maxf(run, float(k) * cycle)
			var to := minf(run + length, float(k) * cycle + DASH_M)
			if to > from:
				_line_mesh.surface_add_vertex(_lifted(doc, a.lerp(b, (from - run) / length), LINE_LIFT_M))
				_line_mesh.surface_add_vertex(_lifted(doc, a.lerp(b, (to - run) / length), LINE_LIFT_M))
		run += length
	_line_mesh.surface_end()


func _build_handles(doc: WorldDocument, points: PackedVector2Array) -> void:
	_handle_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in points:
		var c := _lifted(doc, p, HANDLE_LIFT_M)
		_handle_positions.append(c)
		for s in DISC_SEGMENTS:
			var a0 := TAU * float(s) / float(DISC_SEGMENTS)
			var a1 := TAU * float(s + 1) / float(DISC_SEGMENTS)
			var d0 := Vector3(cos(a0), 0.0, sin(a0))
			var d1 := Vector3(cos(a1), 0.0, sin(a1))
			_tri(c, c + d0 * HANDLE_R, c + d1 * HANDLE_R, Color.WHITE)
			_quad(c + d0 * HANDLE_R, c + d0 * RING_R, c + d1 * RING_R, c + d1 * HANDLE_R, COLOR_ACCENT)
	_handle_mesh.surface_end()


func _tri(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	_handle_mesh.surface_set_color(color)
	for v in [a, b, c]:
		_handle_mesh.surface_add_vertex(v)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	_tri(a, b, c, color)
	_tri(a, c, d, color)


func _lifted(doc: WorldDocument, p: Vector2, lift: float) -> Vector3:
	var h := doc.sample_height(p.x, p.y) if doc != null else NAN
	return Vector3(p.x, (0.0 if is_nan(h) else h) + lift, p.y)
