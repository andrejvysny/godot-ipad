extends TestCase
## ActiveEditArea (spec §8.2): EDIT-04 pin lifetime, EDIT-06 bounded pins for long strokes.

const CELL := 32.0


func test_begin_pins_the_cells_of_the_circle() -> void:
	var area := ActiveEditArea.new(CELL, 250)
	area.begin("op", Vector3(10, 0, 10), 12.0)
	assert_true(area.is_active())
	assert_true(area.is_pinned(Vector2i(0, 0)))
	assert_false(area.is_pinned(Vector2i(3, 3)))
	assert_eq(area.pinned_cells(CELL).size(), 3, "cells (0,0), (-1,0) and (0,-1); the diagonal cell is out of reach")
	var negative := ActiveEditArea.new(CELL, 250)
	negative.begin("op", Vector3(-1, 0, -1), 4.0)
	assert_true(negative.is_pinned(Vector2i(-1, -1)) and negative.is_pinned(Vector2i(0, 0)), "floor, not truncation")
	assert_true(negative.is_pinned(Vector2i(-1, 0)) and negative.is_pinned(Vector2i(0, -1)))


func test_pins_release_after_the_settle_interval() -> void:
	var area := ActiveEditArea.new(CELL, 250)
	area.begin("op", Vector3(10, 0, 10), 12.0)
	area.end("op", "finished")
	assert_false(area.is_active())
	area.tick(Time.get_ticks_msec() + 100)
	assert_true(area.is_pinned(Vector2i(0, 0)), "still pinned inside settle_ms")
	area.tick(Time.get_ticks_msec() + 400)
	assert_false(area.has_pins())
	assert_false(area.is_pinned(Vector2i(0, 0)))


func test_stale_operation_ids_are_ignored() -> void:
	var area := ActiveEditArea.new(CELL, 250)
	area.begin("a", Vector3.ZERO, 5.0)
	area.update("b", Vector3(500, 0, 500), 5.0)
	assert_true(area.is_pinned(Vector2i(0, 0)) and not area.is_pinned(Vector2i(15, 15)))
	area.end("b", "finished")
	assert_true(area.is_active(), "another operation cannot end this one")
	area.end("a", "cancelled")
	area.begin("c", Vector3(100, 0, 100), 5.0)
	area.update("a", Vector3.ZERO, 5.0)
	assert_true(area.is_pinned(Vector2i(3, 3)))
	assert_false(area.is_pinned(Vector2i(0, 0)), "a new operation replaces the old pins at once")


func test_long_stroke_never_pins_more_than_two_circles() -> void:
	var area := ActiveEditArea.new(CELL, 250)
	var radius := 12.0
	var most := 2 * (int(ceil(2.0 * radius / CELL)) + 1) * (int(ceil(2.0 * radius / CELL)) + 1)
	area.begin("stroke", Vector3.ZERO, radius)
	var peak := 0
	for i in 500:
		var p := Vector3(i * 2.0, 0.0, sin(i * 0.1) * 40.0)
		area.update("stroke", p, radius)
		peak = maxi(peak, area.pinned_cells(CELL).size())
		assert_true(area.pinned_cells(CELL).size() <= most, "step %d pins %d cells" % [i, area.pinned_cells(CELL).size()])
		assert_true(area.is_pinned(Vector2i(floori(p.x / CELL), floori(p.z / CELL))), "the cell under the brush stays pinned")
	assert_true(peak > 1)
	assert_false(area.is_pinned(Vector2i(0, 0)), "the start of a 1000 m stroke is released")
	assert_true(area.pinned_cells(CELL).size() <= most)


func test_radius_is_clamped() -> void:
	var area := ActiveEditArea.new(CELL, 250)
	area.begin("op", Vector3.ZERO, 100000.0)
	assert_true(area.pinned_cells(CELL).size() <= 12 * 12, "a huge radius cannot pin the world")
