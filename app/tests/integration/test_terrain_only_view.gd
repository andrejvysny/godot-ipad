extends UiTestCase
## View changes must preserve authored data and selection while blocking first-contact object edits.


func _record(s: EditorSession) -> ObjectRecord:
	var record := ObjectRecord.new()
	record.object_id = ObjectRecord.new_uuid_v4()
	record.binding_id = s.document.assets.bundled_binding_for(BOULDER)
	record.set_position(0.0, 0.0, 0.0)
	s.document.put_object(record)
	s.presenter.sync_object(s.document, record.object_id)
	return record


func test_overview_mask_preserves_identity_and_authored_state() -> void:
	var s := await _start()
	var record := _record(s)
	s.tools.select(record.object_id)
	for i in 300:
		if not s.presenter.has_pending_work():
			break
		await tree.process_frame
	assert_false(s.presenter.has_pending_work(), "shared cache and presenter settle")
	var before := BenchReport.authored_state(s)
	var package_before := _export_payloads(s, "before")
	var render := s.render_state()
	render.view.force_state(RenderViewState.TERRAIN_ONLY)
	render.service_frame(2.0)
	assert_eq(render.view.policy.state, RenderViewState.TERRAIN_ONLY)
	assert_eq(s.tools.selected_id(), record.object_id)
	assert_false(s.presenter.render_world().promoted_node().visible)
	assert_false(s.presenter.has_ghost_visible())
	assert_eq(int(s.presenter.render_stats().visible_instances), 0)
	assert_eq(int(render.overview.stats().proxy_triangles), 0)
	assert_eq(s.presenter.pick(Vector3(0.0, 20.0, 0.0), Vector3.DOWN).id, "")
	s.set_vegetation_hidden(true)
	s.set_vegetation_hidden(false)
	assert_false(s.presenter.render_world().promoted_node().visible)
	assert_eq(BenchReport.authored_state(s), before)
	assert_eq(_export_payloads(s, "after"), package_before, "exported entry bytes unchanged")
	render.view.force_state(RenderViewState.LOCAL)
	render.service_frame(2.0)
	assert_eq(s.tools.selected_id(), record.object_id)
	assert_true(s.presenter.render_world().promoted_node().visible, "selected mesh restores")
	assert_eq(BenchReport.authored_state(s), before)


func test_placement_first_contact_only_focuses() -> void:
	var s := await _start()
	var render := s.render_state()
	render.view.force_state(RenderViewState.TERRAIN_ONLY)
	render.service_frame(2.0)
	var before := BenchReport.authored_state(s)
	var hit := TerrainHit.new()
	hit.ok = true
	hit.position = Vector3.ZERO
	var sample := PointerSample.new()
	var operation := PlaceOperation.new(s._tool_ctx, s.catalog.get_asset(BOULDER), false)
	operation.begin(sample, hit)
	operation.move(sample, hit)
	assert_eq(operation.end(sample, hit, false), null)
	assert_eq(operation.created_id(), "")
	assert_false(s.presenter.has_ghost_visible())
	assert_eq(BenchReport.authored_state(s), before)
	assert_eq(render.view.policy.state, RenderViewState.LOCAL)


func _export_payloads(s: EditorSession, name: String) -> Dictionary:
	var generation := scratch_dir().path_join(name)
	assert_empty_string(WorldCodec.write_generation(generation, s.document, WorldCodec.default_created_with()))
	var package := scratch_dir().path_join(name + ".worldpoc")
	assert_empty_string(WorldPackage.export_package(generation, package, s.catalog))
	var reader := ZIPReader.new()
	assert_eq(reader.open(package), OK)
	var entries: Dictionary = {}
	for path: String in reader.get_files():
		entries[path] = reader.read_file(path)
	reader.close()
	return entries
