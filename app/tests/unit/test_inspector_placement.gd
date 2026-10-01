extends TestCase
## ObjectInspector.choose_position: side/below/above choice, avoid points, hysteresis.

const PANEL := Vector2(100, 100)
const FREE := Rect2(0, 0, 1000, 800)
const ANCHOR := Rect2(450, 350, 60, 60)


func _pts(points: Array[Vector2]) -> PackedVector2Array:
	return PackedVector2Array(points)


func test_clear_preferred_side() -> void:
	var r := ObjectInspector.choose_position(ANCHOR, FREE, PANEL, true, PackedVector2Array(), -1)
	assert_eq(r[1], 0)
	assert_eq(r[0], Vector2(ANCHOR.end.x + ObjectInspector.GAP, ANCHOR.get_center().y - 50.0))


func test_pushes_to_below_when_sides_blocked() -> void:
	var free := Rect2(430, 0, 160, 800) # preferred side clamps onto the anchor
	var avoid := _pts([Vector2(500, 380), Vector2(500, 400)])
	var r := ObjectInspector.choose_position(ANCHOR, free, PANEL, true, avoid, -1)
	assert_eq(r[1], 2)


## Every candidate covers points: right, pushed right, left, pushed left and above cover two each,
## below covers one, so below wins even though it is not preferred.
func test_fewest_covered_when_all_blocked() -> void:
	var avoid := _pts([Vector2(600, 350), Vector2(620, 420), Vector2(700, 350), Vector2(720, 420),
			Vector2(360, 350), Vector2(340, 420), Vector2(250, 350), Vector2(270, 420),
			Vector2(480, 260), Vector2(500, 300), Vector2(480, 500)])
	var r := ObjectInspector.choose_position(ANCHOR, FREE, PANEL, true, avoid, -1)
	assert_eq(r[1], 2, "below covers the fewest neighbours")
	var padded := Rect2(r[0], PANEL).grow(ObjectInspector.AVOID_MARGIN)
	var covered := 0
	for p in avoid:
		covered += 1 if padded.has_point(p) else 0
	assert_eq(covered, 1)
	assert_eq(ObjectInspector.choose_position(ANCHOR, FREE, PANEL, true, avoid, 0)[1], 2, "a worse last choice is dropped")


func test_never_overlaps_anchor_when_alternative_exists() -> void:
	var free := Rect2(430, 0, 160, 800)
	var r := ObjectInspector.choose_position(ANCHOR, free, PANEL, true, PackedVector2Array(), -1)
	assert_ne(r[1], 0, "clamped side overlaps the anchor")
	assert_false(Rect2(r[0], PANEL).intersects(ANCHOR.grow(ObjectInspector.GAP * 0.5)))


func test_hysteresis_on_ties() -> void:
	# Choices 0 and 3 are blocked by one avoid point each; 1 and 2 are clear and tied.
	var right_pos := Vector2(ANCHOR.end.x + ObjectInspector.GAP, ANCHOR.get_center().y - 50.0)
	var avoid := _pts([right_pos + Vector2(50, 50)])
	assert_eq(ObjectInspector.choose_position(ANCHOR, FREE, PANEL, true, avoid, -1)[1], 1)
	assert_eq(ObjectInspector.choose_position(ANCHOR, FREE, PANEL, true, avoid, 2)[1], 2)
	assert_eq(ObjectInspector.choose_position(ANCHOR, FREE, PANEL, true, avoid, 0)[1], 1, "blocked last_choice is dropped")


func test_free_smaller_than_panel() -> void:
	var free := Rect2(10, 20, 50, 50)
	var r := ObjectInspector.choose_position(ANCHOR, free, PANEL, true, PackedVector2Array(), 2)
	assert_eq(r[1], -1)
	assert_eq(r[0], free.position)


func test_side_pushed_past_clustered_neighbours() -> void:
	# Right side is too narrow, below/above overlap the anchor vertically: only the pushed-out left fits.
	var anchor := Rect2(665, 440, 48, 77)
	var free := Rect2(102, 154, 756, 608)
	var panel := Vector2(268, 333)
	var avoid := _pts([Vector2(634, 507), Vector2(574, 523)])
	var r := ObjectInspector.choose_position(anchor, free, panel, true, avoid, -1)
	var rect := Rect2(r[0], panel)
	assert_eq(r[1], 5)
	for p in avoid:
		assert_false(rect.grow(ObjectInspector.AVOID_MARGIN).has_point(p))
