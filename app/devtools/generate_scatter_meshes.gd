extends SceneTree
## Deterministic scatter-mesh generator. Writes app/assets/models/<name>_scatter.tres (ArrayMesh,
## vertex colours, one embedded material, no ext_resource) and the preview scenes of the
## ground-cover assets. Run from the repo root:
##   godot --headless --path app --script res://devtools/generate_scatter_meshes.gd
## Every output feeds the catalog hash (docs/world-format.md §8): regenerate fixtures afterwards.

const OUT_DIR := "res://assets/models/"

var _st: SurfaceTool
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var builders := {
		"grass_tuft_a": [_build_grass, true, "GrassTuftA"],
		"fern_a": [_build_fern, true, "FernA"],
		"wildflowers_a": [_build_flowers, true, "WildflowersA"],
		"pebbles_a": [_build_pebbles, false, "PebblesA"],
		"boulder_a": [_build_boulder, false, ""],
		"spruce_a": [_build_spruce, false, ""],
	}
	var failed := false
	for key in builders:
		var spec: Array = builders[key]
		var mesh: ArrayMesh = _make(spec[0], spec[1])
		var path: String = OUT_DIR + key + "_scatter.tres"
		failed = _save(mesh, path) or failed
		print("%s: %d triangles" % [path, triangle_count(mesh)])
		if spec[2] != "":
			# Fresh mesh instance: a mesh that was saved to a .tres would be referenced by path.
			failed = _save_scene(_make(spec[0], spec[1]), spec[2], OUT_DIR + key + ".tscn") or failed
	quit(1 if failed else 0)


static func triangle_count(mesh: ArrayMesh) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.size() > 0:
		return idx.size() / 3
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func _make(builder: Callable, double_sided: bool) -> ArrayMesh:
	_rng.seed = 20260501
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.call()
	var mesh := _st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.9
	if double_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _save(mesh: ArrayMesh, path: String) -> bool:
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		printerr("cannot save %s (error %d)" % [path, err])
	return err != OK


func _save_scene(mesh: ArrayMesh, root_name: String, path: String) -> bool:
	var root := Node3D.new()
	root.name = root_name
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, path)
	root.free()
	if err != OK:
		printerr("cannot save %s (error %d)" % [path, err])
		return true
	_stabilize_ids(path)
	return false


## Godot writes random unique_id / sub_resource ids; rewrite them so regeneration is byte-stable.
func _stabilize_ids(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var re := RegEx.new()
	re.compile("\\[sub_resource type=\"(\\w+)\" id=\"(\\w+)\"\\]")
	for m in re.search_all(text):
		text = text.replace(m.get_string(2), m.get_string(1).to_snake_case())
	re.compile(" unique_id=\\d+")
	text = re.sub(text, "", true)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# --- Triangle helpers ---------------------------------------------------------------------
## Adds a triangle with a flat normal. With `inside`, the winding is flipped so the normal
## points away from that point (Godot front faces are clockwise).
func _tri(a: Vector3, b: Vector3, c: Vector3, col: Color, inside: Variant = null) -> void:
	var n := (c - a).cross(b - a)
	if inside != null and n.dot((a + b + c) / 3.0 - (inside as Vector3)) < 0.0:
		var t := b
		b = c
		c = t
		n = -n
	elif inside == null and n.y < 0.0:
		var t2 := b
		b = c
		c = t2
		n = -n
	n = n.normalized()
	for v: Vector3 in [a, b, c]:
		_st.set_color(col)
		_st.set_normal(n)
		_st.add_vertex(v)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(a, b, c, col)
	_tri(a, c, d, col)


func _shade(col: Color, k: float) -> Color:
	return Color(col.r * k, col.g * k, col.b * k, 1.0)


## Tapered blade: base quad to mid, then a tip triangle (3 triangles). The blade leans along
## `lean` (horizontal) and faces `yaw`.
func _blade(base: Vector3, yaw: float, width: float, height: float, lean: float, col: Color) -> void:
	var side := Vector3(cos(yaw), 0.0, -sin(yaw)) * width * 0.5
	var out := Vector3(sin(yaw), 0.0, cos(yaw)) * lean
	var mid := base + Vector3(0.0, height * 0.55, 0.0) + out * 0.3
	var tip := base + Vector3(0.0, height, 0.0) + out
	_quad(base - side, base + side, mid + side * 0.6, mid - side * 0.6, _shade(col, 0.85))
	_tri(mid - side * 0.6, mid + side * 0.6, tip, col)


# --- Ground cover -------------------------------------------------------------------------
func _build_grass() -> void:
	var greens := [Color(0.34, 0.62, 0.22), Color(0.46, 0.72, 0.28)]
	for i in 7:
		var yaw := i * 0.9 + _rng.randf_range(-0.2, 0.2)
		var r := 0.03 + 0.04 * float(i % 3)
		var base := Vector3(sin(yaw * 2.1) * r, 0.0, cos(yaw * 2.1) * r)
		var h := _rng.randf_range(0.26, 0.35)
		_blade(base, yaw, 0.07, h, _rng.randf_range(0.04, 0.12), greens[i % 2])


func _build_fern() -> void:
	var dark := Color(0.15, 0.40, 0.16)
	for i in 6:
		var yaw := TAU * float(i) / 6.0 + _rng.randf_range(-0.15, 0.15)
		var dir := Vector3(sin(yaw), 0.0, cos(yaw))
		var side := Vector3(cos(yaw), 0.0, -sin(yaw))
		var reach := _rng.randf_range(0.32, 0.4)
		var rise := _rng.randf_range(0.52, 0.6)
		var spine: Array[Vector3] = []
		for s in 5:
			var t := float(s) / 4.0
			# Arch: rises fast, then bends outwards and droops slightly at the tip.
			spine.append(dir * (reach * t * t + 0.02 * t) + Vector3(0.0, rise * sin(t * PI * 0.5) * (1.0 - 0.18 * t * t), 0.0))
		var shade := 0.85 + 0.3 * float(i % 2)
		for s in 3:
			var w0 := 0.075 * (1.0 - float(s) * 0.28)
			var w1 := 0.075 * (1.0 - float(s + 1) * 0.28)
			_quad(spine[s] - side * w0, spine[s] + side * w0, spine[s + 1] + side * w1, spine[s + 1] - side * w1, _shade(dark, shade))
		var w3 := 0.075 * (1.0 - 3.0 * 0.28)
		_tri(spine[3] - side * w3, spine[3] + side * w3, spine[4], _shade(dark, shade))


func _build_flowers() -> void:
	var green := Color(0.36, 0.62, 0.24)
	for i in 4:
		var yaw := i * 1.6 + 0.3
		var base := Vector3(sin(yaw) * 0.05, 0.0, cos(yaw) * 0.05)
		_blade(base, yaw, 0.06, _rng.randf_range(0.2, 0.28), 0.06, green)
	var petals := [Color(0.98, 0.84, 0.18), Color(0.95, 0.52, 0.72), Color(0.97, 0.97, 0.94),
		Color(0.98, 0.84, 0.18), Color(0.95, 0.52, 0.72)]
	for i in 5:
		var yaw := TAU * float(i) / 5.0 + 0.4
		var foot := Vector3(sin(yaw) * 0.1, 0.0, cos(yaw) * 0.1)
		var head := foot + Vector3(sin(yaw) * 0.03, _rng.randf_range(0.3, 0.4), cos(yaw) * 0.03)
		var s := Vector3(cos(yaw), 0.0, -sin(yaw)) * 0.012
		_tri(foot - s, foot + s, head, green)
		var r := 0.045
		var tilt := Vector3(sin(yaw), 0.0, cos(yaw)) * 0.01
		_quad(head + Vector3(-r, 0.0, -r) + tilt, head + Vector3(r, 0.0, -r) + tilt,
			head + Vector3(r, 0.01, r) + tilt, head + Vector3(-r, 0.01, r) + tilt, petals[i])


func _rock(center: Vector3, rx: float, ry: float, rz: float, col: Color, segs: int) -> void:
	# Upper hemisphere (pole, mid ring, equator on the ground plane): 3 * segs triangles.
	var top := center + Vector3(0.0, ry, 0.0)
	var mid: Array[Vector3] = []
	var eq: Array[Vector3] = []
	for s in segs:
		var az := TAU * float(s) / float(segs) + 0.3
		var k := _rng.randf_range(0.82, 1.0)
		mid.append(center + Vector3(cos(0.9) * cos(az) * rx * k, sin(0.9) * ry * k, cos(0.9) * sin(az) * rz * k))
		var k2 := _rng.randf_range(0.85, 1.0)
		eq.append(center + Vector3(cos(az) * rx * k2, 0.0, sin(az) * rz * k2))
	for s in segs:
		var s2 := (s + 1) % segs
		_tri(top, mid[s], mid[s2], _shade(col, 1.12), center)
		_tri(mid[s], eq[s], eq[s2], _shade(col, 0.95 + 0.1 * float(s % 2)), center)
		_tri(mid[s], eq[s2], mid[s2], _shade(col, 0.88 + 0.1 * float(s % 2)), center)


func _build_pebbles() -> void:
	_rock(Vector3(-0.1, 0.0, 0.05), 0.17, 0.11, 0.14, Color(0.58, 0.57, 0.54), 6)
	_rock(Vector3(0.14, 0.0, -0.06), 0.12, 0.08, 0.1, Color(0.46, 0.45, 0.43), 6)
	_rock(Vector3(0.0, 0.0, -0.17), 0.09, 0.06, 0.08, Color(0.66, 0.64, 0.6), 6)


# --- Boulder and spruce -------------------------------------------------------------------
func _build_boulder() -> void:
	# Ellipsoid matching boulder_a.tscn (radius 1.1 x 0.7, centre (0.25, 0.7, -0.15)), jittered inwards.
	var center := Vector3(0.25, 0.7, -0.15)
	var segs := 8
	var lats := [PI * 0.5, PI * 0.3, PI * 0.1, -PI * 0.1, -PI * 0.3, -PI * 0.5]
	var rows: Array = []
	for lat: float in lats:
		var row: Array[Vector3] = []
		var n := 1 if absf(lat) > PI * 0.49 else segs
		for s in n:
			var az := TAU * float(s) / float(segs) + (0.2 if lats.find(lat) % 2 == 0 else 0.0)
			var k := 1.0 if n == 1 else _rng.randf_range(0.84, 1.0)
			row.append(center + Vector3(cos(lat) * cos(az) * 1.1 * k, sin(lat) * 0.7 * k, cos(lat) * sin(az) * 1.1 * k))
		rows.append(row)
	var grey := Color(0.5, 0.49, 0.46)
	for s in segs:
		var s2 := (s + 1) % segs
		_tri(rows[0][0], rows[1][s], rows[1][s2], _shade(grey, 1.15), center)
		for r in range(1, 4):
			var shade := 0.8 + 0.1 * float((s + r) % 3)
			_tri(rows[r][s], rows[r + 1][s], rows[r + 1][s2], _shade(grey, shade), center)
			_tri(rows[r][s], rows[r + 1][s2], rows[r][s2], _shade(grey, shade + 0.07), center)
		_tri(rows[5][0], rows[4][s2], rows[4][s], _shade(grey, 0.7), center)


func _cone(base_y: float, height: float, radius: float, sides: int, col: Color) -> void:
	var tip := Vector3(0.0, base_y + height, 0.0)
	var base_c := Vector3(0.0, base_y, 0.0)
	var inside := Vector3(0.0, base_y + height * 0.3, 0.0)
	for s in sides:
		var a0 := TAU * float(s) / float(sides)
		var a1 := TAU * float(s + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		_tri(tip, p0, p1, _shade(col, 0.85 + 0.15 * float(s % 2)), inside)
		_tri(base_c, p0, p1, _shade(col, 0.55), inside)


func _build_spruce() -> void:
	var bark := Color(0.36, 0.25, 0.16)
	var sides := 8
	var inside := Vector3(0.0, 0.8, 0.0)
	for s in sides:
		var a0 := TAU * float(s) / float(sides)
		var a1 := TAU * float(s + 1) / float(sides)
		var b0 := Vector3(cos(a0) * 0.24, 0.0, sin(a0) * 0.24)
		var b1 := Vector3(cos(a1) * 0.24, 0.0, sin(a1) * 0.24)
		var t0 := Vector3(cos(a0) * 0.18, 1.6, sin(a0) * 0.18)
		var t1 := Vector3(cos(a1) * 0.18, 1.6, sin(a1) * 0.18)
		_tri(b0, t0, t1, bark, inside)
		_tri(b0, t1, b1, bark, inside)
	_cone(1.4, 2.8, 1.4, 12, Color(0.13, 0.34, 0.18))
	_cone(2.8, 2.8, 1.1, 12, Color(0.15, 0.38, 0.2))
	_cone(4.2, 2.8, 0.8, 12, Color(0.18, 0.43, 0.23))
