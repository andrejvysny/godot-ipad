class_name PathRibbon
extends RefCounted
## Terrain-draped ribbon mesh along a polyline (docs/editor-v2.md §7): vertices at +-width/2
## perpendicular in XZ, Y = surface height + LIFT_M. A 0.25 m darker band runs along each edge
## (separate vertices, so the band stays hard). Rows without a terrain sample on any of their
## four vertices are skipped, which splits the ribbon at holes and the world edge.

const LIFT_M := 0.06
const EDGE_BAND_M := 0.25
const COLOR_FILL := Color("a37650")
const COLOR_EDGE_OVER := Color(50.0 / 255.0, 34.0 / 255.0, 18.0 / 255.0, 0.35)
const VERTS_PER_ROW := 6  # [outer-left, inner-left] band, [inner-left, inner-right] fill, [inner-right, outer-right] band


## Null when no row has terrain under it. `alpha` scales the vertex alpha (live preview).
static func build(doc: WorldDocument, curve: PackedVector2Array, width: float, alpha: float = 1.0) -> ArrayMesh:
	var n := curve.size()
	if n < 2 or doc == null:
		return null
	var half := width * 0.5
	var inner := maxf(half - EDGE_BAND_M, half * 0.2)
	var band := COLOR_FILL.lerp(Color(COLOR_EDGE_OVER, 1.0), COLOR_EDGE_OVER.a)
	var fill := Color(COLOR_FILL, alpha)
	band.a = alpha
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var valid := PackedByteArray()
	valid.resize(n)
	for i in n:
		var tangent := curve[mini(i + 1, n - 1)] - curve[maxi(i - 1, 0)]
		var side := Vector2(-tangent.y, tangent.x).normalized() if tangent.length_squared() > 1e-12 else Vector2.ZERO
		var offsets := [half, inner, -inner, -half]
		var row: Array[Vector3] = []
		var ok := side != Vector2.ZERO
		for off: float in offsets:
			var xz: Vector2 = curve[i] + side * off
			var h := doc.sample_height(xz.x, xz.y)
			ok = ok and not is_nan(h)
			row.append(Vector3(xz.x, (0.0 if is_nan(h) else h) + LIFT_M, xz.y))
		valid[i] = 1 if ok else 0
		verts.append_array(PackedVector3Array([row[0], row[1], row[1], row[2], row[2], row[3]]))
		colors.append_array(PackedColorArray([band, band, fill, fill, band, band]))
	var indices := PackedInt32Array()
	for i in n - 1:
		if valid[i] == 0 or valid[i + 1] == 0:
			continue
		for q in 3:
			var a := i * VERTS_PER_ROW + q * 2
			var b := (i + 1) * VERTS_PER_ROW + q * 2
			indices.append_array(PackedInt32Array([a, a + 1, b, a + 1, b + 1, b]))
	if indices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func material(translucent: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true  # the palette is given as sRGB hex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if translucent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat
