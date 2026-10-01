extends TestCase
## ObjectRenderWorld through ObjectPresenter (spec §7, §8.3): BATCH-03..08, EDIT-01..04, LOD-02, ASSET-01.

const BOULDER := "nature.rock.boulder_a"
const LODGE := "built.lodge.cabin_a"
const SPRUCE := "nature.tree.spruce_a"

var catalog: AssetCatalog
var doc: WorldDocument
var presenter: ObjectPresenter
var world: ObjectRenderWorld
var _extra: Array[ObjectPresenter] = []


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	doc = WorldDocument.new()
	presenter = _make(null)
	world = presenter.render_world()


func after_each() -> void:
	presenter = null
	for p in _extra:
		if is_instance_valid(p):
			tree.root.remove_child(p)
			p.free()
	_extra.clear()


func _make(registry: RenderAssetRegistry) -> ObjectPresenter:
	var p := ObjectPresenter.new()
	p.setup(catalog, registry)
	tree.root.add_child(p)
	_extra.append(p)
	return p


func _add(asset_id: String, pos: Vector3, yaw: float = 0.0, scale: float = 1.0) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.asset_id = asset_id
	r.asset_version = 1
	r.set_position(pos.x, pos.y, pos.z)
	r.set_yaw(yaw)
	r.uniform_scale = scale
	doc.put_object(r)
	return r


func _settle() -> void:
	assert_true(presenter.settle_now(), "render work settles")


func _slot_world(id: String) -> Transform3D:
	var b := world.batch_of(id)
	var local := b.local_transform(b.slot_of[id])
	return Transform3D(local.basis, local.origin + b.origin)


## Every presented record has exactly one visible owner whose transform equals the applied transform.
func _assert_consistent(msg: String) -> void:
	var ids := doc.sorted_object_ids()
	assert_eq(presenter.object_ids(), PackedStringArray(ids), msg + ": presented ids == document ids")
	assert_eq(int(world.stats().instances), ids.size(), msg + ": one instance per record")
	for id in ids:
		var applied := presenter.applied_transform(id)
		var batch := world.batch_of(id)
		var node := presenter.node_for(id)
		assert_true((batch != null) != (node != null), msg + ": exactly one owner of " + id.left(6))
		if world.owner_of(id).ends_with("placeholder") or (node != null and world.promoted_rep() == "placeholder"):
			continue
		var got := _slot_world(id) if batch != null else node.transform
		assert_vec_near(got.origin, applied.origin, 1e-4, msg + ": origin")
		assert_true(got.basis.is_equal_approx(applied.basis), msg + ": basis")


func test_two_surface_spruce_is_one_slot_in_one_batch() -> void:
	var r := _add(SPRUCE, Vector3(5, 0, 5))
	presenter.rebuild(doc)
	_settle()
	var stats := world.stats()
	assert_eq(stats.batches, 1)
	assert_eq(stats.instances, 1)
	var batch := world.batch_of(r.object_id)
	assert_eq(batch.count, 1)
	assert_eq(batch.multimesh().mesh.get_surface_count(), 2, "both surfaces draw through the one instance")
	assert_eq(world.owner_of(r.object_id), SPRUCE + "|mid", "the Performance default role")
	assert_eq(stats.estimated_triangles, 152)
	_assert_consistent("spruce")


func test_selection_promotion_has_one_owner_at_every_step() -> void:
	var a := _add(SPRUCE, Vector3(5, 0, 5), 0.4, 1.5)
	var b := _add(SPRUCE, Vector3(9, 0, 5))
	var c := _add(BOULDER, Vector3(40, 0, 5))
	presenter.rebuild(doc)
	_settle()
	_assert_consistent("settled")
	presenter.set_selected(a.object_id)
	assert_true(presenter.node_for(a.object_id) != null, "promoted at once")
	assert_eq(world.stats().promoted, 1)
	_assert_consistent("a selected")
	_settle()
	var node := presenter.node_for(a.object_id)
	var d := presenter.render_world()._res.registry.descriptor(SPRUCE)
	assert_eq(world.promoted_rep(), "selected")
	assert_eq(node.mesh.resource_path, d.dependency(d.resolve_role("selected")).path, "the selected tier mesh")
	assert_eq(node.mesh.get_surface_count(), int(d.roles.selected.surfaces), "material slots preserved")
	assert_vec_near(presenter.anchor_position(a.object_id), a.get_position_v3(), 1e-4, "anchor preserved")
	presenter.set_selected(b.object_id)
	assert_true(world.batch_of(a.object_id) != null, "the previous selection returns to its batch")
	assert_true(presenter.node_for(b.object_id) == node, "the pooled node is reused")
	_assert_consistent("b selected")
	presenter.set_selected("")
	assert_eq(world.stats().promoted, 0)
	assert_true(world.promoted_node() == null)
	_assert_consistent("deselected")
	presenter.set_selected(c.object_id)
	_assert_consistent("boulder selected")
	presenter.set_selected(a.object_id)
	_settle()
	_assert_consistent("reselected")
	assert_eq(world.promoted_rep(), "selected")


func test_dragging_the_selection_allocates_nothing() -> void:
	var r := _add(SPRUCE, Vector3(5, 0, 5))
	_add(SPRUCE, Vector3(9, 0, 9))
	presenter.rebuild(doc)
	presenter.set_selected(r.object_id)
	_settle()
	var node := presenter.node_for(r.object_id)
	var mesh := node.mesh
	var builds := int(world.stats().batch_builds)
	var uploads := int(world.stats().full_uploads) + int(world.stats().partial_uploads)
	var children := world.get_child_count()
	var overlay := presenter.selection_overlay_nodes()
	var rec := r.clone()
	for i in 50:
		rec.set_position(5.0 + i * 3.0, 0.0, 5.0 - i * 1.5)
		rec.set_yaw(i * 0.1)
		doc.put_object(rec)
		presenter.sync_object(doc, r.object_id)
		presenter.service_frame()
		assert_true(presenter.node_for(r.object_id) == node and node.mesh == mesh, "same node and mesh at step %d" % i)
		assert_true(node.transform.is_equal_approx(presenter.applied_transform(r.object_id)))
		assert_true((overlay[0] as Node3D).transform.is_equal_approx(node.transform), "overlay follows")
		assert_vec_near(presenter.world_bounds(r.object_id).get_center(), presenter.applied_transform(r.object_id) * catalog.get_asset(SPRUCE).bounds.get_center(), 1e-3, "index follows")
	assert_eq(int(world.stats().batch_builds), builds, "no batch built while dragging")
	assert_eq(world.get_child_count(), children, "no node allocated while dragging")
	assert_eq(int(world.stats().full_uploads) + int(world.stats().partial_uploads), uploads + 0, "the batch of the other spruce was not touched")
	assert_eq(presenter.pick(presenter.world_bounds(r.object_id).get_center() + Vector3(0, 30, 0), Vector3.DOWN).id, r.object_id)


func test_moving_across_cell_boundaries_keeps_one_owner_and_picking() -> void:
	var r := _add(SPRUCE, Vector3(-33, 0, -33))
	presenter.rebuild(doc)
	_settle()
	var visited := {}
	for p: Vector3 in [Vector3(-33, 0, -33), Vector3(-31, 0, -33), Vector3(-1, 0, -1), Vector3(1, 0, 1), Vector3(-32, 0, 0),
			Vector3(31.5, 0, 31.5), Vector3(32.5, 0, 32.5), Vector3(-0.5, 0, 63), Vector3(-65, 0, -0.1)]:
		var rec := r.clone()
		rec.set_position(p.x, p.y, p.z)
		doc.put_object(rec)
		presenter.sync_object(doc, r.object_id)
		presenter.service_frame()
		var batch := world.batch_of(r.object_id)
		var want := Vector3(floorf(p.x / 32.0) * 32.0, 0.0, floorf(p.z / 32.0) * 32.0)
		assert_vec_near(batch.origin, want, 1e-9, "cell of %s" % p)
		assert_eq(batch.count, 1)
		assert_eq(int(world.stats().instances), 1, "exactly one instance at %s" % p)
		assert_eq(presenter.pick(p + Vector3(0, 30, 0), Vector3.DOWN).id, r.object_id, "pickable at %s" % p)
		visited[batch.origin] = true
	assert_true(visited.size() >= 7, "the object really changed batches")
	_assert_consistent("after boundary moves")


func test_cell_local_storage_reproduces_applied_transforms_in_a_km1_extent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	for i in 60:
		_add(SPRUCE if i % 2 == 0 else BOULDER, Vector3(rng.randf_range(-512, 512), rng.randf_range(0, 40), rng.randf_range(-512, 512)),
				rng.randf_range(0.0, TAU), rng.randf_range(0.5, 2.5))
	_add(SPRUCE, Vector3(-512, 3, -512))
	_add(SPRUCE, Vector3(511.9, 3, 511.9))
	presenter.rebuild(doc)
	_settle()
	_assert_consistent("km1 extent")


func test_a_crown_overhanging_the_cell_is_inside_the_batch_bounds_and_pickable() -> void:
	var r := _add(LODGE, Vector3(30.0, 0, 5.0), 0.0, 2.0)
	presenter.rebuild(doc)
	_settle()
	var d := world._res.registry.descriptor(LODGE)
	var rep := world.owner_of(r.object_id).get_slice("|", 1)
	var render := presenter.applied_transform(r.object_id) * (d.roles[rep].aabb as AABB)
	assert_true(render.end.x > 32.0 and render.position.x < 32.0, "the render box straddles the cell edge")
	var batch := world.batch_of(r.object_id)
	assert_eq(batch.origin, Vector3.ZERO, "owned by the cell of its anchor")
	assert_true(batch.world_aabb().grow(1e-3).encloses(render), "custom_aabb covers the neighbour overhang")
	var wb := presenter.world_bounds(r.object_id)
	var x := 32.0 + (wb.end.x - 32.0) * 0.5
	assert_eq(presenter.pick(Vector3(x, 60, 5.0), Vector3.DOWN).id, r.object_id, "picked from the neighbour side")


func test_settled_world_does_no_uploads_or_builds() -> void:
	for i in 40:
		_add(SPRUCE if i % 2 == 0 else BOULDER, Vector3(i * 7.0 - 100.0, 0, (i % 5) * 9.0))
	presenter.rebuild(doc)
	_settle()
	var before := world.stats()
	for i in 10:
		presenter.service_frame()
		assert_false(presenter.has_pending_work())
	var after := world.stats()
	for key in ["full_uploads", "partial_uploads", "batch_builds", "batches", "instances"]:
		assert_eq(after[key], before[key], key + " unchanged over 10 settled frames")
	assert_true(int(before.full_uploads) > 0, "the initial build did upload")


func test_more_placements_in_one_batch_add_instances_not_nodes() -> void:
	var nodes := -1
	for count in [1, 10, 100]:
		doc = WorldDocument.new()
		for i in count:
			_add(SPRUCE, Vector3(1.0 + (i % 10) * 2.8, 0, 1.0 + (i / 10) * 2.8))
		presenter.rebuild(doc)
		_settle()
		var stats := world.stats()
		assert_eq(presenter.individual_instance_count(), count)
		assert_eq(stats.batches, 1, "one batch for %d spruces" % count)
		if nodes < 0:
			nodes = presenter.node_count()
		assert_eq(presenter.node_count(), nodes, "node_count is independent of the placement count")
		assert_eq(presenter.authored_object_count(), count)
		assert_eq(presenter.represented_object_count(), count)
		assert_eq(stats.estimated_triangles, 152 * count)


func test_missing_role_mesh_never_makes_the_object_disappear() -> void:
	var r := _add(BOULDER, Vector3(10, 0, 10))
	var s := _add(SPRUCE, Vector3(50, 0, 10))
	presenter.rebuild(doc)
	world.service_frame(5.0)  # nothing polled from the cache: no mesh is READY yet
	assert_eq(world.stats().instances, 2, "drawn while loading")
	assert_eq(world.stats().placeholders, 2, "by placeholders")
	assert_true(presenter.has_pending_work())
	_settle()
	assert_eq(world.stats().placeholders, 0)
	assert_eq(world.owner_of(s.object_id), SPRUCE + "|mid")
	presenter.set_default_role("near")
	world.service_frame(5.0)
	assert_eq(world.stats().instances, 2)
	assert_eq(world.owner_of(s.object_id), SPRUCE + "|mid", "the valid coarser tier stays until near is READY")
	_settle()
	assert_eq(world.owner_of(s.object_id), SPRUCE + "|near")
	_assert_consistent("after the role change")


func test_pinned_cells_defer_role_changes_but_not_edits() -> void:
	var r := _add(SPRUCE, Vector3(5, 0, 5))
	var far := _add(SPRUCE, Vector3(200, 0, 5))
	presenter.rebuild(doc)
	_settle()
	presenter.set_pin_check(func(cell: Vector2i) -> bool: return cell == Vector2i(0, 0))
	presenter.set_default_role("near")
	for i in 400:
		presenter.service_frame(4.0)
		if world.owner_of(far.object_id).ends_with("|near"):
			break
		OS.delay_msec(2)
	assert_eq(world.owner_of(far.object_id), SPRUCE + "|near", "unpinned cells change")
	assert_eq(world.owner_of(r.object_id), SPRUCE + "|mid", "the pinned cell keeps its tier")
	var moved := r.clone()
	moved.set_position(12, 0, 6)
	doc.put_object(moved)
	presenter.sync_object(doc, r.object_id)
	presenter.service_frame()
	assert_vec_near(_slot_world(r.object_id).origin, presenter.applied_transform(r.object_id).origin, 1e-4, "edits still apply while pinned")
	assert_true(presenter.has_pending_work(), "the deferred change is still pending")
	presenter.set_pin_check(Callable())
	_settle()
	assert_eq(world.owner_of(r.object_id), SPRUCE + "|near", "applied once released")


func test_cancel_undo_redo_delete_keep_batches_consistent() -> void:
	var a := _add(SPRUCE, Vector3(5, 0, 5))
	var b := _add(BOULDER, Vector3(40, 0, 5))
	var c := _add(SPRUCE, Vector3(8, 0, 8))
	presenter.rebuild(doc)
	presenter.set_selected(a.object_id)
	_settle()
	_assert_consistent("start")
	var moved := a.clone()
	moved.set_position(70, 0, 70)
	doc.put_object(moved)
	presenter.sync_object(doc, a.object_id)
	_assert_consistent("selected drag")
	doc.put_object(a)  # cancel: the authored transform returns
	presenter.sync_object(doc, a.object_id)
	_assert_consistent("selected cancel")
	doc.remove_object(a.object_id)  # delete the selected object
	presenter.sync_object(doc, a.object_id)
	assert_eq(presenter.selected_id(), "")
	assert_true(world.promoted_node() == null)
	_assert_consistent("selected delete")
	doc.put_object(a)  # undo
	presenter.sync_object(doc, a.object_id)
	_settle()
	_assert_consistent("undo delete")
	doc.remove_object(b.object_id)  # delete an unselected object
	presenter.sync_object(doc, b.object_id)
	_assert_consistent("unselected delete")
	doc.put_object(b)  # undo, then redo, then undo again
	presenter.sync_objects(doc, [b.object_id])
	doc.remove_object(b.object_id)
	presenter.sync_objects(doc, [b.object_id])
	doc.put_object(b)
	presenter.sync_objects(doc, [b.object_id])
	_settle()
	_assert_consistent("undo/redo")
	var swapped := c.clone()
	swapped.asset_id = BOULDER
	doc.put_object(swapped)
	presenter.sync_object(doc, c.object_id)
	_settle()
	_assert_consistent("asset replacement")
	assert_true(world.owner_of(c.object_id).begins_with(BOULDER))


func test_world_replacement_bumps_the_epoch_and_discards_old_work() -> void:
	for i in 30:
		_add(SPRUCE, Vector3(i * 5.0, 0, 0))
	presenter.rebuild(doc)
	presenter.service_frame()  # requests are queued / in flight
	var epoch := int(world.stats().world_epoch)
	var empty := WorldDocument.new()
	presenter.rebuild(empty)
	assert_eq(int(world.stats().world_epoch), epoch + 1)
	assert_eq(world.stats().instances, 0)
	for i in 100:
		presenter.service_frame(4.0)
		OS.delay_msec(2)
	assert_eq(world.stats().instances, 0, "a late result of the old epoch attaches nothing")
	assert_eq(world.stats().batches, 0)
	var stats := presenter._cache.stats()
	assert_eq(stats.loading + stats.queued, 0, "old requests are cancelled or finished")
	presenter.rebuild(doc)
	_settle()
	_assert_consistent("the new world renders normally")
	assert_eq(int(world.stats().world_epoch), epoch + 2)


func test_presenting_fixtures_never_loads_catalog_preview_scenes() -> void:
	var before := {}
	for id in catalog.sorted_ids():
		before[id] = ResourceLoader.has_cached(catalog.get_asset(id).preview_scene)
	var loaded := WorldCodec.read_generation("res://fixtures/stress_100", catalog)
	assert_empty_string(loaded[1])
	presenter.rebuild(loaded[0])
	presenter.set_selected(presenter.object_ids()[0])
	_settle()
	assert_eq(presenter.authored_object_count(), 100)
	assert_eq(presenter.represented_object_count(), 100)
	for id in catalog.sorted_ids():
		if not before[id]:
			assert_false(ResourceLoader.has_cached(catalog.get_asset(id).preview_scene), "preview scene of %s stayed unloaded" % id)
	var r := ObjectRecord.new()
	r.asset_id = BOULDER
	presenter.show_ghost(r, true)
	for id in catalog.sorted_ids():
		if not before[id]:
			assert_false(ResourceLoader.has_cached(catalog.get_asset(id).preview_scene), "ghost does not load %s" % id)


func test_not_ready_assets_are_bounded_placeholders_with_one_notice() -> void:
	var reg := StubRenderRegistry.hiding(catalog, [SPRUCE])
	presenter = _make(reg)
	world = presenter.render_world()
	var notices: Array[String] = []
	presenter.placeholders_reported.connect(func(text: String) -> void: notices.append(text))
	var trees: Array[ObjectRecord] = []
	for i in 7:
		trees.append(_add(SPRUCE, Vector3(i * 4.0, 0, 3)))
	_add(BOULDER, Vector3(60, 0, 3))
	presenter.rebuild(doc)
	_settle()
	for i in 5:
		presenter.service_frame()
	assert_eq(world.stats().placeholders, 7)
	assert_eq(world.stats().instances, 8)
	assert_eq(world.stats().estimated_triangles, 7 * 12 + 80)
	assert_eq(notices.size(), 1, "one message per world")
	assert_true(notices[0].contains("7 objects use placeholders") and notices[0].contains(SPRUCE), notices[0])
	var bounds := catalog.get_asset(SPRUCE).bounds
	var box := world.batch_of(trees[0].object_id).local_transform(world.batch_of(trees[0].object_id).slot_of[trees[0].object_id])
	assert_vec_near(box.basis.get_scale(), bounds.size * presenter.applied_transform(trees[0].object_id).basis.get_scale(), 1e-3, "box fitted to the catalog bounds")
	presenter.set_selected(trees[0].object_id)
	assert_eq(world.promoted_rep(), "placeholder")
	assert_eq(world.stats().instances, 8)
	presenter.rebuild(doc)
	_settle()
	for i in 3:
		presenter.service_frame()
	assert_eq(notices.size(), 2, "a new world reports again")


func test_unready_assets_get_a_bounds_box_ghost() -> void:
	presenter = _make(StubRenderRegistry.hiding(catalog, [SPRUCE]))
	var r := ObjectRecord.new()
	r.asset_id = SPRUCE
	presenter.show_ghost(r, true)
	presenter.service_frame()
	presenter.show_ghost(r, true)
	assert_false(presenter.ghost().uses_prepared_mesh(), "a bounds box stands in")
	assert_true(presenter.has_ghost_visible())
