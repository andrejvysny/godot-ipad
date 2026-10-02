extends TestCase


func test_ready_downgrades_activate_while_moving_without_overlapping_children() -> void:
	var child := OverviewGroup.new(0, 128.0, Vector2i.ZERO)
	var parent := OverviewGroup.new(1, 256.0, Vector2i.ZERO)
	child.current = true
	child.active = true
	child.group_level = 1
	parent.current = true
	parent.group_level = 1
	var groups: Array[Dictionary] = [{Vector2i.ZERO: child}, {Vector2i.ZERO: parent}]
	var blocked: Array[Dictionary] = [{}, {}]
	var off: Array[OverviewGroup] = []
	var on: Array[OverviewGroup] = []
	assert_false(OverviewCut.compute(groups, blocked, false, off, on))
	assert_eq(off, [child])
	assert_eq(on, [parent])
	assert_false(child.cut_on)
	assert_true(parent.cut_on)


func test_finer_upgrade_waits_for_settle_and_retains_coarse_coverage() -> void:
	var child := OverviewGroup.new(0, 128.0, Vector2i.ZERO)
	var parent := OverviewGroup.new(1, 256.0, Vector2i.ZERO)
	child.current = true
	child.group_level = 0
	parent.current = true
	parent.active = true
	parent.group_level = 0
	var groups: Array[Dictionary] = [{Vector2i.ZERO: child}, {Vector2i.ZERO: parent}]
	var blocked: Array[Dictionary] = [{}, {}]
	var off: Array[OverviewGroup] = []
	var on: Array[OverviewGroup] = []
	assert_true(OverviewCut.compute(groups, blocked, false, off, on))
	assert_true(off.is_empty() and on.is_empty())
	assert_true(parent.cut_on)
	assert_false(child.cut_on)
	assert_false(OverviewCut.compute(groups, blocked, true, off, on))
	assert_eq(off, [parent])
	assert_eq(on, [child])
