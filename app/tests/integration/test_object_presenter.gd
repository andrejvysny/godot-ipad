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
	assert_true(presenter._overlay != null)
	presenter.set_selected("nope")
	assert_eq(presenter.selected_id(), "")
	assert_true(presenter._overlay == null)
	presenter.set_selected(r.object_id)
	presenter.set_selected("")
	assert_eq(presenter.selected_id(), "")
	presenter.set_selected(r.object_id)
	presenter.rebuild(doc)
	assert_eq(presenter.selected_id(), r.object_id, "kept across rebuild")
	doc.remove_object(r.object_id)
	presenter.sync_object(doc, r.object_id)
	assert_eq(presenter.selected_id(), "")
	assert_true(presenter._overlay == null)
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
	assert_eq(presenter._markers.size(), 0)
	assert_eq(presenter._labels.size(), 0)
	presenter.set_show_anchors(true)
	presenter.set_show_ids(true)
	assert_eq(presenter._markers.size(), 1)
	assert_eq(presenter._labels.size(), 1)
	assert_vec_near((presenter._markers[r.object_id] as Node3D).position, Vector3(1, 2, 3), 1e-5)
	var label := presenter._labels[r.object_id] as Label3D
	assert_eq(label.text, r.object_id.left(8))
	var wb := presenter.world_bounds(r.object_id)
	assert_near(label.position.y, wb.end.y + 0.5, 1e-5)
	var moved := r.clone()
	moved.set_position(7, 2, 3)
	doc.put_object(moved)
	presenter.sync_object(doc, r.object_id)
	assert_vec_near((presenter._markers[r.object_id] as Node3D).position, Vector3(7, 2, 3), 1e-5)
	var second := _add(SPRUCE, Vector3(30, 0, 0))
	presenter.sync_object(doc, second.object_id)
	assert_eq(presenter._markers.size(), 2)
	assert_eq(presenter._labels.size(), 2)
	doc.remove_object(second.object_id)
	presenter.sync_object(doc, second.object_id)
	assert_eq(presenter._markers.size(), 1)
	assert_eq(presenter._labels.size(), 1)
	presenter.set_show_anchors(false)
	presenter.set_show_ids(false)
	assert_eq(presenter._markers.size(), 0)
	assert_eq(presenter._labels.size(), 0)
	assert_eq(presenter.pick(Vector3(7, 10, 3), Vector3.DOWN).id, r.object_id, "markers never pickable")
