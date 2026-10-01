extends TestCase
## Fixed-area Texture Preview, object side (spec 11.1, 11.3, 11.5; PREVIEW-01/03/04/05/07, EDIT-01): objects
## whose bounds intersect the area show their prepared preview textures through shared material variants;
## everything else stays on the low tier. Bench registry (pine_cards has preview tiers, broadleaf none).

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const TerrainPreviewTests := preload("res://tests/integration/test_texture_preview.gd")
const PINE := "bench.tree.pine_cards"
const BROADLEAF := "bench.tree.broadleaf_geo"
const TIMEOUT_FRAMES := 600

var _filter: TerrainTests.KnownWarningFilter
var _adapter: TerrainAdapter
var _doc: WorldDocument
var _cache: RenderAssetCache
var _presenter: ObjectPresenter
var _world: ObjectRenderWorld
var _ctrl: TexturePreviewController


func before_each() -> void:
	allow_logged_errors()
	_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(_filter)


func after_each() -> void:
	if _presenter != null and is_instance_valid(_presenter):
		tree.root.remove_child(_presenter)
		_presenter.free()
	_presenter = null
	if _adapter != null and is_instance_valid(_adapter):
		_adapter.get_parent().remove_child(_adapter)
		_adapter.free()
	_adapter = null
	assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))
	OS.remove_logger(_filter)


func _setup_env(preview_mib: float = -1.0) -> void:
	_doc = TerrainPreviewTests.new()._mixed_doc()
	var a := TerrainAdapter.new()
	tree.root.add_child(a)
	var cam := Camera3D.new()
	a.add_child(cam)
	cam.position = Vector3(0, 60, 60)
	a.set_camera(cam)
	assert_empty_string(a.initialize(_doc), "initialize")
	_adapter = a
	var budgets := RenderConfig.safe_default().section("budgets")
	budgets.inflight_loads = 1  # the dummy renderer's texture storage is not thread-safe
	if preview_mib > 0.0:
		budgets.preview_mib = preview_mib
	_cache = RenderAssetCache.new(budgets)
	var catalog: AssetCatalog = AssetCatalog.load_from("res://assets/bench")[0]
	var registry := RenderAssetRegistry.load_from("res://assets/bench/render_assets/index.json", catalog)
	_presenter = ObjectPresenter.new()
	_presenter.setup(catalog, registry, _cache)
	tree.root.add_child(_presenter)
	_world = _presenter.render_world()
	_ctrl = TexturePreviewController.new(_cache, RenderConfig.safe_default().section("texture_preview"))
	_ctrl.bind(_adapter, _doc)
	_ctrl.bind_objects(_presenter)


func _add(asset_id: String, x: float, z: float) -> String:
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.asset_id = asset_id
	r.asset_version = 1
	r.set_position(x, 0.0, z)
	_doc.put_object(r)
	return r.object_id


func _frame() -> void:
	_cache.poll(4.0)
	_ctrl.service(2.0)
	_presenter.service_frame(4.0)
	await tree.process_frame


func _settle() -> void:
	for i in TIMEOUT_FRAMES:
		await _frame()
		if not _presenter.has_pending_work():
			return
	fail("render work never settled")


func _until(state: String) -> void:
	for i in TIMEOUT_FRAMES:
		if _ctrl.state() == state:
			return
		await _frame()
	fail("preview stayed %s, wanted %s" % [_ctrl.state(), state])


func _frames(n: int) -> void:
	for i in n:
		await _frame()


func _enable(radius: float = -1.0) -> void:
	assert_true(_ctrl.enable_at(Vector3.ZERO, radius).ok)
	for i in TIMEOUT_FRAMES:
		if _ctrl.state() != TexturePreviewController.LOADING:
			return
		await _frame()
	fail("preview stayed LOADING")


func _off() -> void:
	_ctrl.disable("test")
	await _until(TexturePreviewController.OFF)


## Exactly one visible owner per object: a batch slot, a preview node or the promoted node.
func _assert_one_owner(ids: Array, msg: String) -> void:
	assert_eq(int(_world.stats().instances), ids.size(), msg + ": one instance per record")
	for id: String in ids:
		var owners := 0
		owners += 1 if _world.batch_of(id) != null else 0
		owners += 1 if _world.preview_node(id) != null else 0
		owners += 1 if _presenter.node_for(id) != null else 0
		assert_eq(owners, 1, "%s: one owner of %s" % [msg, id.left(6)])


func _widths(node: MeshInstance3D) -> Array:
	var out: Array = []
	for i in node.mesh.get_surface_count():
		var m := node.get_surface_override_material(i) as StandardMaterial3D
		out.append(0 if m == null else m.albedo_texture.get_width())
	out.sort()
	return out


func test_objects_inside_the_area_use_preview_textures_and_the_rest_is_unchanged() -> void:
	_setup_env()
	var a := _add(PINE, 3.0, 2.0)
	var b := _add(PINE, -4.0, 5.0)
	var out := _add(PINE, 90.0, 90.0)
	_presenter.rebuild(_doc)
	await _settle()
	var hash_before := CanonicalEncoder.authored_hash(_doc)
	var revision := _doc.document_revision
	var out_batch := _world.batch_of(out)
	var out_mesh := out_batch.multimesh().mesh
	var low_materials: Array = []
	var low_widths: Array = []
	for i in out_mesh.get_surface_count():
		low_materials.append(out_mesh.surface_get_material(i))
		low_widths.append((out_mesh.surface_get_material(i) as StandardMaterial3D).albedo_texture.get_width())
	var mesh_a := _world.batch_of(a).multimesh().mesh
	var xf_a := _presenter.applied_transform(a)
	await _enable()
	var st := _ctrl.status()
	assert_eq(st.state, TexturePreviewController.ACTIVE, str(st))
	assert_eq(st.objects_previewed, 2)
	assert_false(st.objects_truncated)
	assert_eq(st.object_textures_requested, 2, "foliage and bark of the one asset")
	assert_eq(st.object_textures_ready, 2)
	assert_eq((st.object_textures_missing as Array).size(), 0)
	for id in [a, b]:
		assert_eq(_world.owner_of(id), "preview")
		var node := _world.preview_node(id)
		assert_eq(_widths(node), [512, 1024], "bark 512 px and foliage 1024 px preview tiers")
		assert_true(node.mesh == mesh_a, "geometry tier unchanged")
		assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		assert_eq(node.transform, _presenter.applied_transform(id), "transform unchanged")
	assert_eq(_world.preview_node(a).transform, xf_a)
	assert_true(_world.preview_node(a).get_surface_override_material(0) == _world.preview_node(b).get_surface_override_material(0),
			"one shared variant per material, not one per placement")
	assert_true(_world.owner_of(out).begins_with(PINE + "|"), "outside object keeps its batch")
	var after := _world.batch_of(out)
	assert_true(after == out_batch, "outside batch untouched")
	for i in out_mesh.get_surface_count():
		assert_true(out_mesh.surface_get_material(i) == low_materials[i], "shared low material is the same instance")
		assert_eq((out_mesh.surface_get_material(i) as StandardMaterial3D).albedo_texture.get_width(), low_widths[i])
	assert_eq(CanonicalEncoder.authored_hash(_doc), hash_before)
	assert_eq(_doc.document_revision, revision)
	await _off()
	assert_eq(_world.preview_owner_ids().size(), 0)
	assert_true(_world.batch_of(a) != null and _world.batch_of(b) != null, "back in their batches")
	assert_eq(int(_world.stats().pooled_nodes), 0, "preview pool freed")
	assert_eq(int(_cache.stats().by_kind.preview_texture), 0, "preview textures released")


func test_single_owner_through_select_move_and_disable() -> void:
	_setup_env()
	var a := _add(PINE, 3.0, 2.0)
	var b := _add(PINE, -4.0, 5.0)
	var c := _add(PINE, 90.0, 90.0)
	var ids := [a, b, c]
	_presenter.rebuild(_doc)
	await _settle()
	_assert_one_owner(ids, "settled")
	await _enable()
	_assert_one_owner(ids, "published")
	_presenter.set_selected(a)
	_assert_one_owner(ids, "a selected")
	var promoted := _presenter.node_for(a)
	assert_eq(_widths(promoted), [512, 1024], "the promoted node carries the overrides")
	assert_eq(_world.preview_owner_ids().size(), 2)
	_presenter.set_selected(b)
	_assert_one_owner(ids, "b selected")
	assert_eq(_world.owner_of(a), "preview", "a returns to its preview node")
	assert_eq(_widths(_world.preview_node(a)), [512, 1024])
	var r := _doc.get_object(b).clone()
	r.set_position(6.0, 0.0, 6.0)
	_doc.put_object(r)
	_presenter.sync_object(_doc, b)
	await _frames(3)
	_assert_one_owner(ids, "moved within the area")
	assert_eq(_widths(_presenter.node_for(b)), [512, 1024])
	r.set_position(90.0, 0.0, 80.0)
	_doc.put_object(r)
	_presenter.sync_object(_doc, b)
	await _frames(3)
	_assert_one_owner(ids, "moved out of the area")
	assert_eq(_widths(_presenter.node_for(b)), [0, 0], "no preview outside the captured area")
	assert_eq(_ctrl.status().center, Vector3.ZERO, "the area never moves")
	r.set_position(0.0, 0.0, 4.0)
	_doc.put_object(r)
	_presenter.sync_object(_doc, b)
	await _frames(3)
	assert_eq(_widths(_presenter.node_for(b)), [512, 1024], "moved back in")
	_presenter.set_selected("")
	await _frames(2)
	_assert_one_owner(ids, "deselected")
	assert_eq(_world.owner_of(b), "preview")
	await _off()
	_assert_one_owner(ids, "disabled")
	assert_eq(_world.preview_owner_ids().size(), 0)


func test_assets_without_preview_tier_are_not_missing_and_rejected_textures_limit() -> void:
	_setup_env()
	var broad := _add(BROADLEAF, 2.0, 2.0)
	_presenter.rebuild(_doc)
	await _settle()
	await _enable()
	var st := _ctrl.status()
	assert_eq(st.state, TexturePreviewController.ACTIVE, str(st))
	assert_eq(st.objects_previewed, 0)
	assert_eq(st.object_textures_requested, 0)
	assert_true(_world.batch_of(broad) != null)
	await _off()
	tree.root.remove_child(_presenter)
	_presenter.free()
	_adapter.get_parent().remove_child(_adapter)
	_adapter.free()
	_setup_env(33.0)
	var pine := _add(PINE, 2.0, 2.0)
	_presenter.rebuild(_doc)
	await _settle()
	var batch := _world.batch_of(pine)
	await _enable()
	st = _ctrl.status()
	assert_eq(st.state, TexturePreviewController.LIMITED, str(st))
	assert_eq((st.object_textures_missing as Array).size(), 2)
	assert_eq(st.objects_previewed, 0)
	assert_true(_world.batch_of(pine) == batch, "the object keeps its low-tier batch")
	var mat := batch.multimesh().mesh.surface_get_material(0) as StandardMaterial3D
	assert_true(mat.albedo_texture != null, "never a null texture")
	await _off()


func test_disable_and_world_replacement_while_loading_publish_nothing() -> void:
	_setup_env()
	var a := _add(PINE, 3.0, 2.0)
	_presenter.rebuild(_doc)
	await _settle()
	assert_true(_ctrl.enable_at(Vector3.ZERO).ok)
	assert_eq(_ctrl.state(), TexturePreviewController.LOADING)
	_ctrl.disable("user")
	for i in 120:
		await _frame()
	assert_eq(_ctrl.state(), TexturePreviewController.OFF)
	assert_eq(_world.preview_owner_ids().size(), 0, "late loads discarded")
	assert_true(_world.batch_of(a) != null)
	assert_true(_ctrl.enable_at(Vector3.ZERO).ok)
	_ctrl.on_world_replaced()
	_presenter.rebuild(_doc)
	for i in 120:
		await _frame()
	assert_eq(_ctrl.state(), TexturePreviewController.OFF)
	assert_eq(_world.preview_owner_ids().size(), 0)
	assert_eq(int(_cache.stats().by_kind.preview_texture), 0, "nothing stays resident")


func test_twenty_cycles_do_not_grow_resources() -> void:
	_setup_env()
	for i in 6:
		_add(PINE, float(i) * 3.0 - 7.0, 3.0)
	_presenter.rebuild(_doc)
	await _settle()
	var base := _cache.stats()
	var nodes := int(_world.stats().nodes)
	for cycle in 20:
		await _enable()
		assert_eq(_ctrl.status().objects_previewed, 6, "cycle %d" % cycle)
		await _off()
		await _frames(2)
		var st := _cache.stats()
		assert_eq(int(st.resident_bytes), int(base.resident_bytes), "cycle %d resident bytes" % cycle)
		assert_eq(int(st.entries), int(base.entries), "cycle %d entries" % cycle)
		assert_eq(int(_world.stats().nodes), nodes, "cycle %d nodes" % cycle)
		assert_eq(_world.preview_owner_ids().size(), 0)


func test_pinned_cells_defer_binding_until_released() -> void:
	_setup_env()
	var a := _add(PINE, 3.0, 2.0)
	var b := _add(PINE, -4.0, 5.0)
	_presenter.rebuild(_doc)
	await _settle()
	_presenter.set_pin_check(func(_cell: Vector2i) -> bool: return true)
	await _enable()
	await _frames(5)
	assert_eq(_world.preview_owner_ids().size(), 0, "publishing waits while the cells are pinned")
	assert_eq(_ctrl.status().objects_deferred, 2)
	_presenter.set_pin_check(Callable())
	await _frames(3)
	assert_eq(_world.preview_owner_ids().size(), 2)
	assert_eq(_world.owner_of(a), "preview")
	_presenter.set_pin_check(func(_cell: Vector2i) -> bool: return true)
	_ctrl.disable("user")
	assert_eq(_world.preview_owner_ids().size(), 2, "restoring waits for the pins too")
	assert_true(_world.batch_of(b) == null)
	_presenter.set_pin_check(Callable())
	await _until(TexturePreviewController.OFF)
	await _frames(3)
	assert_eq(_world.preview_owner_ids().size(), 0)
	assert_true(_world.batch_of(a) != null and _world.batch_of(b) != null)


func test_preview_membership_is_bounded() -> void:
	_setup_env()
	var ids: Array = []
	for i in 200:
		ids.append(_add(PINE, float(i % 15) * 2.0 - 14.0, float(i / 15) * 2.0 - 13.0))
	_presenter.rebuild(_doc)
	await _settle()
	await _enable()
	var st := _ctrl.status()
	assert_eq(st.objects_previewed, ObjectPreviewParticipant.MAX_PREVIEW_OBJECTS)
	assert_true(st.objects_truncated)
	print("object preview publish 128 objects: %.2f ms (HOST)" % float(st.objects_build_ms))
	assert_eq(_world.preview_owner_ids().size(), 128)
	_assert_one_owner(ids, "truncated")
	var t0 := Time.get_ticks_usec()
	await _off()
	print("object preview 200 objects: disable+off %.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
