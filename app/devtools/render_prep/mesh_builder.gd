extends RefCounted
## Indexed triangle builder for the procedural bench fixtures. Every triangle is oriented so its
## clockwise (Godot front-face) winding agrees with the average vertex normal.

var pos := PackedVector3Array()
var nrm := PackedVector3Array()
var uv := PackedVector2Array()
var col := PackedColorArray()
var idx := PackedInt32Array()
var use_uv := false
var use_col := false
var cylinder_uv := false


func vert(p: Vector3, n: Vector3, c: Color = Color.WHITE, t: Vector2 = Vector2.ZERO) -> int:
	pos.append(p)
	nrm.append(n)
	col.append(c)
	uv.append(t)
	return pos.size() - 1


func tri(a: int, b: int, c: int) -> void:
	var g := (pos[c] - pos[a]).cross(pos[b] - pos[a])
	if g.dot(nrm[a] + nrm[b] + nrm[c]) < 0.0:
		var t := b
		b = c
		c = t
	idx.append_array(PackedInt32Array([a, b, c]))


func quad(a: int, b: int, c: int, d: int) -> void:
	tri(a, b, c)
	tri(a, c, d)


func triangle_count() -> int:
	return idx.size() / 3


## Tapered cylinder along local +Y from the origin of `xf`; r0 at the base, r1 at the top. A
## duplicated seam column keeps the texture coordinates continuous (u wraps once, v follows height).
func cylinder(xf: Transform3D, r0: float, r1: float, length: float, segs: int, rings: int, c0: Color, c1: Color) -> void:
	use_uv = use_uv or cylinder_uv
	var slope := (r0 - r1) / length
	var grid: Array = []
	for r in rings + 1:
		var t := float(r) / float(rings)
		var row: Array[int] = []
		for s in segs + 1:
			var a := TAU * float(s) / float(segs)
			var local := Vector3(cos(a) * lerpf(r0, r1, t), length * t, sin(a) * lerpf(r0, r1, t))
			var n := (xf.basis * Vector3(cos(a), slope, sin(a))).normalized()
			row.append(vert(xf * local, n, c0.lerp(c1, t), Vector2(float(s) / float(segs), t * length * 0.25)))
		grid.append(row)
	for r in rings:
		for s in segs:
			quad(grid[r][s], grid[r][s + 1], grid[r + 1][s + 1], grid[r + 1][s])


## Leaf along basis.y (length), width along basis.x, face normal basis.z. 4*(segs-1) triangles.
func leaf(origin: Vector3, basis: Basis, length: float, width: float, segs: int, fold: float, c: Color, nbias: Vector3) -> void:
	var centre: Array[int] = []
	var left: Array[int] = []
	var right: Array[int] = []
	for k in segs + 1:
		var t := float(k) / float(segs)
		var cp := origin + basis.y * (length * t) + basis.z * (0.12 * length * sin(PI * t))
		var shade := c.darkened(0.25 * (1.0 - t))
		centre.append(vert(cp, (basis.z + nbias).normalized(), shade))
		if k > 0 and k < segs:
			var hw := width * 0.5 * pow(sin(PI * t), 0.8)
			var lp := cp - basis.x * hw + basis.z * (hw * fold)
			var rp := cp + basis.x * hw + basis.z * (hw * fold)
			left.append(vert(lp, (basis.z - basis.x * fold + nbias).normalized(), shade))
			right.append(vert(rp, (basis.z + basis.x * fold + nbias).normalized(), shade))
	tri(centre[0], left[0], centre[1])
	tri(centre[0], centre[1], right[0])
	for k in range(1, segs - 1):
		tri(centre[k], left[k - 1], left[k])
		tri(centre[k], left[k], centre[k + 1])
		tri(centre[k], centre[k + 1], right[k])
		tri(centre[k], right[k], right[k - 1])
	tri(centre[segs - 1], left[segs - 2], centre[segs])
	tri(centre[segs - 1], centre[segs], right[segs - 2])


## Flat card from `base` along `forward` (length) with width along `side`. `cell` is the atlas
## rectangle (min, size); the sprig base is at the bottom of the cell.
func card(base: Vector3, forward: Vector3, side: Vector3, length: float, width: float, cell: Rect2, c: Color, nbias: Vector3) -> void:
	use_uv = true
	var fn := side.cross(forward).normalized()
	if fn.y < 0.0:
		fn = -fn
	var n := (fn * 0.5 + nbias).normalized()
	var hw := side * (width * 0.5)
	var b0 := vert(base - hw, n, c, cell.position + Vector2(0.0, cell.size.y))
	var b1 := vert(base + hw, n, c, cell.position + cell.size)
	var t1 := vert(base + hw + forward * length, n, c, cell.position + Vector2(cell.size.x, 0.0))
	var t0 := vert(base - hw + forward * length, n, c, cell.position)
	quad(b0, b1, t1, t0)


## Icosphere lobe (20 * 4^subdiv triangles) scaled by `radii`, displaced by `bump`, centred at `centre`.
func lobe(centre: Vector3, radii: Vector3, subdiv: int, c: Color, bump: float, seed_offset: float) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v: Array[Vector3] = []
	for p in [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
			Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]:
		v.append((p as Vector3).normalized())
	var faces: Array = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2],
		[10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10],
		[8, 6, 7], [9, 8, 1]]
	for _s in subdiv:
		var next: Array = []
		var cache := {}
		for f: Array in faces:
			var m: Array[int] = []
			for e in 3:
				var a: int = f[e]
				var b: int = f[(e + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				if not cache.has(key):
					v.append(((v[a] + v[b]) * 0.5).normalized())
					cache[key] = v.size() - 1
				m.append(cache[key])
			next.append([f[0], m[0], m[2]])
			next.append([f[1], m[1], m[0]])
			next.append([f[2], m[2], m[1]])
			next.append([m[0], m[1], m[2]])
		faces = next
	var ids: Array[int] = []
	for d in v:
		var k := 1.0 + bump * sin(5.1 * d.x + seed_offset) * cos(4.3 * d.y + 1.7 * seed_offset) * sin(6.7 * d.z + 0.5)
		var p := centre + Vector3(d.x * radii.x, d.y * radii.y, d.z * radii.z) * k
		ids.append(vert(p, Vector3(d.x / radii.x, d.y / radii.y, d.z / radii.z).normalized(), c.darkened(0.15 * (1.0 - d.y) * 0.5)))
	for f: Array in faces:
		tri(ids[f[0]], ids[f[1]], ids[f[2]])


## UV-sphere style ellipsoid with a deterministic displacement of the direction; used for rocks.
func displaced_ellipsoid(centre: Vector3, radii: Vector3, segs: int, rings: int, bump: float, floor_y: float, base_col: Color) -> void:
	var grid: Array = []
	var top := vert(Vector3.ZERO, Vector3.UP)
	var bottom := vert(Vector3.ZERO, Vector3.DOWN)
	for r in range(1, rings):
		var lat := PI * float(r) / float(rings)
		var row: Array[int] = []
		for s in segs:
			var az := TAU * float(s) / float(segs)
			var d := Vector3(sin(lat) * cos(az), cos(lat), sin(lat) * sin(az))
			var k := _rock_displacement(d, bump)
			var p := centre + Vector3(d.x * radii.x, d.y * radii.y, d.z * radii.z) * k
			p.y = maxf(p.y, floor_y)
			var shade := 0.85 + 0.3 * (k - 1.0 + bump) / maxf(2.0 * bump, 0.001)
			row.append(vert(p, Vector3(d.x / radii.x, d.y / radii.y, d.z / radii.z).normalized(), Color(base_col.r * shade, base_col.g * shade, base_col.b * shade, 1.0)))
		grid.append(row)
	pos[top] = centre + Vector3(0.0, radii.y * _rock_displacement(Vector3.UP, bump), 0.0)
	pos[bottom] = Vector3(centre.x, floor_y, centre.z)
	col[top] = base_col
	col[bottom] = base_col.darkened(0.3)
	for s in segs:
		var s2 := (s + 1) % segs
		tri(top, grid[0][s2], grid[0][s])
		tri(bottom, grid[rings - 2][s], grid[rings - 2][s2])
		for r in rings - 2:
			quad(grid[r][s], grid[r][s2], grid[r + 1][s2], grid[r + 1][s])


static func _rock_displacement(d: Vector3, bump: float) -> float:
	return 1.0 + bump * (0.6 * sin(3.1 * d.x + 1.3) * cos(2.7 * d.z + 0.4) + 0.4 * sin(5.3 * d.y + 2.0 * d.x))


func to_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	if use_col:
		arrays[Mesh.ARRAY_COLOR] = col
	if use_uv:
		arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
