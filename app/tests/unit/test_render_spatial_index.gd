extends TestCase
## RenderSpatialIndex: XZ grid with overlap references, ray DDA and nearest queries.

var index: RenderSpatialIndex


func before_each() -> void:
	index = RenderSpatialIndex.new(32.0)


func _box(x: float, y: float, z: float, sx: float = 2.0, sy: float = 2.0, sz: float = 2.0) -> AABB:
	return AABB(Vector3(x, y, z), Vector3(sx, sy, sz))


func _ids(a: PackedStringArray) -> Array:
	return Array(a)


func test_put_remove_has_replace() -> void:
	index.put("a", _box(1, 0, 1))
	assert_true(index.has("a"))
	assert_eq(index.size(), 1)
	assert_eq(index.bounds_of("a"), _box(1, 0, 1))
	index.put("a", _box(100, 0, 100))
	assert_eq(index.size(), 1)
	assert_eq(_ids(index.query_aabb(_box(0, -1, 0, 10, 4, 10))), [])
	assert_eq(_ids(index.query_aabb(_box(99, -1, 99, 10, 4, 10))), ["a"])
	index.remove("a")
	index.remove("a")
	assert_false(index.has("a"))
	assert_eq(index.size(), 0)
	assert_eq(index.cell_count(), 0)
	assert_eq(index.bounds_of("a"), AABB())
	index.put("b", _box(0, 0, 0))
	index.clear()
	assert_eq(index.size(), 0)
	assert_eq(_ids(index.query_ray(Vector3(0, 10, 0), Vector3.DOWN, 100.0)), [])


func test_negative_coordinates_and_cell_edges() -> void:
	index.put("origin", _box(-1, 0, -1))  # spans the four cells around (0, 0)
	assert_eq(index.cell_count(), 4)
	index.put("far", _box(-33, 0, -33))  # spans the four cells around (-32, -32)
	assert_eq(index.cell_count(), 7, "shares the (-1, -1) cell with origin")
	index.put("edge", AABB(Vector3(32, 0, 32), Vector3(0.0, 1, 0.0)))
	assert_eq(_ids(index.query_aabb(_box(-34, -1, -34, 2, 4, 2))), ["far"])
	assert_eq(_ids(index.query_aabb(_box(0.5, -1, 0.5, 0.2, 4, 0.2))), ["origin"])
	assert_eq(_ids(index.query_aabb(_box(-0.5, -1, -0.5, 0.2, 4, 0.2))), ["origin"])
	assert_eq(_ids(index.query_aabb(_box(31, -1, 31, 2, 4, 2))), ["edge"])
	assert_eq(_ids(index.query_aabb(_box(-1000, -10, -1000, 2000, 20, 2000))), ["edge", "far", "origin"])


func test_query_aabb_deduplicates_across_overlap_cells() -> void:
	index.put("wide", _box(-10, 0, -10, 100, 2, 100))
	assert_true(index.cell_count() > 4)
	assert_eq(_ids(index.query_aabb(_box(-50, -5, -50, 300, 10, 300))), ["wide"])
	assert_eq(_ids(index.query_aabb(_box(0, 5, 0, 5, 1, 5))), [], "above the box in Y")
	index.put("a", _box(5, 0, 5))
	index.put("b", _box(4, 0, 4))
	assert_eq(_ids(index.query_aabb(_box(0, 0, 0, 10, 2, 10))), ["a", "b", "wide"], "sorted ascending")
	assert_eq(_ids(index.query_aabb(AABB(Vector3(NAN, 0, 0), Vector3.ONE))), [])


func test_ray_diagonal_across_many_cells() -> void:
	for i in range(-10, 11):
		index.put("p%02d" % (i + 10), _box(i * 40.0, 0, i * 40.0))
	index.put("off", _box(200, 0, -200))
	var got := index.query_ray(Vector3(-500, 1, -500), Vector3(1, 0, 1), 5000.0)
	var want: Array = []
	for i in range(-10, 11):
		want.append("p%02d" % (i + 10))
	assert_eq(_ids(got), want)
	var back := index.query_ray(Vector3(500, 1, 500), Vector3(-1, 0, -1), 5000.0)
	assert_eq(_ids(back), want)
	assert_eq(_ids(index.query_ray(Vector3(-500, 1, 502), Vector3(1, 0, -1), 5000.0)), ["off", "p10"])


func test_ray_vertical_and_inside() -> void:
	index.put("a", _box(-1, 0, -1, 2, 2, 2))
	index.put("b", _box(40, 0, 0))
	assert_eq(_ids(index.query_ray(Vector3(0, 50, 0), Vector3.DOWN, 100.0)), ["a"])
	assert_eq(_ids(index.query_ray(Vector3(0, 50, 0), Vector3.UP, 100.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, 1, 0), Vector3(1, 0.3, 0.2), 0.0)), ["a"], "origin inside counts")
	assert_eq(_ids(index.query_ray(Vector3(0.5, 0.5, 0.5), Vector3.RIGHT, 1000.0)), ["a", "b"])


func test_ray_outside_occupied_rect_and_cutoff() -> void:
	index.put("a", _box(100, 0, 100))
	assert_eq(_ids(index.query_ray(Vector3(-5000, 1, 101), Vector3.RIGHT, 100000.0)), ["a"])
	assert_eq(_ids(index.query_ray(Vector3(-5000, 1, 101), Vector3.LEFT, 100000.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(-5000, 1, 500), Vector3.RIGHT, 100000.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, 1, 101), Vector3.RIGHT, 99.0)), [], "max_distance cutoff")
	assert_eq(_ids(index.query_ray(Vector3(0, 1, 101), Vector3.RIGHT, 101.5)), ["a"])
	assert_eq(_ids(index.query_ray(Vector3(0, 1, 101), Vector3(7, 0, 0), 500.0)), ["a"], "non-unit dir")


func test_ray_rect_shrinks_after_removal() -> void:
	index.put("a", _box(0, 0, 0))
	index.put("b", _box(3200, 0, 0))
	index.remove("b")
	assert_eq(_ids(index.query_ray(Vector3(-10, 1, 1), Vector3.RIGHT, 5000.0)), ["a"])
	assert_eq(_ids(index.query_ray(Vector3(4000, 1, 1), Vector3.LEFT, 8000.0)), ["a"])


func test_ray_invalid_input() -> void:
	index.put("a", _box(0, 0, 0))
	assert_eq(_ids(index.query_ray(Vector3(NAN, 1, 0), Vector3.DOWN, 10.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, INF, 0), Vector3.DOWN, 10.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, 5, 0), Vector3(0, NAN, 0), 10.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, 5, 0), Vector3.ZERO, 10.0)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, 5, 0), Vector3.DOWN, NAN)), [])
	assert_eq(_ids(index.query_ray(Vector3(0, 5, 0), Vector3.DOWN, -1.0)), [])


func test_query_near_order_ties_and_count() -> void:
	index.put("c", _box(9, 0, -1))  # centre (10, 1, 0)
	index.put("a", _box(-11, 0, -1))  # centre (-10, 1, 0): same distance as c, smaller id
	index.put("b", _box(2, 0, -1))  # centre (3, 1, 0)
	index.put("z", _box(500, 0, 0))
	var centre := Vector3(0, 1, 0)
	assert_eq(_ids(index.query_near(centre, 50.0, 10)), ["b", "a", "c"])
	assert_eq(_ids(index.query_near(centre, 50.0, 2)), ["b", "a"])
	assert_eq(_ids(index.query_near(centre, 5.0, 10)), ["b"])
	assert_eq(_ids(index.query_near(centre, 9.99, 10)), ["b"])
	assert_eq(_ids(index.query_near(centre, 10.0, 10)), ["b", "a", "c"], "inclusive radius")
	assert_eq(_ids(index.query_near(centre, 1000.0, 10)), ["b", "a", "c", "z"])
	assert_eq(_ids(index.query_near(centre, 50.0, 0)), [])
	assert_eq(_ids(index.query_near(Vector3(NAN, 0, 0), 50.0, 5)), [])
