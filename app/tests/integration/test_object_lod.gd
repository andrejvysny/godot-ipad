extends TestCase
## Per-cell object LOD (spec §4.2, §8.1, §8.2, §12.3, §21.2): LOD-01 hysteresis, settle-gated role changes,
## EDIT-04 pins, selection promotion, bounded evaluation, MEMORY-03 camera jump, MEMORY-05 repeated travel.
## Host (desktop) evidence only.

const SETTLE_MS := 60

var fx: OverviewFixture


func before_each() -> void:
	fx = OverviewFixture.new(tree)
	fx.set_profile(fx.profile.merged({"settle_ms": SETTLE_MS}, true))


func after_each() -> void:
	fx.release()
	fx = null


func _side(x: float, y: float, z: float) -> void:
	fx.aim(Vector3(x, y, z), Vector3(x + 1.0, y, z))


func _wait_settled() -> void:
	OS.delay_msec(SETTLE_MS + 20)
	fx.frame()


func _owner_role(id: String) -> String:
	return fx.world.owner_of(id).get_slice("|", 1)


func test_hysteresis_keeps_roles_stable_around_every_threshold() -> void:
	for profile: Dictionary in [{"near_min_role": "mid", "tree_detail_radius_m": 80.0},
			{"near_min_role": "near", "tree_detail_radius_m": 120.0}]:
		for limit: float in LodPolicy.thresholds(profile):
			var start := LodPolicy.role_for(limit * 0.97, profile, "", 0.2)
			var role := start
			for i in 100:
				role = LodPolicy.role_for(limit * (1.03 if i % 2 == 0 else 0.97), profile, role, 0.2)
				assert_eq(role, start, "a +-3%% camera wobble at %.1f m never switches" % limit)


func test_a_cell_never_toggles_when_the_camera_wobbles_around_a_threshold() -> void:
	var rec := fx.add(OverviewFixture.SPRUCE, Vector3(16.0, 0.0, 16.0))
	var threshold := fx.metric(80.0)
	_side(-threshold * 0.97, 0.0, 16.0)
	fx.sync_all()
	assert_true(fx.settle())
	assert_eq(_owner_role(rec.object_id), "mid")
	var roles := {}
	for i in 60:
		_side(-threshold * (1.03 if i % 2 == 0 else 0.97), 0.0, 16.0)
		fx.frame()
		OS.delay_msec(2)
		roles[fx.world.cell_wanted_role(Vector2i(0, 0))] = true
		roles[_owner_role(rec.object_id)] = true
	_wait_settled()
	assert_eq(roles.keys(), ["mid"], "wanted role and drawn tier never left mid")
	_side(-threshold * 1.25, 0.0, 16.0)
	assert_true(fx.settle())
	assert_eq(_owner_role(rec.object_id), "far", "a real move past the margin does switch")
	_side(-threshold * 1.03, 0.0, 16.0)
	assert_true(fx.settle())
	assert_eq(_owner_role(rec.object_id), "far", "and a small move back does not switch back")


func test_each_cell_takes_its_own_tier_and_first_builds_use_it_at_once() -> void:
	var near := fx.add(OverviewFixture.SPRUCE, Vector3(16.0, 0.0, 16.0))
	var far := fx.add(OverviewFixture.SPRUCE, Vector3(416.0, 0.0, 16.0))
	var mid_range := fx.add(OverviewFixture.SPRUCE, Vector3(80.0, 0.0, 16.0))
	_side(-20.0, 0.0, 16.0)
	fx.sync_all()
	assert_true(fx.settle())
	assert_eq(_owner_role(near.object_id), "mid")
	assert_eq(_owner_role(mid_range.object_id), "mid", "76 m away is still inside the 80 m detail radius")
	assert_eq(_owner_role(far.object_id), "far", "400 m away uses the far tier although group roles clamp to far")
	assert_eq(fx.world.cell_role(Vector2i(13, 0)), "far")
	var roles: Dictionary = fx.world.stats().cell_roles
	assert_eq(int(roles.get("mid", 0)), 2)
	assert_eq(int(roles.get("far", 0)), 1)


func test_role_changes_of_built_cells_wait_for_settled_navigation() -> void:
	fx.set_profile(fx.profile.merged({"settle_ms": 250}, true))
	var rec := fx.add(OverviewFixture.SPRUCE, Vector3(16.0, 0.0, 16.0))
	_side(-20.0, 0.0, 16.0)
	fx.sync_all()
	assert_true(fx.settle())
	assert_eq(_owner_role(rec.object_id), "mid")
	var moved_ms := Time.get_ticks_msec()
	_side(-300.0, 0.0, 16.0)
	fx.frame()
	assert_eq(fx.world.cell_wanted_role(Vector2i(0, 0)), "far", "evaluated at once")
	assert_eq(fx.world.cell_role(Vector2i(0, 0)), "mid", "but not applied while the camera is still settling")
	assert_eq(_owner_role(rec.object_id), "mid")
	assert_true(fx.world.has_pending_work(), "the change is pending")
	while Time.get_ticks_msec() - moved_ms < 240:
		fx.frame()
		assert_eq(_owner_role(rec.object_id), "mid", "unchanged before the settle delay")
		OS.delay_msec(5)
	assert_true(fx.settle())
	assert_eq(_owner_role(rec.object_id), "far")


func test_pinned_cells_keep_their_role_during_an_edit_and_change_after_release() -> void:
	var edited := fx.add(OverviewFixture.SPRUCE, Vector3(16.0, 0.0, 16.0))
	var other := fx.add(OverviewFixture.SPRUCE, Vector3(48.0, 0.0, 16.0))
	_side(-20.0, 0.0, 16.0)
	fx.sync_all()
	assert_true(fx.settle())
	var pinned := {Vector2i(0, 0): true}
	fx.presenter.set_pin_check(func(cell: Vector2i) -> bool: return pinned.has(cell))
	fx.pins = pinned
	_side(-300.0, 0.0, 16.0)
	assert_true(fx.run_until(func() -> bool: return _owner_role(other.object_id) == "far"), "the unpinned cell changes")
	assert_eq(_owner_role(edited.object_id), "mid", "the pinned cell keeps its tier")
	for i in 20:
		var rec := edited.clone()
		rec.set_position(16.0 + i * 0.5, 0.0, 16.0 + i * 0.25)
		fx.doc.put_object(rec)
		fx.sync(edited.object_id)
		fx.frame()
		var batch := fx.world.batch_of(edited.object_id)
		var local := batch.local_transform(batch.slot_of[edited.object_id])
		assert_vec_near(local.origin + batch.origin, fx.presenter.applied_transform(edited.object_id).origin, 1e-4, "transform updates while pinned")
	assert_eq(_owner_role(edited.object_id), "mid", "still the old tier after the edit")
	assert_eq(fx.world.cell_wanted_role(Vector2i(0, 0)), "far", "the wanted role is known")
	pinned.clear()
	fx.pins = {}
	assert_true(fx.settle())
	assert_eq(_owner_role(edited.object_id), "far", "applied once released")


func test_the_selected_object_stays_promoted_while_its_cell_changes_role() -> void:
	var a := fx.add(OverviewFixture.SPRUCE, Vector3(16.0, 0.0, 16.0))
	var b := fx.add(OverviewFixture.SPRUCE, Vector3(20.0, 0.0, 20.0))
	_side(-20.0, 0.0, 16.0)
	fx.sync_all()
	assert_true(fx.settle())
	fx.presenter.set_selected(a.object_id)
	assert_true(fx.settle())
	assert_eq(fx.world.owner_of(a.object_id), "promoted")
	_side(-300.0, 0.0, 16.0)
	assert_true(fx.settle())
	assert_eq(_owner_role(b.object_id), "far", "the neighbour changed")
	assert_eq(fx.world.owner_of(a.object_id), "promoted", "the selection stays promoted")
	assert_true(fx.presenter.node_for(a.object_id) != null)
	assert_eq(int(fx.world.stats().instances), 2, "one owner each")


func test_evaluation_is_chunked_nearest_first_and_idle_when_the_camera_rests() -> void:
	for ix in 25:
		for iz in 25:
			fx.add(OverviewFixture.SPRUCE, Vector3(-384.0 + ix * 32.0 + 16.0, 0.0, -384.0 + iz * 32.0 + 16.0))
	_side(-440.0, 0.0, -368.0)
	fx.sync_all()
	assert_true(fx.settle())
	var cells := 625
	var before := int(fx.world.stats().lod_evaluations)
	for i in 10:
		fx.frame()
	assert_eq(int(fx.world.stats().lod_evaluations), before, "a resting camera evaluates nothing")
	_side(380.0, 0.0, 368.0)
	var evaluated: Array[int] = []
	var last := before
	for i in 4:
		fx.presenter.service_frame(1.0)
		var now := int(fx.world.stats().lod_evaluations)
		evaluated.append(now - last)
		last = now
		if i == 0:
			assert_eq(fx.world.cell_wanted_role(Vector2i(11, 11)), "mid", "the cell nearest to the camera is in the first chunk")
	assert_true(evaluated.max() <= ObjectLodDirector.CHUNK, "at most %d cells per frame: %s" % [ObjectLodDirector.CHUNK, evaluated])
	assert_eq(evaluated.reduce(func(a: int, b: int) -> int: return a + b, 0), cells, "every cell once per pass")

	var t0 := Time.get_ticks_usec()
	var n := 200
	for i in n:
		_side(380.0 - i * 3.0, 0.0, 368.0)  # moves every frame: passes keep restarting
		fx.presenter.service_frame(1.0)
	var per_frame := float(Time.get_ticks_usec() - t0) / 1000.0 / n
	print("    LOD evaluation + service while the camera moves every frame (625 cells): %.3f ms/frame, %d cells evaluated" % [
			per_frame, int(fx.world.stats().lod_evaluations) - last])
	assert_true(per_frame < 8.0, "evaluation stays cheap (%.2f ms)" % per_frame)


func test_camera_jump_reprioritises_queued_builds_and_the_queue_stays_bounded() -> void:
	var ids := {}
	for ix in 20:
		for iz in 20:
			var rec := fx.add(OverviewFixture.SPRUCE, Vector3(-320.0 + ix * 32.0 + 16.0, 0.0, -320.0 + iz * 32.0 + 16.0))
			ids[rec.object_id] = Vector2(rec.position[0], rec.position[2])
	fx.aim(Vector3(-300.0, 60.0, -300.0), Vector3(-300.0, 0.0, -300.0))
	fx.sync_all()
	var queue_max := int(fx.world.stats().pending_builds)
	var built := {}
	var pre_order: Array[Vector2] = []
	var post_order: Array[Vector2] = []
	var jumped := false
	for frame in 2000:
		fx.presenter.service_frame(0.0)
		queue_max = maxi(queue_max, int(fx.world.stats().pending_builds))
		for id: String in ids:
			if not built.has(id) and fx.world.owner_of(id) != "":
				built[id] = true
				(post_order if jumped else pre_order).append(ids[id])
		if not jumped and built.size() >= 40:
			jumped = true
			fx.aim(Vector3(300.0, 60.0, 300.0), Vector3(300.0, 0.0, 300.0))
		if built.size() == ids.size() and not fx.presenter.has_pending_work():
			break
	assert_true(queue_max <= 400, "the queue never exceeds the distinct (cell, asset) groups: %d" % queue_max)
	assert_eq(built.size(), 400, "everything is eventually built")
	assert_true(pre_order.size() >= 40 and post_order.size() > 100)
	var corner := Vector2(300.0, 300.0)
	var near_new: Array[Vector2] = []
	var by_distance := ids.values()
	by_distance.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.distance_to(corner) < b.distance_to(corner))
	for i in 40:
		near_new.append(by_distance[i])
	var hits := 0
	for i in 20:
		hits += 1 if near_new.has(post_order[i]) else 0
	assert_true(hits >= 18, "the first builds after the jump are around the new focus (%d of 20 in its 40 nearest cells)" % hits)
	var mean_pre := 0.0
	for p in pre_order.slice(0, 40):
		mean_pre += p.distance_to(Vector2(-300.0, -300.0)) / 40.0
	var mean_post := 0.0
	for p in post_order.slice(0, 20):
		mean_post += p.distance_to(corner) / 20.0
	assert_true(mean_post < 150.0 and mean_pre < 150.0, "both phases build near their focus (%.0f / %.0f m)" % [mean_pre, mean_post])


func test_repeated_travel_between_two_distant_areas_converges() -> void:
	fx.add_patches(8, 220, 40.0, 10.0)
	var centres: Array[Vector3] = []
	for id in fx.doc.sorted_object_ids():
		var p := fx.doc.get_object(id).get_position_v3()
		if centres.is_empty() or (centres.size() == 1 and Vector2(p.x, p.z).distance_to(Vector2(centres[0].x, centres[0].z)) > 400.0):
			centres.append(p)
	assert_eq(centres.size(), 2, "two areas far apart")
	fx.sync_all()
	var samples: Array[Dictionary] = []
	var cache := fx.presenter._cache
	for cycle in 20:
		for area in 2:
			fx.aim(centres[area] + Vector3(0.0, 55.0, 25.0), centres[area])
			assert_true(fx.settle(), "cycle %d area %d settles" % [cycle, area])
		var render := fx.world.stats()
		var ov := fx.overview.stats()
		var cs := cache.stats()
		samples.append({"entries": int(cs.entries), "bytes": int(cs.resident_bytes), "batches": int(render.batches),
			"nodes": fx.overview.get_child_count(), "built": int(ov.built), "groups": int(ov.groups), "pending": int(render.pending_builds)})
	print("    travel A<->B x20: cache entries %d, bytes %d, batches %d, proxy nodes %d, groups built %d" % [
			samples[19].entries, samples[19].bytes, samples[19].batches, samples[19].nodes, samples[19].built])
	for key in ["entries", "bytes", "batches", "nodes", "built"]:
		var steady: int = samples[4][key]
		for cycle in range(5, 20):
			assert_true(int(samples[cycle][key]) <= steady, "%s stops growing: cycle %d has %d > %d" % [key, cycle, int(samples[cycle][key]), steady])
	assert_eq(int(samples[19].pending), 0)
