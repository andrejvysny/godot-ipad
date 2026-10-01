extends TestCase

const BOULDER := "nature.rock.boulder_a"
const LODGE := "built.lodge.cabin_a"
const SPRUCE := "nature.tree.spruce_a"

var presenter: ObjectPresenter
var catalog: AssetCatalog
var doc: WorldDocument


func before_each() -> void:
	var loaded := AssetCatalog.load_from()
	catalog = loaded[0]
	doc = WorldDocument.new()
	presenter = ObjectPresenter.new()
	presenter.setup(catalog)
	tree.root.add_child(presenter)


func after_each() -> void:
	if is_instance_valid(presenter):
		tree.root.remove_child(presenter)
		presenter.free()


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


func _meshes(node: Node, out: Array[MeshInstance3D] = []) -> Array[MeshInstance3D]:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for c in node.get_children():
		_meshes(c, out)
	return out


func test_rebuild_applies_anchor_transform() -> void:
	var r := _add(BOULDER, Vector3(10, 2, -5), deg_to_rad(30.0), 2.0)
	var anchor := catalog.get_asset(BOULDER).anchor_local
	assert_true(anchor != Vector3.ZERO)
	presenter.rebuild(doc)
	var node := presenter.node_for(r.object_id)
	assert_true(node != null)
	assert_eq(String(node.name), "obj_" + r.object_id)
	assert_true(node.transform.is_equal_approx(r.node_transform(anchor)))
	assert_vec_near(presenter._xforms[r.object_id] * anchor, r.get_position_v3(), 1e-5)
	assert_eq(presenter.object_count(), 1)
	assert_eq(presenter.object_ids(), PackedStringArray([r.object_id]))


func test_sync_add_update_remove_and_asset_change() -> void:
	var r := _add(BOULDER, Vector3.ZERO)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.object_count(), 1)
	var first := presenter.node_for(r.object_id)
	var moved := r.clone()
	moved.set_position(4, 0, 4)
	doc.put_object(moved)
	presenter.sync_object(doc, r.object_id)
	assert_true(presenter.node_for(r.object_id) == first, "same node on transform update")
	assert_true(first.transform.is_equal_approx(moved.node_transform(catalog.get_asset(BOULDER).anchor_local)))
	var swapped := moved.clone()
	swapped.asset_id = SPRUCE
	doc.put_object(swapped)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.object_count(), 1)
	assert_true(presenter.node_for(r.object_id) != first, "node re-created")
	var unknown := swapped.clone()
	unknown.asset_id = "no.such.asset"
	doc.put_object(unknown)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.object_count(), 0)
	doc.put_object(swapped)
	presenter.sync_objects(doc, [r.object_id])
	assert_eq(presenter.object_count(), 1)
	doc.remove_object(r.object_id)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.object_count(), 0)
	assert_true(presenter.node_for(r.object_id) == null)


func test_pick_basic_hits_and_misses() -> void:
	var r := _add(BOULDER, Vector3.ZERO)
	presenter.rebuild(doc)
	var hit := presenter.pick(Vector3(0, 10, 0), Vector3.DOWN)
	assert_eq(hit.id, r.object_id)
	assert_near(hit.distance, 8.9, 1e-4)
	var scaled_dir := presenter.pick(Vector3(0, 10, 0), Vector3(0, -2, 0))
	assert_near(scaled_dir.distance, 8.9, 1e-4, "distance is in world units for non-unit dir")
	assert_eq(presenter.pick(Vector3(5, 10, 0), Vector3.DOWN).id, "")
	assert_eq(presenter.pick(Vector3(0, 10, 0), Vector3.UP).id, "")
	assert_eq(presenter.pick(Vector3(0, 10, 0), Vector3.DOWN).id, r.object_id)
	var none := presenter.pick(Vector3(5, 10, 0), Vector3.DOWN)
	assert_eq(none.distance, INF)


func test_pick_nearest_of_stacked_and_origin_inside() -> void:
	var low := _add(BOULDER, Vector3.ZERO)
	var high := _add(BOULDER, Vector3(0, 5, 0))
	presenter.rebuild(doc)
	var hit := presenter.pick(Vector3(0, 20, 0), Vector3.DOWN)
	assert_eq(hit.id, high.object_id)
	assert_near(hit.distance, 13.9, 1e-4)
	var inside := presenter.pick(Vector3(0, 0.2, 0), Vector3.DOWN)
	assert_eq(inside.id, low.object_id)
	assert_eq(inside.distance, 0.0)


func test_pick_uses_oriented_bounds() -> void:
	var r := _add(LODGE, Vector3.ZERO, deg_to_rad(45.0))
	presenter.rebuild(doc)
	var wb := presenter.world_bounds(r.object_id)
	assert_true(wb.has_point(Vector3(5, 3, 0)), "inside the axis-aligned bounds")
	assert_eq(presenter.pick(Vector3(5, 20, 0), Vector3.DOWN).id, "", "outside oriented box")
	assert_eq(presenter.pick(Vector3(3, 20, 0), Vector3.DOWN).id, r.object_id)


func test_pick_honours_scale() -> void:
	var r := _add(BOULDER, Vector3.ZERO, 0.0, 2.0)
	presenter.rebuild(doc)
	var hit := presenter.pick(Vector3(1.8, 10, 0), Vector3.DOWN)
	assert_eq(hit.id, r.object_id)
	assert_near(hit.distance, 7.8, 1e-4)
	var small := r.clone()
	small.uniform_scale = 1.0
	doc.put_object(small)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.pick(Vector3(1.8, 10, 0), Vector3.DOWN).id, "")


func test_pick_rejects_bad_input() -> void:
	_add(BOULDER, Vector3.ZERO)
	presenter.rebuild(doc)
	assert_eq(presenter.pick(Vector3(0, 10, 0), Vector3.ZERO).id, "")
	assert_eq(presenter.pick(Vector3(0, 10, 0), Vector3(0, NAN, 0)).id, "")
	assert_eq(presenter.pick(Vector3(0, INF, 0), Vector3.DOWN).id, "")
	assert_eq(presenter.pick(Vector3(NAN, 10, 0), Vector3.DOWN).distance, INF)


func test_ghost_show_hide_colour_and_not_pickable() -> void:
	var r := ObjectRecord.new()
	r.asset_id = BOULDER
	r.set_position(0, 0, 0)
	assert_false(presenter.has_ghost_visible())
	presenter.show_ghost(r, true)
	assert_true(presenter.has_ghost_visible())
	assert_true(presenter.ghost_valid())
	assert_eq(presenter.pick(Vector3(0, 10, 0), Vector3.DOWN).id, "")
	assert_eq(presenter.object_count(), 0)
	var meshes := _meshes(presenter._ghost)
	assert_true(not meshes.is_empty())
	for m in meshes:
		assert_true(m.material_override == presenter._ghost_material)
		assert_eq(m.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_eq(presenter._ghost_material.albedo_color, Color(0.30, 0.90, 0.40, 0.45))
	presenter.show_ghost(r, false)
	assert_false(presenter.ghost_valid())
	assert_eq(presenter._ghost_material.albedo_color, Color(0.95, 0.30, 0.25, 0.45))
	var ghost := presenter._ghost
	presenter.show_ghost(r, true)
	assert_true(presenter._ghost == ghost, "same asset reuses ghost")
	presenter.hide_ghost()
	assert_false(presenter.has_ghost_visible())


func test_selection_set_clear_and_removal() -> void:
	var r := _add(BOULDER, Vector3.ZERO)
	var other := _add(SPRUCE, Vector3(20, 0, 0))
	presenter.rebuild(doc)
	presenter.set_selected(r.object_id)
	assert_eq(presenter.selected_id(), r.object_id)
	assert_true(presenter.selection_overlay_visible())
	presenter.set_selected("nope")
	assert_eq(presenter.selected_id(), "")
	assert_false(presenter.selection_overlay_visible())
	presenter.set_selected(r.object_id)
	presenter.set_selected("")
	assert_eq(presenter.selected_id(), "")
	presenter.set_selected(r.object_id)
	presenter.rebuild(doc)
	assert_eq(presenter.selected_id(), r.object_id, "kept across rebuild")
	doc.remove_object(r.object_id)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.selected_id(), "")
	assert_false(presenter.selection_overlay_visible())
	presenter.set_selected(other.object_id)
	doc.remove_object(other.object_id)
	presenter.rebuild(doc)
	assert_eq(presenter.selected_id(), "")


func test_world_bounds_of_scaled_object() -> void:
	var r := _add(BOULDER, Vector3.ZERO, 0.0, 2.0)
	presenter.rebuild(doc)
	var wb := presenter.world_bounds(r.object_id)
	assert_vec_near(wb.position, Vector3(-2.2, -0.6, -2.2), 1e-4)
	assert_vec_near(wb.size, Vector3(4.4, 2.8, 4.4), 1e-4)
	assert_eq(presenter.world_bounds("missing"), AABB())


func test_debug_markers_follow_sync() -> void:
	var r := _add(BOULDER, Vector3(1, 2, 3))
	presenter.rebuild(doc)
	assert_eq(presenter.debug_marker_count(), 0)
	assert_eq(presenter.debug_label_count(), 0)
	presenter.set_show_anchors(true)
	presenter.set_show_ids(true)
	assert_eq(presenter.debug_marker_count(), 1)
	assert_eq(presenter.debug_label_count(), 1)
	assert_vec_near(presenter.debug_marker_for(r.object_id).position, Vector3(1, 2, 3), 1e-5)
	var label := presenter.debug_label_for(r.object_id)
	assert_eq(label.text, r.object_id.left(8))
	var wb := presenter.world_bounds(r.object_id)
	assert_near(label.position.y, wb.end.y + 0.5, 1e-5)
	var moved := r.clone()
	moved.set_position(7, 2, 3)
	doc.put_object(moved)
	presenter.sync_object(doc, r.object_id)
	assert_vec_near(presenter.debug_marker_for(r.object_id).position, Vector3(7, 2, 3), 1e-5)
	var second := _add(SPRUCE, Vector3(30, 0, 0))
	presenter.sync_object(doc, second.object_id)
	presenter.set_show_ids(true)  # assignments refresh on toggle, otherwise within 250 ms
	assert_eq(presenter.debug_marker_count(), 2)
	assert_eq(presenter.debug_label_count(), 2)
	doc.remove_object(second.object_id)
	presenter.sync_object(doc, second.object_id)
	assert_eq(presenter.debug_marker_count(), 1)
	assert_eq(presenter.debug_label_count(), 1)
	presenter.set_show_anchors(false)
	presenter.set_show_ids(false)
	assert_eq(presenter.debug_marker_count(), 0)
	assert_eq(presenter.debug_label_count(), 0)
	assert_eq(presenter.pick(Vector3(7, 10, 3), Vector3.DOWN).id, r.object_id, "markers never pickable")


func test_debug_decor_is_bounded_and_keeps_selection() -> void:
	var last := ""
	for i in 300:
		last = _add(BOULDER, Vector3(i * 3.0, 0, 0)).object_id
	presenter.rebuild(doc)
	presenter.set_selected(last)
	presenter.set_show_anchors(true)
	presenter.set_show_ids(true)
	assert_eq(presenter.debug_marker_count(), 64)
	assert_eq(presenter.debug_label_count(), 64)
	assert_true(presenter.debug_label_ids().has(last), "selected object always labelled")
	var children := presenter.get_child_count()
	presenter.set_debug_limit(8)
	assert_eq(presenter.debug_label_count(), 8)
	assert_eq(presenter.debug_marker_count(), 8)
	assert_true(presenter.debug_label_ids().has(last))
	assert_eq(presenter.get_child_count(), children, "pool nodes are hidden, not freed")
	presenter.set_show_anchors(false)
	presenter.set_show_ids(false)
	assert_eq(presenter.debug_label_count(), 0)


func test_instantiated_nodes_cast_no_shadow() -> void:
	var r := _add(SPRUCE, Vector3.ZERO)
	presenter.rebuild(doc)
	var meshes := _meshes(presenter.node_for(r.object_id))
	assert_true(not meshes.is_empty())
	for m in meshes:
		assert_eq(m.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


func test_selection_overlay_is_built_once_and_followed() -> void:
	var r := _add(BOULDER, Vector3.ZERO)
	presenter.rebuild(doc)
	presenter.set_selected(r.object_id)
	var nodes := presenter.selection_overlay_nodes()
	var mesh := (nodes[1] as MeshInstance3D).mesh
	var children := presenter.get_child_count()
	var anchor := catalog.get_asset(BOULDER).anchor_local
	var rec := r.clone()
	for i in 50:
		rec.set_position(i * 0.5, 1.0, -i * 0.25)
		rec.set_yaw(i * 0.1)
		doc.put_object(rec)
		presenter.sync_object(doc, r.object_id)
		var now := presenter.selection_overlay_nodes()
		assert_true(now[0] == nodes[0] and now[1] == nodes[1] and now[2] == nodes[2], "same overlay nodes")
		assert_true((now[1] as MeshInstance3D).mesh == mesh, "same wire mesh")
	assert_eq(presenter.get_child_count(), children)
	assert_true((nodes[0] as Node3D).transform.is_equal_approx(presenter.applied_transform(r.object_id)))
	assert_vec_near((nodes[2] as Node3D).position, rec.get_position_v3(), 1e-4)
	assert_vec_near(presenter.applied_transform(r.object_id) * anchor, rec.get_position_v3(), 1e-4)
	presenter.set_selected("")
	assert_false(presenter.selection_overlay_visible())
	presenter.set_selected(r.object_id)
	assert_true(presenter.selection_overlay_nodes()[1] == nodes[1])
	assert_true(presenter.has_object(r.object_id))
	assert_false(presenter.has_object("nope"))


func _doc_snapshot() -> String:
	var parts := PackedStringArray()
	for id in doc.sorted_object_ids():
		parts.append(JSON.stringify(doc.get_object(id).to_dict()))
	return "\n".join(parts)


func test_vegetation_hidden_is_presentation_only() -> void:
	var tree_rec := _add(SPRUCE, Vector3.ZERO)
	var rock := _add(BOULDER, Vector3(20, 0, 0))
	var lodge := _add(LODGE, Vector3(-20, 0, 0))
	presenter.rebuild(doc)
	var before := _doc_snapshot()
	var category := catalog.get_asset(SPRUCE).category
	assert_true(catalog.get_asset(BOULDER).category != category and catalog.get_asset(LODGE).category != category)
	var rule := {"categories": [category], "excluded_asset_ids": []}
	var rev := presenter.presentation_revision()
	presenter.set_selected(tree_rec.object_id)
	presenter.set_vegetation_hidden(true, rule)
	assert_true(presenter.vegetation_hidden())
	assert_true(presenter.presentation_revision() > rev)
	assert_false(presenter.node_for(tree_rec.object_id).visible)
	assert_true(presenter.node_for(rock.object_id).visible)
	assert_true(presenter.node_for(lodge.object_id).visible)
	assert_eq(presenter.pick(Vector3(0, 40, 0), Vector3.DOWN).id, "")
	assert_eq(presenter.pick(Vector3(20, 40, 0), Vector3.DOWN).id, rock.object_id)
	var near := presenter.objects_near(Vector3.ZERO, 100.0, 10)
	assert_false(near.has(tree_rec.object_id))
	assert_true(near.has(rock.object_id) and near.has(lodge.object_id))
	assert_true(presenter.selection_overlay_visible(), "selected hidden object keeps bounds")
	assert_eq(presenter.selected_id(), tree_rec.object_id)
	var late := _add(SPRUCE, Vector3(5, 0, 40))
	presenter.sync_object(doc, late.object_id)
	assert_false(presenter.node_for(late.object_id).visible, "nodes created while hidden are hidden")
	doc.remove_object(late.object_id)
	presenter.sync_object(doc, late.object_id)
	assert_eq(_doc_snapshot(), before, "document untouched")
	presenter.set_vegetation_hidden(true, {"categories": [category], "excluded_asset_ids": [SPRUCE]})
	assert_true(presenter.node_for(tree_rec.object_id).visible, "excluded asset stays visible")
	presenter.set_vegetation_hidden(false, rule)
	assert_true(presenter.node_for(tree_rec.object_id).visible)
	assert_eq(presenter.pick(Vector3(0, 40, 0), Vector3.DOWN).id, tree_rec.object_id)
	assert_true(presenter.objects_near(Vector3.ZERO, 100.0, 10).has(tree_rec.object_id))


# --- picking vs the original exhaustive algorithm (PICK-01/02) ---------------------------------

func _reference_pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {"id": "", "distance": INF}
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-12:
		return best
	var dir_len := dir.length()
	for id: String in presenter._xforms:
		var asset := catalog.get_asset(presenter._asset_of[id])
		var inv := (presenter._xforms[id] as Transform3D).affine_inverse()
		var lo := inv * origin
		var ld := inv.basis * dir
		var t := 0.0
		if not asset.bounds.has_point(lo):
			var hit: Variant = asset.bounds.intersects_ray(lo, ld)
			if hit == null:
				continue
			t = ((hit as Vector3) - lo).dot(ld) / ld.length_squared()
			if t < 0.0:
				continue
		var dist := t * dir_len
		if dist < (best["distance"] as float):
			best = {"id": id, "distance": dist}
	return best


func test_pick_matches_reference_on_random_scene() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261001
	var assets := [BOULDER, LODGE, SPRUCE]
	for i in 360:
		var pos := Vector3(rng.randf_range(-300, 300), rng.randf_range(-2, 12), rng.randf_range(-300, 300))
		_add(assets[i % 3], pos, rng.randf_range(0.0, TAU), rng.randf_range(0.6, 2.5))
	presenter.rebuild(doc)
	var ids := presenter.object_ids()
	var hits := 0
	for i in 600:
		var origin: Vector3
		var dir: Vector3
		var mode := i % 3
		if mode == 0:
			origin = Vector3(rng.randf_range(-320, 320), rng.randf_range(40, 120), rng.randf_range(-320, 320))
			dir = Vector3(rng.randf_range(-0.4, 0.4), -1.0, rng.randf_range(-0.4, 0.4)) * rng.randf_range(0.5, 3.0)
		elif mode == 1:
			origin = Vector3(rng.randf_range(-320, 320), rng.randf_range(1, 4), rng.randf_range(-320, 320))
			dir = Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.1, 0.05), rng.randf_range(-1, 1))
		else:
			origin = presenter.world_bounds(ids[rng.randi() % ids.size()]).get_center()
			dir = Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		var got := presenter.pick(origin, dir)
		var want := _reference_pick(origin, dir)
		assert_eq(got.id, want.id, "ray %d id" % i)
		if want.id != "":
			hits += 1
			assert_near(got.distance, want.distance, 1e-9, "ray %d distance" % i)
	assert_true(hits > 100, "random rays actually hit objects (%d)" % hits)


func test_pick_ignores_removed_objects_and_bad_dirs() -> void:
	var a := _add(BOULDER, Vector3.ZERO)
	var b := _add(BOULDER, Vector3(0, 6, 0))
	presenter.rebuild(doc)
	assert_eq(presenter.pick(Vector3(0, 30, 0), Vector3(0, -7, 0)).id, b.object_id)
	doc.remove_object(b.object_id)
	presenter.sync_object(doc, b.object_id)
	var hit := presenter.pick(Vector3(0, 30, 0), Vector3(0, -7, 0))
	assert_eq(hit.id, a.object_id)
	assert_near(hit.distance, 28.9, 1e-3)
	assert_eq(presenter.pick(Vector3(0, 30, 0), Vector3(NAN, -1, 0)).id, "")
	assert_eq(presenter.pick(Vector3(0, 30, 0), Vector3.ZERO).distance, INF)


func test_overhanging_bounds_are_picked_from_the_neighbour_cell() -> void:
	var r := _add(LODGE, Vector3(30.0, 0, 5.0), 0.0, 2.0)
	presenter.rebuild(doc)
	var wb := presenter.world_bounds(r.object_id)
	assert_true(wb.end.x > 32.0 and wb.position.x < 32.0, "bounds straddle the cell edge")
	var x := 32.0 + (wb.end.x - 32.0) * 0.5
	assert_eq(presenter.pick(Vector3(x, 60, 5.0), Vector3.DOWN).id, r.object_id)
	var shallow := presenter.pick(Vector3(x + 40.0, wb.get_center().y, 5.0), Vector3.LEFT)
	assert_eq(shallow.id, r.object_id)


func test_objects_near_and_revision() -> void:
	var near := _add(BOULDER, Vector3(3, 0, 0))
	var far := _add(BOULDER, Vector3(90, 0, 0))
	presenter.rebuild(doc)
	assert_eq(presenter.objects_near(Vector3.ZERO, 40.0, 5), PackedStringArray([near.object_id]))
	assert_eq(presenter.objects_near(Vector3.ZERO, 200.0, 1), PackedStringArray([near.object_id]))
	assert_eq(presenter.objects_near(Vector3.ZERO, 200.0, 5).size(), 2)
	var rev := presenter.presentation_revision()
	presenter.sync_object(doc, far.object_id)
	assert_true(presenter.presentation_revision() > rev)
