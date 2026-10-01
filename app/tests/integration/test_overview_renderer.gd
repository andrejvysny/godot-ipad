extends TestCase
## OverviewRenderer on a 1 km world (spec §9, §15.1, §21.2): LOD-03 hierarchy cut, LOD-04 invalidation per group,
## LOD-05 top-down proxies, PICK-03 area focus, vegetation hiding, pins and selection, world replacement.
## Host (desktop) evidence only.

var fx: OverviewFixture


func after_each() -> void:
	if fx != null:
		fx.release()
		fx = null


## Camera straight above (x, z) at height `h`.
func _top(x: float, z: float, h: float) -> void:
	fx.aim(Vector3(x, h, z), Vector3(x, 0.0, z))


## No visible individual batch lies inside the rect of an active group, and no active group has a parent or a
## child that is active too; every active group is current (never a stale proxy).
func _assert_cut_is_clean(what: String) -> void:
	var active := fx.active_groups()
	for g: OverviewGroup in active:
		assert_true(g.current and not g.invalidated, "%s: active group %s is current" % [what, g.key])
		for k: OverviewGroup in active:
			if k.level < g.level:
				assert_false(g.rect.encloses(k.rect), "%s: no active %d m group under an active %d m group" % [what, k.level_m, g.level_m])
	for cell: RenderCell in fx.world._cells.values():
		for batch: InstanceBatch in cell.batches.values():
			if not batch.node.visible:
				continue
			for g: OverviewGroup in active:
				assert_false(g.rect.has_point(Vector2(cell.origin.x, cell.origin.z)),
						"%s: visible batch %s inside active group %s" % [what, cell.key, g.key])


func _assert_every_object_once(what: String) -> void:
	assert_eq(fx.proxied_members() + fx.visible_individuals(), fx.total_objects(), what + ": proxy members + individuals == objects")


func test_overview_distance_represents_every_object_exactly_once() -> void:
	fx = OverviewFixture.new(tree)
	fx.add_patches(20, 250, 45.0, 0.0)
	assert_eq(fx.total_objects(), 5000)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle(), "everything built and activated")
	var stats := fx.overview.stats()
	assert_eq(int(stats.active.get(256, 0)), 16, "the whole km1 is 16 groups of 256 m")
	assert_eq(int(stats.active.get(128, 0)), 0, "children are never active together with their parent")
	assert_eq(fx.visible_individuals(), 0, "every cell is covered")
	_assert_every_object_once("overview")
	_assert_cut_is_clean("overview")
	assert_true(int(stats.proxy_triangles) > 0 and int(stats.proxy_triangles) < 400000, "proxy triangles %d" % int(stats.proxy_triangles))

	_top(60.0, 40.0, 130.0)
	var mixed := fx.run_until(func() -> bool:
		_assert_cut_is_clean("moving")
		return not fx.busy())
	assert_true(mixed)
	fx.settle()
	var counts := fx.overview.stats()
	assert_true(int(counts.active.get(128, 0)) + int(counts.active.get(256, 0)) > 0, "far groups stay grouped")
	assert_true(fx.visible_individuals() > 0, "near cells are individual")
	_assert_every_object_once("mixed")
	_assert_cut_is_clean("mixed")
	for g: OverviewGroup in fx.active_groups():
		assert_true(g.group_level >= g.level, "an active group is wanted at its own level")


func test_a_blocked_child_splits_its_parent_and_siblings_take_over() -> void:
	fx = OverviewFixture.new(tree, Rect2(-256.0, -256.0, 512.0, 512.0))
	fx.add_patches(8, 120, 30.0, 0.0)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	var parent: OverviewGroup = null
	for g: OverviewGroup in fx.overview.groups(1):
		if g.active and g.members > 0:
			parent = g
	if not assert_true(parent != null, "an active 256 m group with objects"):
		return
	var kids: Array[OverviewGroup] = []
	for k: OverviewGroup in fx.overview.groups(0):
		if parent.rect.encloses(k.rect):
			kids.append(k)
	assert_eq(kids.size(), 4)
	fx.pins = {Vector2i(floori(kids[0].rect.position.x / 32.0), floori(kids[0].rect.position.y / 32.0)): true}
	fx.frame()
	assert_false(parent.active, "the parent is retired in the same frame as the pin")
	assert_false(kids[0].active, "the pinned child is individual")
	for i in range(1, 4):
		assert_true(kids[i].active, "unblocked sibling %d takes over at once" % i)
	_assert_every_object_once("split")
	_assert_cut_is_clean("split")
	fx.pins = {}
	assert_true(fx.settle())
	assert_true(parent.active and not kids[1].active, "released: the parent returns")
	_assert_every_object_once("merged")


func test_moving_or_deleting_one_object_invalidates_only_its_group_branch() -> void:
	fx = OverviewFixture.new(tree)
	var centres := fx.add_patches(6, 150, 40.0, 0.0)
	_top(0.0, 0.0, 1200.0)
	fx.sync_all()
	assert_true(fx.settle())
	_assert_every_object_once("start")
	var victim_id := ""
	for id in fx.doc.sorted_object_ids():
		var p := fx.doc.get_object(id).get_position_v3()
		if Vector2(p.x, p.z).distance_to(Vector2(centres[0].x, centres[0].z)) < 10.0:
			victim_id = id
			break
	var rec := fx.doc.get_object(victim_id)
	var gens := {}
	for lvl in 2:
		for g: OverviewGroup in fx.overview.groups(lvl):
			gens[g] = g.gen
	var moved := rec.clone()
	var p0 := rec.get_position_v3()
	moved.set_position(p0.x, p0.y + 3.0, p0.z)  # a re-grounding inside the same cell
	fx.doc.put_object(moved)
	fx.sync(victim_id)
	var inactive := 0
	for lvl in 2:
		for g: OverviewGroup in fx.overview.groups(lvl):
			var hit := g.rect.has_point(Vector2(p0.x, p0.z))
			if hit:
				assert_false(g.active, "the group of the edit is retired at once (level %d)" % lvl)
				assert_false(g.current, "its old proxy is dropped")
				inactive += 1
			else:
				assert_eq(g.gen, gens[g], "distant group %s untouched" % g.key)
	assert_eq(inactive, 2, "exactly the 128 m group and its 256 m parent")
	assert_eq(fx.visible_individuals() > 0, true, "the affected cells show their individual representation")
	_assert_every_object_once("after edit")
	assert_true(fx.run_until(func() -> bool:
		_assert_cut_is_clean("rebuilding")
		return not fx.busy()))
	fx.settle()
	_assert_every_object_once("rebuilt")

	var far_cell := Vector3(p0.x + 200.0, p0.y, p0.z) if p0.x < 200.0 else Vector3(p0.x - 200.0, p0.y, p0.z)
	var teleported := rec.clone()
	teleported.set_position(far_cell.x, far_cell.y, far_cell.z)
	fx.doc.put_object(teleported)
	fx.sync(victim_id)
	var retired := 0
	for lvl in 2:
		for g: OverviewGroup in fx.overview.groups(lvl):
			if g.rect.has_point(Vector2(p0.x, p0.z)) or g.rect.has_point(Vector2(far_cell.x, far_cell.z)):
				assert_false(g.active)
				retired += 1
	assert_true(retired >= 3 and retired <= 4, "old and new branch only (%d groups)" % retired)
	assert_true(fx.settle())
	_assert_every_object_once("moved across groups")

	fx.doc.remove_object(victim_id)
	fx.sync(victim_id)
	assert_true(fx.settle())
	_assert_every_object_once("deleted")
	assert_eq(fx.total_objects(), 900 - 1)


func test_a_build_in_flight_when_an_edit_arrives_is_discarded() -> void:
	fx = OverviewFixture.new(tree, Rect2(-256.0, -256.0, 512.0, 512.0))
	fx.add_patches(4, 100, 30.0, 0.0)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	var ids := fx.doc.sorted_object_ids()
	var state := {"edits": 0}  # lambdas capture ints by value
	var edit_while_building := func() -> bool:
		if int(state.edits) < 12:
			var rec := fx.doc.get_object(ids[int(state.edits) * 7])
			var moved := rec.clone()
			var pos := rec.get_position_v3()
			moved.set_position(pos.x, pos.y + 1.0, pos.z)
			fx.doc.put_object(moved)
			fx.sync(rec.object_id)
			state.edits = int(state.edits) + 1
		return int(state.edits) >= 12
	assert_true(fx.run_until(edit_while_building, 4000))
	assert_true(fx.settle())
	_assert_every_object_once("after edits during builds")
	_assert_cut_is_clean("after edits during builds")


func test_top_down_proxy_meshes_cover_every_occupied_cell_and_keep_clearings() -> void:
	fx = OverviewFixture.new(tree, Rect2(-128.0, -128.0, 256.0, 256.0))
	var centre := Vector3(-64.0, 0.0, -64.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in 1500:
		var p := centre + Vector3(rng.randf_range(-60.0, 60.0), 0.0, rng.randf_range(-60.0, 60.0))
		if absf(p.x - centre.x) < 20.0 and absf(p.z - centre.z) < 20.0:
			continue
		fx.add(OverviewFixture.SPRUCE, p, rng.randf() * TAU, rng.randf_range(0.8, 1.3))
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	var g := fx.overview.group(0, Vector2i(-1, -1))
	assert_true(g != null and g.members > 1000, "the forest group")
	assert_true(g.active or fx.overview.group(1, Vector2i(-1, -1)).active)
	var arrays := g.canopy.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var up_cells := {}
	for t in range(0, idx.size(), 3):
		var face := (v[idx[t + 2]] - v[idx[t]]).cross(v[idx[t + 1]] - v[idx[t]])
		if face.normalized().y > 0.5:
			var c := (v[idx[t]] + v[idx[t + 1]] + v[idx[t + 2]]) / 3.0 + g.canopy.position
			up_cells[Vector2i(floori(c.x / 4.0), floori(c.z / 4.0))] = true
	for id in fx.doc.sorted_object_ids():
		var p := fx.doc.get_object(id).get_position_v3()
		assert_true(up_cells.has(Vector2i(floori(p.x / 4.0), floori(p.z / 4.0))), "an upward triangle over %s" % str(p))
	for cell: Vector2i in up_cells:
		var cx := (cell.x + 0.5) * 4.0
		var cz := (cell.y + 0.5) * 4.0
		assert_false(absf(cx - centre.x) < 15.0 and absf(cz - centre.z) < 15.0, "no geometry in the clearing at %s" % cell)


func test_tap_on_an_active_group_returns_an_area_and_never_a_hidden_object() -> void:
	fx = OverviewFixture.new(tree)
	var spruce := fx.add(OverviewFixture.SPRUCE, Vector3(100.0, 0.0, 100.0))
	for i in 40:
		fx.add(OverviewFixture.SPRUCE, Vector3(100.0 + (i % 8) * 3.0, 0.0, 100.0 + (i / 8) * 3.0))
	_top(100.0, 100.0, 1400.0)
	fx.sync_all()
	assert_true(fx.settle())
	var top := Vector3(100.0, 1400.0, 100.0)
	assert_eq(fx.presenter.pick(top, Vector3.DOWN).id, "", "objects under a group are not individually pickable")
	var hit := fx.overview.pick(top, Vector3.DOWN)
	assert_false(hit.is_empty(), "the proxy is hit")
	assert_true((hit.area as AABB).has_point(Vector3(100.0, 3.0, 100.0)), "the area is the hit group's box")
	assert_true(hit.distance > 1300.0 and hit.distance < 1400.0)
	assert_true(fx.overview.pick(Vector3(-400.0, 1400.0, 300.0), Vector3.DOWN).is_empty(), "nothing over an empty area")

	var ctx := ToolContext.new()
	ctx.camera = fx.camera
	ctx.presenter = fx.presenter
	ctx.document = fx.doc
	ctx.units_per_point = func() -> float: return 1.0
	ctx.area_pick = fx.overview.pick
	var focused: Array = []
	ctx.focus_area = func(area: AABB) -> void: focused.append(area)
	var op := SelectOperation.new(ctx, false, "")
	var s := PointerSample.new()
	s.position_viewport = fx.camera.get_viewport().get_visible_rect().size * 0.5
	op.begin(s, TerrainHit.miss("test"))
	op.end(s, TerrainHit.miss("test"), false)
	assert_eq(focused.size(), 1, "the tap focuses the area")
	assert_true(op.tap_selection() == null, "and selects nothing, so the selection is unchanged")
	assert_true((focused[0] as AABB).has_point(Vector3(100.0, 3.0, 100.0)))

	fx.camera.global_position = Vector3(100.0, 25.0, 130.0)
	fx.camera.look_at(Vector3(100.0, 0.0, 100.0), Vector3.UP)
	assert_true(fx.settle())
	assert_true(fx.overview.pick(Vector3(100.0, 400.0, 100.0), Vector3.DOWN).is_empty(), "no proxy once the cells are individual")
	assert_ne(fx.presenter.pick(Vector3(100.0, 400.0, 100.0), Vector3.DOWN).id, "", "individual objects pick again")
	assert_true(spruce.object_id != "")


func test_the_selected_object_keeps_its_group_individual_while_zooming_out() -> void:
	fx = OverviewFixture.new(tree, Rect2(-256.0, -256.0, 512.0, 512.0))
	var picked := fx.add(OverviewFixture.SPRUCE, Vector3(100.0, 0.0, 100.0))
	for i in 30:
		fx.add(OverviewFixture.SPRUCE, Vector3(-150.0 + i * 3.0, 0.0, -150.0))
	fx.aim(Vector3(100.0, 60.0, 130.0), Vector3(100.0, 0.0, 100.0))
	fx.sync_all()
	assert_true(fx.settle())
	fx.presenter.set_selected(picked.object_id)
	fx.selected = fx.presenter.world_bounds(picked.object_id)
	_top(0.0, 0.0, 1600.0)
	assert_true(fx.settle())
	var home := fx.overview.group(1, Vector2i(0, 0))
	assert_false(home.active, "the group of the selection stays individual")
	assert_true(fx.overview.group(1, Vector2i(-1, -1)).active, "other groups are grouped")
	assert_eq(fx.world.owner_of(picked.object_id), "promoted", "and the selection is drawn")
	assert_false(fx.world.is_object_covered(picked.object_id))
	_assert_every_object_once("with a selection")
	fx.presenter.set_selected("")
	fx.selected = AABB()
	assert_true(fx.settle())
	assert_true(home.active, "deselecting lets the group form again")
	_assert_every_object_once("deselected")


func test_vegetation_hiding_hides_canopy_proxies_only() -> void:
	fx = OverviewFixture.new(tree, Rect2(-256.0, -256.0, 512.0, 512.0))
	for i in 60:
		fx.add(OverviewFixture.SPRUCE, Vector3(-100.0 + (i % 10) * 3.0, 0.0, -100.0 + (i / 10) * 3.0))
	fx.add(OverviewFixture.CABIN, Vector3(-80.0, 0.0, -60.0))
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	var g: OverviewGroup = null
	for candidate: OverviewGroup in fx.active_groups():
		if candidate.members > 0:
			g = candidate
	if not assert_true(g != null and g.canopy != null and g.solid != null, "an active group with both meshes"):
		return
	assert_true(g.canopy.visible and g.solid.visible)
	var top := Vector3(-97.0, 1400.0, -97.0)
	assert_false(fx.overview.pick(top, Vector3.DOWN).is_empty(), "canopy lobes are pickable while shown")
	fx.overview.set_vegetation_hidden(true)
	assert_false(g.canopy.visible, "canopy proxy hidden")
	assert_true(g.solid.visible, "solids stay")
	assert_true(fx.overview.pick(top, Vector3.DOWN).is_empty(), "hidden canopy is not pickable")
	fx.overview.set_vegetation_hidden(false)
	assert_true(g.canopy.visible)


func test_world_replacement_reveals_every_cell_and_discards_old_builds() -> void:
	fx = OverviewFixture.new(tree, Rect2(-256.0, -256.0, 512.0, 512.0))
	fx.add_patches(4, 100, 30.0, 0.0)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	assert_true(fx.active_groups().size() > 0)
	fx.doc = WorldDocument.new()
	fx.sync_all()
	assert_eq(fx.active_groups().size(), 0, "every group is retired with the world")
	assert_eq(fx.world.covered_cell_count(), 0, "no cell stays covered")
	assert_eq(int(fx.world.stats().instances), 0)
	fx.overview.set_world_rect(Rect2(-256.0, -256.0, 512.0, 512.0))
	assert_eq(int(fx.overview.stats().built), 0, "no proxy survives the new world")
	fx.add(OverviewFixture.SPRUCE, Vector3(10.0, 0.0, 10.0))
	fx.sync_all()
	assert_true(fx.settle())
	assert_eq(fx.proxied_members(), 1, "the new world's single object is represented once")
	assert_eq(fx.visible_individuals(), 0)


# --- Three levels (64 / 128 / 256 m) ----------------------------------------------------------

const L3 := [64.0, 128.0, 256.0]


func _fx3(rect: Rect2 = Rect2(-256.0, -256.0, 512.0, 512.0)) -> OverviewFixture:
	return OverviewFixture.new(tree, rect, PackedFloat32Array(L3))


func _active_by_level() -> Dictionary:
	return fx.overview.stats().active


func test_three_levels_represent_every_object_exactly_once_across_the_cut() -> void:
	fx = _fx3(OverviewFixture.WORLD)
	fx.add_patches(20, 250, 45.0, 0.0)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	var stats := fx.overview.stats()
	assert_eq(int(stats.active.get(256, 0)), 16, "the whole km1 is 16 groups of 256 m")
	assert_eq(int(stats.active.get(128, 0)) + int(stats.active.get(64, 0)), 0, "no descendant under an active group")
	assert_eq(fx.visible_individuals(), 0)
	_assert_every_object_once("overview")
	_assert_cut_is_clean("overview")
	var mixed_levels := {}
	for step in [Vector3(60.0, 0.0, 40.0), Vector3(-200.0, 0.0, 120.0), Vector3(150.0, 0.0, -180.0)]:
		_top(step.x, step.z, 70.0)
		assert_true(fx.run_until(func() -> bool:
			_assert_cut_is_clean("moving")
			return not fx.busy()))
		fx.settle()
		_assert_every_object_once("mixed at %s" % str(step))
		_assert_cut_is_clean("mixed")
		assert_true(fx.visible_individuals() > 0, "near cells are individual")
		for g: OverviewGroup in fx.active_groups():
			mixed_levels[g.level] = true
			assert_true(g.group_level >= g.level)
	assert_true(mixed_levels.has(0) and mixed_levels.has(1), "the 64 m and 128 m levels take part in the cut")


func test_blocked_groups_at_each_level_split_their_ancestors_and_siblings_take_over() -> void:
	fx = _fx3()
	fx.add_patches(10, 120, 28.0, 0.0)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	var top: OverviewGroup = fx.overview.group(2, Vector2i(0, 0))
	assert_true(top.active, "the 256 m group over the origin quadrant is grouped")
	var kids128: Array[OverviewGroup] = []
	var kids64: Array[OverviewGroup] = []
	for g: OverviewGroup in fx.overview.groups(1):
		if top.rect.encloses(g.rect):
			kids128.append(g)
	for g: OverviewGroup in fx.overview.groups(0):
		if kids128[0].rect.encloses(g.rect):
			kids64.append(g)
	assert_eq(kids128.size(), 4)
	assert_eq(kids64.size(), 4)
	for g: OverviewGroup in kids128:
		assert_true(g.current, "128 m proxies are prefetched")
	for g: OverviewGroup in kids64:
		assert_true(g.current, "64 m proxies are prefetched")
	fx.pins = {Vector2i(floori(kids64[0].rect.position.x / 32.0), floori(kids64[0].rect.position.y / 32.0)): true}
	fx.frame()
	assert_false(top.active, "the 256 m group is retired in the frame of the pin")
	assert_false(kids128[0].active, "the 128 m group holding the pin is retired too")
	assert_false(kids64[0].active, "the pinned 64 m group is individual")
	for i in range(1, 4):
		assert_true(kids128[i].active, "unblocked 128 m sibling %d takes over at once" % i)
		assert_true(kids64[i].active, "unblocked 64 m sibling %d takes over at once" % i)
	_assert_every_object_once("split at level 0")
	_assert_cut_is_clean("split at level 0")
	fx.pins = {}
	assert_true(fx.settle())
	assert_true(top.active and not kids128[1].active and not kids64[1].active, "released: the top group returns")
	_assert_every_object_once("merged")

	var target: OverviewGroup = kids128[1]
	var inside: Array[OverviewGroup] = []
	for g: OverviewGroup in fx.overview.groups(0):
		if target.rect.encloses(g.rect):
			inside.append(g)
	fx.selected = AABB(Vector3(inside[0].rect.get_center().x - 5.0, 0.0, inside[0].rect.get_center().y - 5.0), Vector3(10.0, 5.0, 10.0))
	fx.frame()
	assert_false(top.active and kids128[1].active, "a selection splits its ancestors")
	assert_false(kids64[1].active)
	assert_true(kids128[2].active, "other 128 m groups take over")
	_assert_every_object_once("selection split")
	_assert_cut_is_clean("selection split")
	fx.selected = AABB()
	assert_true(fx.settle())
	assert_true(top.active)


func test_an_edit_deactivates_its_group_and_every_ancestor_only() -> void:
	fx = _fx3(OverviewFixture.WORLD)
	var centres := fx.add_patches(6, 150, 40.0, 0.0)
	_top(0.0, 0.0, 1400.0)
	fx.sync_all()
	assert_true(fx.settle())
	_assert_every_object_once("start")
	var victim_id := ""
	for id in fx.doc.sorted_object_ids():
		var p := fx.doc.get_object(id).get_position_v3()
		if Vector2(p.x, p.z).distance_to(Vector2(centres[0].x, centres[0].z)) < 10.0:
			victim_id = id
			break
	var rec := fx.doc.get_object(victim_id)
	var gens := {}
	for lvl in 3:
		for g: OverviewGroup in fx.overview.groups(lvl):
			gens[g] = g.gen
	var moved := rec.clone()
	var p0 := rec.get_position_v3()
	moved.set_position(p0.x, p0.y + 3.0, p0.z)
	fx.doc.put_object(moved)
	fx.sync(victim_id)
	var touched := 0
	for lvl in 3:
		for g: OverviewGroup in fx.overview.groups(lvl):
			if g.rect.has_point(Vector2(p0.x, p0.z)):
				assert_false(g.active, "the %d m group of the edit is retired at once" % g.level_m)
				assert_false(g.current, "its old proxy is dropped")
				assert_ne(g.gen, gens[g])
				touched += 1
			else:
				assert_eq(g.gen, gens[g], "%d m group %s untouched" % [g.level_m, g.key])
	assert_eq(touched, 3, "the 64 m group and its 128 m and 256 m ancestors")
	_assert_every_object_once("after edit")
	assert_true(fx.run_until(func() -> bool:
		_assert_cut_is_clean("rebuilding")
		return not fx.busy()))
	fx.settle()
	_assert_every_object_once("rebuilt")
	assert_eq(int(_active_by_level().get(256, 0)), 16, "the whole world is grouped again")


func test_top_down_64_m_proxies_use_a_4_m_grid_and_keep_clearings() -> void:
	fx = _fx3(Rect2(-128.0, -128.0, 256.0, 256.0))
	var centre := Vector3(-32.0, 0.0, -32.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 78
	for i in 700:
		var p := centre + Vector3(rng.randf_range(-30.0, 30.0), 0.0, rng.randf_range(-30.0, 30.0))
		if absf(p.x - centre.x) < 10.0 and absf(p.z - centre.z) < 10.0:
			continue
		fx.add(OverviewFixture.SPRUCE, p, rng.randf() * TAU, rng.randf_range(0.8, 1.3))
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	assert_true(fx.settle())
	var g := fx.overview.group(0, Vector2i(-1, -1))
	assert_eq(g.level_m, 64.0)
	assert_true(g.members > 600 and g.canopy != null, "the forest group")
	var arrays := g.canopy.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var up_cells := {}
	for t in range(0, idx.size(), 3):
		var face := (v[idx[t + 2]] - v[idx[t]]).cross(v[idx[t + 1]] - v[idx[t]])
		if face.normalized().y > 0.5:
			var c := (v[idx[t]] + v[idx[t + 1]] + v[idx[t + 2]]) / 3.0 + g.canopy.position
			up_cells[Vector2i(floori(c.x / 4.0), floori(c.z / 4.0))] = true
	for id in fx.doc.sorted_object_ids():
		var p := fx.doc.get_object(id).get_position_v3()
		assert_true(up_cells.has(Vector2i(floori(p.x / 4.0), floori(p.z / 4.0))), "an upward triangle over %s" % str(p))
	for cell: Vector2i in up_cells:
		var cx := (cell.x + 0.5) * 4.0
		var cz := (cell.y + 0.5) * 4.0
		assert_false(absf(cx - centre.x) < 7.0 and absf(cz - centre.z) < 7.0, "no geometry in the clearing at %s" % cell)
	assert_true(g.lobes <= OverviewClusterBuilder.MAX_LOBES)


func _three_level_signature() -> Dictionary:
	fx = _fx3(Rect2(-256.0, -256.0, 512.0, 512.0))
	fx.add_patches(6, 150, 30.0, 0.0)
	_top(0.0, 0.0, 1600.0)
	fx.sync_all()
	fx.settle()
	_top(40.0, 20.0, 300.0)
	fx.settle()
	var s := fx.overview.stats()
	var sig := {"active": (s.active as Dictionary).duplicate(), "built": s.built, "proxy": s.proxy_triangles,
		"all": s.built_triangles, "covered": s.cells_covered, "individuals": fx.visible_individuals()}
	fx.release()
	fx = null
	return sig


func test_three_level_results_are_deterministic() -> void:
	var a := _three_level_signature()
	var b := _three_level_signature()
	assert_eq(a, b, "two identical runs give identical cuts and proxies")
	assert_true(int(a.proxy) > 0)


func test_measurements_for_a_km1_world_with_50000_objects() -> void:
	for levels: Array in [[128.0, 256.0], L3]:
		print("    --- overview levels %s ---" % str(levels))
		_measure_50000(PackedFloat32Array(levels))
		fx.release()
		fx = null


func _measure_50000(levels: PackedFloat32Array) -> void:
	fx = OverviewFixture.new(tree, OverviewFixture.WORLD, levels)
	var t0 := Time.get_ticks_usec()
	fx.add_patches(50, 1000, 70.0, 20.0)
	print("    build 50,000 records in 50 patches with clearings: %.0f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	assert_eq(fx.total_objects(), 50000)
	_top(0.0, 0.0, 1600.0)
	t0 = Time.get_ticks_usec()
	fx.sync_all()
	print("    presenter rebuild (50,000 upserts): %.0f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	var worst_service := 0.0
	var total_service := 0.0
	var frames := 0
	var done := false
	while not done and Time.get_ticks_usec() - t0 < 180000000:
		fx.presenter.service_frame(1.0)
		var f0 := Time.get_ticks_usec()
		fx.overview.set_blockers(fx.pins, fx.selected)
		fx.overview.service(fx.camera)
		var ms := float(Time.get_ticks_usec() - f0) / 1000.0
		worst_service = maxf(worst_service, ms)
		total_service += ms
		frames += 1
		done = not fx.busy()
		OS.delay_msec(1)
	assert_true(done, "50,000 objects settle")
	var s := fx.overview.stats()
	print("    settle to the whole-world overview: %.0f ms, %d frames" % [float(Time.get_ticks_usec() - t0) / 1000.0, frames])
	print("    overview: %d groups built, active %s, proxy triangles %d (all built groups %d), cells covered %d" % [
			int(s.built), str(s.active), int(s.proxy_triangles), int(s.built_triangles), int(s.cells_covered)])
	print("    overview service per frame: mean %.3f ms, worst %.3f ms; worker build per group: last %.1f ms, max %.1f ms; main-thread mesh creation: last %.2f ms, max %.2f ms" % [
			total_service / maxf(frames, 1), worst_service, float(s.last_worker_ms), float(s.max_worker_ms), float(s.last_mesh_ms), float(s.max_mesh_ms)])
	var render := fx.world.stats()
	print("    individual instances visible at overview distance: %d of %d (batches %d)" % [int(render.visible_instances), fx.total_objects(), int(render.batches)])
	assert_eq(fx.visible_individuals(), 0)
	assert_eq(fx.proxied_members(), 50000)
	assert_true(int(s.proxy_triangles) < 1000000, "proxy triangles stay in the workload budget")
	var t1 := Time.get_ticks_usec()
	for i in 200:
		fx.overview.set_blockers(fx.pins, fx.selected)
		fx.overview.service(fx.camera)
	print("    settled overview service (no change): %.3f ms/frame" % (float(Time.get_ticks_usec() - t1) / 200000.0))
