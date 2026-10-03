extends ScatterTestCase
## ScatterRenderer overview interface (members, covering, overview_changed), BATCH-07 for scatter and the
## settle rule of meaningful roles.


func _tilted_doc_layer() -> void:
	var region := doc.get_region(Vector2i(0, 0))
	for i in region.heights.size():
		region.heights[i] = 0.3 * float(i % 256) * WorldConstants.SAMPLE_SPACING
	var layer := ScatterLayer.new()
	layer.add(doc.assets.bundled_binding_for(SPRUCE), 10.0, 10.0, 0.7, 1.5, ScatterLayer.FLAG_TILT)
	layer.add(doc.assets.bundled_binding_for(BOULDER), 20.0, 12.0, 0.0, 0.8, 0)
	layer.add(doc.assets.bundled_binding_for(GRASS), 12.0, 12.0, 0.0, 1.0, 0)
	layer.add(doc.assets.bundled_binding_for(SPRUCE), 100.0, 100.0, 0.0, 1.0, 0)
	doc.scatter = layer


func test_overview_members_carry_terrain_y_tilt_and_scale_and_exclude_ground_cover() -> void:
	_tilted_doc_layer()
	_build()
	var members := renderer.overview_members(Rect2(0.0, 0.0, 64.0, 64.0))
	assert_eq(members.size(), 2, "spruce and boulder only")
	for m: Dictionary in members:
		assert_true(m.asset_id == SPRUCE or m.asset_id == BOULDER)
		var xf: Transform3D = m.xf
		assert_near(xf.origin.y, doc.sample_height(xf.origin.x, xf.origin.z), 1e-4, "terrain Y")
		if m.asset_id == SPRUCE:
			assert_near(xf.basis.get_scale().x, 1.5, 1e-4, "scale")
			assert_vec_near(xf.basis.y.normalized(), doc.sample_normal(10.0, 10.0), 1e-4, "tilt")
	assert_eq(renderer.overview_members(Rect2(80.0, 80.0, 40.0, 40.0)).size(), 1)
	assert_eq(renderer.overview_members(Rect2(300.0, 300.0, 10.0, 10.0)).size(), 0)


func test_covered_cells_are_hidden_but_stay_built_and_ground_cover_is_never_covered() -> void:
	_tilted_doc_layer()
	_build()
	var cell := ScatterRenderer.cell_of(10.0, 10.0)
	var builds := int(renderer.stats().cell_builds)
	var uploads := int(renderer.stats().uploads)
	renderer.set_cells_covered(Rect2(0.0, 0.0, 64.0, 64.0), true)
	assert_false(renderer.multimesh_for(cell, SPRUCE).visible)
	assert_false(renderer.multimesh_for(ScatterRenderer.cell_of(20.0, 12.0), BOULDER).visible)
	assert_true(renderer.multimesh_for(renderer.cell_for(GRASS, 12.0, 12.0), GRASS).visible, "decorative cells are never covered")
	assert_true(renderer.multimesh_for(ScatterRenderer.cell_of(100.0, 100.0), SPRUCE).visible, "cells outside stay")
	assert_eq(renderer.rendered_count(cell, SPRUCE), 1, "kept built")
	renderer.flush()
	assert_eq(renderer.stats().cell_builds, builds, "covering rebuilds nothing")
	assert_eq(renderer.stats().uploads, uploads)
	renderer.set_cells_covered(Rect2(0.0, 0.0, 64.0, 64.0), false)
	assert_true(renderer.multimesh_for(cell, SPRUCE).visible)
	assert_eq(renderer.stats().uploads, uploads, "showing again uploads nothing")


func test_overview_changed_for_edits_and_redrapes_but_not_for_density_or_visibility() -> void:
	_tilted_doc_layer()
	var emitted: Array[Rect2] = []
	renderer.overview_changed.connect(func(r: Rect2) -> void: emitted.append(r))
	_build()
	assert_eq(emitted.size(), 1, "rebuild_all reports the whole layout")
	assert_eq(emitted[0], doc.layout.extent_rect())
	emitted.clear()
	doc.scatter.add(doc.assets.bundled_binding_for(SPRUCE), 100.0, 100.0, 0.0, 1.0, 0)
	renderer.mark_rect(Rect2(90.0, 90.0, 20.0, 20.0))
	assert_eq(emitted.size(), 1, "a meaningful instance was added")
	assert_true(emitted[0].has_point(Vector2(100.0, 100.0)))
	emitted.clear()
	doc.scatter.add(doc.assets.bundled_binding_for(GRASS), 101.0, 101.0, 0.0, 1.0, 0)
	renderer.mark_rect(Rect2(90.0, 90.0, 20.0, 20.0))
	assert_eq(emitted.size(), 0, "ground cover is not part of the overview")
	renderer.mark_rect(Rect2(0.0, 0.0, 64.0, 64.0), true)
	assert_eq(emitted.size(), 1, "a re-drape under meaningful instances")
	emitted.clear()
	renderer.mark_rect(Rect2(-300.0, -300.0, 20.0, 20.0), true)
	assert_eq(emitted.size(), 0, "a re-drape over nothing")
	renderer.set_lod_profile(full_profile(0.25, 0.5, 30.0))
	renderer.set_vegetation_hidden(true, RenderConfig.load_from().vegetation_rule())
	renderer.set_cells_covered(Rect2(0.0, 0.0, 64.0, 64.0), true)
	_camera_at(Vector3(0.0, 10.0, 0.0), Vector3(20.0, 0.0, 20.0))
	renderer.set_camera(camera)
	renderer.flush()
	camera.global_position = Vector3(40.0, 10.0, 0.0)
	renderer.flush()
	assert_eq(emitted.size(), 0, "profile, visibility, covering and camera changes are silent")
	renderer.mark_all()
	assert_eq(emitted.size(), 1, "mark_all reports the whole layout")
	assert_eq(emitted[0], doc.layout.extent_rect())


# --- BATCH-07 and meaningful roles --------------------------------------------------------------

func test_unchanged_scene_has_no_uploads_or_rebuilds_after_settling() -> void:
	_camera_at(Vector3(0.0, 30.0, 40.0), Vector3(0.0, 0.0, 0.0))
	renderer.set_camera(camera)
	_build()
	var before := renderer.stats()
	var nodes := renderer.get_children()
	for i in 40:
		renderer.service_frame(1.0)
	for i in 10:
		renderer.service_frame(1.0)
	assert_false(renderer.has_dirty())
	var after := renderer.stats()
	assert_eq(after.uploads, before.uploads, "no instance buffer uploads")
	assert_eq(after.cell_builds, before.cell_builds, "no cell rebuilds")
	assert_eq(renderer.get_children(), nodes, "no node churn")
	renderer.mark_rect(Rect2(-20.0, -20.0, 40.0, 40.0), true)
	renderer.flush()
	assert_eq(renderer.stats().uploads, before.uploads, "a re-drape that changes nothing uploads nothing")


func test_meaningful_roles_follow_distance_only_after_the_camera_settles() -> void:
	var layer := _layer_of([SPRUCE], 10.0, 10.0)
	doc.scatter = layer
	_camera_at(Vector3(10.0, 5.0, 12.0), Vector3(10.0, 0.0, 10.0))
	renderer.set_camera(camera)
	var legacy := RenderConfig.load_from().profile("detailed")
	legacy.size_policy_enabled = false
	renderer.set_lod_profile(legacy)
	_build()
	var cell := ScatterRenderer.cell_of(10.0, 10.0)
	var near_mesh := renderer.multimesh_for(cell, SPRUCE).multimesh.mesh
	camera.global_position = Vector3(10.0, 5.0, 400.0)  # far: the role coarsens
	renderer.service_frame(1.0)
	assert_eq(renderer.multimesh_for(cell, SPRUCE).multimesh.mesh, near_mesh, "no role change while the camera moves")
	renderer.flush()
	var far_mesh := renderer.multimesh_for(cell, SPRUCE).multimesh.mesh
	assert_ne(far_mesh, near_mesh, "coarser tier after settling")
	assert_true(far_mesh.resource_path.contains("far"), far_mesh.resource_path)
	assert_eq(renderer.rendered_count(cell, SPRUCE), 1, "never disappears")
