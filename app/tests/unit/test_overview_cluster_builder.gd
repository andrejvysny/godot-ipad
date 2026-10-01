extends TestCase
## OverviewClusterBuilder (spec §9.2): deterministic, order independent, budgeted proxy geometry; LOD-05
## (top-down recognisability, clearings stay empty).

const SPRUCE := 0
const BOULDER := 1
const CABIN := 2
const GRASS := 3


func _table() -> PackedFloat32Array:
	var rows := [
		{"kind": "canopy", "shape": "cone", "base_y_m": 1.4, "height_m": 5.6, "radius_m": 1.4, "color": Color(0.13, 0.34, 0.18)},
		{"kind": "solid", "shape": "ellipsoid", "base_y_m": 0.0, "height_m": 1.4, "radius_m": 1.1, "color": Color(0.47, 0.46, 0.43)},
		{"kind": "solid", "shape": "box", "base_y_m": 0.0, "height_m": 7.3, "radius_m": 4.3, "color": Color(0.55, 0.38, 0.22)},
		{"kind": "none", "shape": "box", "base_y_m": 0.0, "height_m": 0.4, "radius_m": 0.3, "color": Color(0.3, 0.6, 0.2)}]
	var table := PackedFloat32Array()
	for row: Dictionary in rows:
		table.append_array(OverviewClusterBuilder.table_row(row))
	return table


## members: Array of [asset_row, Vector3 position, scale].
func _input(members: Array, size_m: float = 128.0, origin := Vector2.ZERO) -> Dictionary:
	var positions := PackedVector3Array()
	var assets := PackedInt32Array()
	var sxz := PackedFloat32Array()
	var sy := PackedFloat32Array()
	for m: Array in members:
		assets.append(int(m[0]))
		positions.append(m[1])
		sxz.append(float(m[2]))
		sy.append(float(m[2]))
	return {"origin": origin, "size_m": size_m, "cell_m": size_m / 32.0, "positions": positions, "assets": assets,
		"scale_xz": sxz, "scale_y": sy, "table": _table()}


func _forest(count: int, seed_value: int, rect: Rect2) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = []
	for i in count:
		var kind := SPRUCE if i % 9 != 0 else BOULDER
		out.append([kind, Vector3(rng.randf_range(rect.position.x, rect.end.x), rng.randf_range(0.0, 3.0),
				rng.randf_range(rect.position.y, rect.end.y)), rng.randf_range(0.8, 1.6)])
	return out


## Every triangle of a surface as [a, b, c, stored normal of a].
func _triangles(surface: Dictionary) -> Array:
	var out: Array = []
	var v: PackedVector3Array = surface.vertices
	var n: PackedVector3Array = surface.normals
	var idx: PackedInt32Array = surface.indices
	for t in range(0, idx.size(), 3):
		out.append([v[idx[t]], v[idx[t + 1]], v[idx[t + 2]], n[idx[t]]])
	return out


func test_same_inputs_give_identical_arrays_and_input_order_does_not_matter() -> void:
	var members := _forest(1500, 11, Rect2(0, 0, 128, 128))
	members.append([CABIN, Vector3(60, 0, 60), 1.0])
	var a := OverviewClusterBuilder.build(_input(members))
	var b := OverviewClusterBuilder.build(_input(members))
	assert_true(a == b, "identical inputs, identical outputs")
	var shuffled := members.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in range(shuffled.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = tmp
	var c := OverviewClusterBuilder.build(_input(shuffled))
	assert_true(a == c, "member order does not change the proxy")
	assert_true(int(a.lobes) > 100, "a forest produces many lobes")


func test_canopy_lobe_is_an_eight_sided_frustum_with_top_cap() -> void:
	var out := OverviewClusterBuilder.build(_input([[SPRUCE, Vector3(2.0, 0.0, 2.0), 1.0]]))
	var canopy: Dictionary = out.canopy
	assert_eq(canopy.lobes, 1)
	assert_eq(canopy.triangles, 24, "8 side quads + 8 cap triangles")
	assert_eq(out.solid.lobes, 0)
	var box := AABB((canopy.boxes as PackedVector3Array)[0], (canopy.boxes as PackedVector3Array)[1])
	assert_near(box.size.x, 4.0 * OverviewClusterBuilder.OVERSIZE, 1e-4, "lobe sized to the 4 m cell x 1.15")
	assert_near(box.position.y, 1.4, 1e-4, "bottom ring at the canopy base")
	assert_near(box.end.y, 7.0, 1e-4, "top ring at base + height")
	assert_vec_near(box.get_center() * Vector3(1, 0, 1), Vector3(2, 0, 2), 1e-4, "centred on the grid cell")


func test_every_triangle_is_clockwise_seen_from_outside() -> void:
	var members := _forest(400, 3, Rect2(0, 0, 128, 128))
	members.append([CABIN, Vector3(40, 0, 90), 1.0])
	members.append([BOULDER, Vector3(100, 0, 20), 3.0])
	members.append([BOULDER, Vector3(20, 0, 20), 1.0])
	var out := OverviewClusterBuilder.build(_input(members))
	var checked := 0
	for key in ["canopy", "solid"]:
		for t: Array in _triangles(out[key]):
			var face: Vector3 = ((t[2] as Vector3) - (t[0] as Vector3)).cross((t[1] as Vector3) - (t[0] as Vector3))
			assert_true(face.length() > 1e-6, "no degenerate triangle")
			assert_true(face.dot(t[3] as Vector3) > 0.0, "front face agrees with the outward normal")
			checked += 1
	assert_true(checked > 200)


func test_top_down_every_occupied_cell_has_an_upward_triangle_over_it() -> void:
	var members := _forest(900, 21, Rect2(0, 0, 128, 128))
	var out := OverviewClusterBuilder.build(_input(members))
	var occupied := {}
	for m: Array in members:
		var p: Vector3 = m[1]
		if int(m[0]) == SPRUCE:
			occupied[Vector2i(floori(p.x / 4.0), floori(p.z / 4.0))] = true
	var covered := {}
	for t: Array in _triangles(out.canopy):
		var face: Vector3 = ((t[2] as Vector3) - (t[0] as Vector3)).cross((t[1] as Vector3) - (t[0] as Vector3))
		if face.normalized().y > 0.5:
			var c: Vector3 = ((t[0] as Vector3) + (t[1] as Vector3) + (t[2] as Vector3)) / 3.0
			covered[Vector2i(floori(c.x / 4.0), floori(c.z / 4.0))] = true
	for cell: Vector2i in occupied:
		assert_true(covered.has(cell), "occupied cell %s has an upward-facing triangle" % cell)
	assert_eq(covered.size(), occupied.size(), "and nothing is drawn over empty cells")


func test_a_clearing_inside_a_forest_stays_empty() -> void:
	var clearing := Rect2(44, 44, 40, 40)
	var members: Array = []
	for m: Array in _forest(3000, 8, Rect2(0, 0, 128, 128)):
		var p: Vector3 = m[1]
		if not clearing.has_point(Vector2(p.x, p.z)):
			members.append(m)
	var out := OverviewClusterBuilder.build(_input(members))
	var interior := clearing.grow(-4.0)
	var inside := 0
	for key in ["canopy", "solid"]:
		var boxes: PackedVector3Array = out[key].boxes
		for i in range(0, boxes.size(), 2):
			var c := AABB(boxes[i], boxes[i + 1]).get_center()
			if interior.has_point(Vector2(c.x, c.z)):
				inside += 1
	assert_eq(inside, 0, "no lobe centre inside the clearing")
	assert_true(int(out.lobes) > 300, "the surrounding forest is drawn")


func test_ground_cover_is_ignored_and_large_solids_keep_their_silhouette() -> void:
	var out := OverviewClusterBuilder.build(_input([[GRASS, Vector3(10, 0, 10), 1.0], [GRASS, Vector3(14, 0, 10), 1.0]]))
	assert_eq(out.lobes, 0, "kind none is not drawn")
	assert_eq(out.triangles, 0)
	out = OverviewClusterBuilder.build(_input([[CABIN, Vector3(30, 0, 30), 1.0], [BOULDER, Vector3(30.5, 0, 31), 0.9],
			[BOULDER, Vector3(80, 0, 80), 3.0]]))
	assert_eq(out.canopy.lobes, 0)
	assert_eq(out.solid.lobes, 3, "the cabin and the big rock are individual, the small boulder is a grid cell")
	var widest := 0.0
	var boxes: PackedVector3Array = out.solid.boxes
	for i in range(0, boxes.size(), 2):
		widest = maxf(widest, boxes[i + 1].x)
	assert_true(widest > 8.0, "the cabin box keeps its footprint (%s m)" % widest)


func test_lobe_budget_aggregates_the_grid_deterministically() -> void:
	var members: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 2600:
		members.append([SPRUCE if i % 2 == 0 else BOULDER, Vector3(rng.randf_range(0, 128), 0.0, rng.randf_range(0, 128)), 1.0])
	var a := OverviewClusterBuilder.build(_input(members))
	assert_true(int(a.lobes) <= OverviewClusterBuilder.MAX_LOBES, "%d lobes" % int(a.lobes))
	assert_true(float(a.cell_m) > 4.0, "the grid was aggregated to %s m" % a.cell_m)
	assert_true(a == OverviewClusterBuilder.build(_input(members)), "aggregation is deterministic")
	assert_true(int(a.lobes) > 100, "and still draws the forest")


func test_vertices_are_local_to_the_group_origin() -> void:
	var out := OverviewClusterBuilder.build(_input([[SPRUCE, Vector3(260.0, 0.0, -250.0), 1.0]], 256.0, Vector2(256.0, -256.0)))
	assert_eq(out.canopy.lobes, 1)
	var box := AABB((out.canopy.boxes as PackedVector3Array)[0], (out.canopy.boxes as PackedVector3Array)[1])
	assert_true(box.position.x >= -1.0 and box.end.x <= 9.5 and box.position.z >= -1.0 and box.end.z <= 9.5, str(box))
	assert_near(float(out.cell_m), 8.0, 1e-6, "256 m groups use an 8 m grid")


func test_run_reports_the_result_and_time_for_a_worker() -> void:
	var out := {}
	OverviewClusterBuilder.run(_input(_forest(200, 1, Rect2(0, 0, 128, 128))), out)
	assert_true(out.has("result") and int(out.usec) >= 0)
	assert_true(OverviewClusterBuilder.empty_result().lobes == 0)
