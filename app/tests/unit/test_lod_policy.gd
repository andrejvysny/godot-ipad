extends TestCase

const PERF := {"near_min_role": "mid", "tree_detail_radius_m": 80.0, "ground_cover_radius_m": 25.0}
const BAL := {"near_min_role": "near", "tree_detail_radius_m": 120.0, "ground_cover_radius_m": 40.0}


func test_roles_follow_the_profile_thresholds() -> void:
	assert_eq(LodPolicy.roles(PERF), PackedStringArray(["mid", "far", "group128", "group256"]))
	assert_eq(LodPolicy.thresholds(PERF), PackedFloat64Array([80.0, 200.0, 400.0]))
	assert_eq(LodPolicy.role_for(10.0, PERF), "mid")
	assert_eq(LodPolicy.role_for(100.0, PERF), "far")
	assert_eq(LodPolicy.role_for(300.0, PERF), "group128")
	assert_eq(LodPolicy.role_for(900.0, PERF), "group256")
	assert_eq(LodPolicy.role_for(10.0, BAL), "near")
	assert_eq(LodPolicy.role_for(60.0, BAL), "mid")
	assert_eq(LodPolicy.individual_role(900.0, PERF), "far", "groups are the overview's decision")


func test_lod_01_hysteresis_prevents_toggling_near_a_threshold() -> void:
	var role := LodPolicy.role_for(79.0, PERF)
	assert_eq(role, "mid")
	for d: float in [80.5, 79.5, 81.0, 78.5, 80.0, 82.0]:
		role = LodPolicy.role_for(d, PERF, role)
		assert_eq(role, "mid", "inside the band at %.1f m" % d)
	role = LodPolicy.role_for(88.1, PERF, role)
	assert_eq(role, "far", "clears the band")
	for d: float in [79.0, 80.0, 75.0]:
		role = LodPolicy.role_for(d, PERF, role)
		assert_eq(role, "far", "stays coarse inside the band at %.1f m" % d)
	assert_eq(LodPolicy.role_for(71.9, PERF, role), "mid")


func test_big_jumps_skip_roles() -> void:
	assert_eq(LodPolicy.role_for(1000.0, PERF, "mid"), "group256")
	assert_eq(LodPolicy.role_for(5.0, PERF, "group256"), "mid")


func test_effective_distance_scales_with_fov_and_viewport() -> void:
	assert_near(LodPolicy.effective_distance(100.0, 60.0, 820.0), 100.0, 1e-9)
	assert_near(LodPolicy.effective_distance(100.0, 60.0, 1640.0), 50.0, 1e-9, "taller viewport: more detail")
	assert_true(LodPolicy.effective_distance(100.0, 90.0, 820.0) > 100.0, "wider FOV: less detail")


func test_ground_cover_radius_has_hysteresis() -> void:
	assert_true(LodPolicy.ground_cover_visible(20.0, PERF, false))
	assert_false(LodPolicy.ground_cover_visible(24.0, PERF, false), "appears only inside the band")
	assert_true(LodPolicy.ground_cover_visible(26.0, PERF, true), "inside the band while visible")
	assert_false(LodPolicy.ground_cover_visible(28.0, PERF, true))
