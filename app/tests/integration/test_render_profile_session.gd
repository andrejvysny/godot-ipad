extends UiTestCase
## Render profiles in the live session (rendering spec §4, §13.1, §15.4, §16.5): PROFILE-01..05, UI-02 (partial),
## cheap status, and the performance indicator / menu.

const SPRUCE := "nature.tree.spruce_a"
const GRASS := "nature.cover.grass_tuft_a"
const PEBBLES := "nature.rock.pebbles_a"
const SCALES := {"performance": 0.65, "balanced": 0.75, "detailed": 1.0}


func _viewport_scale(s: EditorSession) -> float:
	return s.get_viewport().scaling_3d_scale


## Starts a Pencil stroke (an open operation) in the middle of the world with the paint tool.
func _begin_stroke(s: EditorSession) -> void:
	await _tool(s, "paint", false)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, _centre_world(s))
	assert_true(s.tools.has_active_operation(), "stroke is open")


func _end_stroke(s: EditorSession) -> void:
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, _centre_world(s))
	assert_false(s.tools.has_active_operation(), "stroke is closed")


func _add_scatter(s: EditorSession, ids: Array) -> void:
	var x := -60.0
	for id: String in ids:
		s.document.scatter.add(id, s.catalog.get_asset(id).version, x, 10.0, 0.0, 1.0, 0)
		x += 25.0
	var wide := s.render_config.profile("performance")  # ground cover is drawn near the camera and thinned: draw all
	wide.size_policy_enabled = false  # isolate vegetation and shadow rules from size eligibility
	wide.ground_cover_radius_m = 100000.0
	wide.decorative_density_outside = 1.0
	wide.decorative_density_active = 1.0
	s.layers.set_lod_profile(wide)
	s.layers.rebuild(s.document)
	assert_true(s.layers.settle_now(), "scatter settles")


# --- PROFILE-01, -02, -03 ----------------------------------------------------------------------

func test_boot_applies_performance_and_ignores_previous_session() -> void:
	var s := await _start()
	assert_eq(s.render_profiles.active_name(), "performance")
	assert_eq(s.render_config.error, "")
	var vp := s.get_viewport()
	assert_eq(vp.scaling_3d_mode, Viewport.SCALING_3D_MODE_BILINEAR)
	assert_near(vp.scaling_3d_scale, 0.65, 1e-6)
	assert_eq(vp.msaa_3d, Viewport.MSAA_DISABLED)
	assert_eq(vp.screen_space_aa, Viewport.SCREEN_SPACE_AA_DISABLED)
	assert_false(vp.use_taa)
	assert_near(vp.mesh_lod_threshold, 4.0, 1e-6)
	assert_eq(Engine.max_fps, 0)
	assert_eq(s.request_profile("detailed").status, "applied")
	assert_near(vp.scaling_3d_scale, 1.0, 1e-6)
	assert_eq(Engine.max_fps, 30)
	sessions.erase(s)
	tree.root.remove_child(s)
	s.free()
	await _frames(2)
	var second := await _start()
	assert_eq(second.render_profiles.active_name(), "performance", "nothing is restored")
	assert_near(_viewport_scale(second), 0.65, 1e-6)
	assert_eq(Engine.max_fps, 0)


func test_slow_frames_never_change_the_profile() -> void:
	var s := await _start()
	var generation := s.render_profiles.generation()
	for i in 600:
		s.frames.add(100.0)
	await _frames(10)
	assert_eq(s.render_profiles.active_name(), "performance")
	assert_eq(s.render_profiles.generation(), generation)
	assert_near(_viewport_scale(s), 0.65, 1e-6)
	assert_eq(Engine.max_fps, 0)
	assert_true(s.status().frame_p50_ms >= 0.0)


func test_profile_request_during_a_stroke_is_deferred_and_applied_once() -> void:
	var s := await _start()
	await _begin_stroke(s)
	var applied: Array = []
	s.render_profiles.profile_applied.connect(func(name: String) -> void: applied.append(name))
	var result := s.request_profile("detailed")
	assert_eq(result.status, "pending")
	assert_eq(s.render_profiles.pending_name(), "detailed")
	assert_near(_viewport_scale(s), 0.65, 1e-6)
	assert_eq(s.status().profile_pending, "detailed")
	assert_eq(s.last_message, "Detailed applies after the current edit")
	await _end_stroke(s)
	await _frames(2)
	assert_eq(applied, ["detailed"], "applied exactly once")
	assert_near(_viewport_scale(s), 1.0, 1e-6)
	assert_eq(s.render_profiles.pending_name(), "")
	assert_eq(s.status().profile, "detailed")
	assert_eq(s.last_message, "Profile: Detailed")


func test_profile_request_applies_after_a_cancelled_operation() -> void:
	var s := await _start()
	await _begin_stroke(s)
	assert_eq(s.request_profile("balanced").status, "pending")
	s.cancel_active()
	await _frames(2)
	assert_eq(s.render_profiles.active_name(), "balanced")
	assert_near(_viewport_scale(s), 0.75, 1e-6)


func test_status_has_profile_keys_and_caches_the_slow_part() -> void:
	var s := await _start()
	var status := s.status()
	for key in ["profile", "profile_label", "profile_pending", "profile_target_fps", "render_scale",
			"vegetation_hidden", "fps", "frame_p50_ms", "frame_p95_ms", "brush_p95_ms", "render", "terrain_stats"]:
		assert_true(status.has(key), "missing status key " + key)
	assert_eq(status.profile, "performance")
	assert_eq(status.profile_label, "Performance")
	assert_eq(status.profile_target_fps, 60)
	assert_false(status.vegetation_hidden)
	for i in 600:
		s.frames.add(20.0)
	var cached := s.status()
	assert_eq(cached.frame_p50_ms, status.frame_p50_ms, "slow part is cached between refreshes")
	s.render_state().invalidate_slow_status()
	var fresh := s.status()
	assert_near(fresh.frame_p50_ms, 20.0, 1e-6)
	assert_near(fresh.fps, 50.0, 1e-6)


# --- PROFILE-04 ----------------------------------------------------------------------------------

func test_no_production_path_casts_shadows_in_any_profile() -> void:
	var s := await _start("stress_100")
	_add_scatter(s, [SPRUCE, GRASS, PEBBLES, UiTestCase.BOULDER])
	assert_true(s.presenter.authored_object_count() > 0)
	assert_true(s.layers.stats().multimeshes >= 4, "scatter nodes exist")
	for name in SCALES:
		assert_ne(s.request_profile(name).status, "pending")
		await _frames(2)
		assert_eq(s.render_profiles.active_name(), name)
		_assert_no_shadows(s, name)


func _inside_terrain3d(node: Node) -> bool:
	var parent := node.get_parent()
	while parent != null:
		if parent.get_class() == "Terrain3D":
			return true
		parent = parent.get_parent()
	return false


func _assert_no_shadows(s: EditorSession, name: String) -> void:
	assert_false(s.sun.shadow_enabled, name + ": sun")
	for light: Node in s.find_children("*", "Light3D", true, false):
		assert_false((light as Light3D).shadow_enabled, name + ": " + str(light.get_path()))
	var geometry := s.find_children("*", "GeometryInstance3D", true, false)
	assert_true(geometry.size() > 4, name + ": geometry was found")
	for node: Node in geometry:
		if _inside_terrain3d(node):
			continue
		assert_eq((node as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
				"%s: %s" % [name, node.get_path()])
	if s.terrain is TerrainAdapter:
		var t3d: Node = s.terrain.find_child("Terrain3D", true, false)
		assert_true(t3d != null, "Terrain3D exists")
		assert_eq(t3d.get("cast_shadows"), RenderingServer.SHADOW_CASTING_SETTING_OFF, name + ": Terrain3D")
	var environments := s.find_children("*", "WorldEnvironment", true, false)
	assert_eq(environments.size(), 1)
	var env: Environment = (environments[0] as WorldEnvironment).environment
	assert_false(env.glow_enabled or env.ssao_enabled or env.ssil_enabled or env.ssr_enabled, name + ": screen effects")
	assert_false(env.sdfgi_enabled or env.fog_enabled or env.volumetric_fog_enabled, name + ": gi and fog")
	assert_eq(env.tonemap_mode, Environment.TONE_MAPPER_LINEAR)


# --- UI-02 (partial) -----------------------------------------------------------------------------

func test_hide_vegetation_is_presentation_only() -> void:
	var s := await _start()
	_add_scatter(s, [SPRUCE, GRASS, PEBBLES, UiTestCase.BOULDER])
	var hash_before := s.authored_hash()
	var revision := s.document.document_revision
	var history := s.history.size()
	s.set_vegetation_hidden(true)
	assert_true(s.vegetation_hidden())
	assert_true(s.status().vegetation_hidden)
	var x := -60.0
	var node_by_asset := {}
	for id: String in [SPRUCE, GRASS, PEBBLES, UiTestCase.BOULDER]:
		node_by_asset[id] = s.layers.scatter.multimesh_for(s.layers.scatter.cell_for(id, x, 10.0), id)
		assert_true(node_by_asset[id] != null, id + " is drawn")
		x += 25.0
	for id: String in [SPRUCE, GRASS]:
		assert_false((node_by_asset[id] as MultiMeshInstance3D).visible, id + " hidden")
	for id: String in [PEBBLES, UiTestCase.BOULDER]:
		assert_true((node_by_asset[id] as MultiMeshInstance3D).visible, id + " stays visible")
	assert_eq(s.authored_hash(), hash_before)
	assert_eq(s.document.document_revision, revision)
	assert_eq(s.history.size(), history)
	s.set_vegetation_hidden(false)
	for node: Node in s.layers.scatter.get_children():
		assert_true((node as MultiMeshInstance3D).visible)


# --- PROFILE-05 ----------------------------------------------------------------------------------

## A selectable object well inside the viewport, clear of UI panels, whose centre picks itself.
func _selectable(s: EditorSession) -> String:
	var camera := s.rig.get_camera()
	var vp := tree.root.get_visible_rect().size
	for id in s.presenter.object_ids():
		var centre := s.presenter.world_bounds(id).get_center()
		if camera.is_position_behind(centre):
			continue
		var pos := camera.unproject_position(centre)
		if not Rect2(vp * 0.25, vp * 0.5).has_point(pos):
			continue
		var over_ui := false
		for panel in _ui(s).registered_panels():
			over_ui = over_ui or (panel.is_visible_in_tree() and _rect(panel).has_point(pos))
		var hit := s.presenter.pick(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
		if not over_ui and hit.id == id:
			return id
	return ""


func test_input_and_picking_stay_aligned_at_every_profile_scale() -> void:
	var s := await _start("stress_100")
	var id := _selectable(s)
	if not assert_ne(id, "", "a selectable object is on screen"):
		return
	var camera := s.rig.get_camera()
	var position := s.document.get_object(id).position
	var terrain_point := Vector3(position[0], s.document.sample_height(position[0], position[2]), position[2])
	for name in SCALES:
		s.request_profile(name)
		await _frames(2)
		assert_near(_viewport_scale(s), float(SCALES[name]), 1e-6, name)
		var screen := camera.unproject_position(terrain_point)
		var hit := TerrainPicker.raycast(s.document, camera.project_ray_origin(screen), camera.project_ray_normal(screen))
		assert_true(hit.ok, name + ": terrain hit")
		assert_true(hit.position.distance_to(terrain_point) < 1e-3, "%s: ray hit %s want %s" % [name, hit.position, terrain_point])
		s.tools.set_tool("select")
		s.tools.select("")
		await _frames(2)
		var centre := camera.unproject_position(s.presenter.world_bounds(id).get_center())
		await _world_tap(s, centre)
		assert_eq(s.tools.selected_id(), id, name + ": tap selects the object under the Pencil")


# --- indicator and menu --------------------------------------------------------------------------

func test_indicator_caption_and_warning() -> void:
	var s := await _start()
	var indicator := _ui(s).perf_indicator()
	var base := {"profile_label": "Performance", "fps": 0.0, "profile_pending": "", "profile_target_fps": 60}
	assert_eq(indicator.caption(base), "Performance · — fps")
	assert_eq(indicator.caption(base.merged({"fps": 58.6}, true)), "Performance · 59 fps")
	assert_eq(indicator.caption(base.merged({"fps": 58.6, "profile_pending": "detailed"}, true)),
			"Performance · 59 fps -> Detailed")
	assert_true(PerfIndicator.is_below_target(50.0, 60))
	assert_false(PerfIndicator.is_below_target(55.0, 60))
	assert_false(PerfIndicator.is_below_target(0.0, 60), "no measurement is not a warning")
	for i in 600:
		s.frames.add(20.0)
	s.render_state().invalidate_slow_status()
	_ui(s).refresh()
	assert_eq(indicator.text(), "Performance · 50 fps")
	assert_true(indicator.is_warning())
	for i in 600:
		s.frames.add(10.0)
	s.render_state().invalidate_slow_status()
	_ui(s).refresh()
	assert_eq(indicator.text(), "Performance · 100 fps")
	assert_false(indicator.is_warning())
	assert_eq(s.render_profiles.active_name(), "performance", "a warning never changes anything")


func test_menu_switches_profiles_and_closes() -> void:
	var s := await _start()
	var ui := _ui(s)
	assert_true(ui.registered_panels().has(ui.perf_indicator()) and ui.registered_panels().has(ui.perf_menu()))
	assert_false(ui.perf_menu().visible)
	await _pencil_click(s, ui.perf_indicator().button())
	assert_true(ui.perf_menu().visible)
	assert_true(ui.perf_indicator().button().button_pressed)
	assert_true(ui.perf_menu().profile_button("performance").button_pressed)
	assert_false(ui.perf_menu().profile_button("balanced").button_pressed)
	assert_eq(ui.perf_menu().info_text(), "Target 60 fps · 3D 65%")
	await _pencil_click(s, ui.perf_menu().profile_button("balanced"))
	assert_eq(s.render_profiles.active_name(), "balanced")
	assert_false(ui.perf_menu().visible, "menu closes after a choice")
	assert_true(ui.perf_indicator().text().begins_with("Balanced"), ui.perf_indicator().text())
	await _pencil_click(s, ui.perf_indicator().button())
	assert_eq(ui.perf_menu().info_text(), "Target 60 fps · 3D 75%")
	assert_true(ui.perf_menu().profile_button("balanced").button_pressed)
	s.tools.dismissed.emit()
	assert_false(ui.perf_menu().visible, "Esc closes the menu")
	assert_eq(s.history.size(), 0)


func test_indicator_and_menu_show_the_pending_profile() -> void:
	var s := await _start()
	var ui := _ui(s)
	await _begin_stroke(s)
	s.request_profile("detailed")
	await _frames(2)
	assert_true(ui.perf_indicator().text().ends_with("-> Detailed"), ui.perf_indicator().text())
	assert_true(ui.perf_menu().profile_button("detailed").text.contains("after edit"))
	await _end_stroke(s)
	await _frames(2)
	assert_true(ui.perf_indicator().text().begins_with("Detailed"), ui.perf_indicator().text())
	assert_false(ui.perf_menu().profile_button("detailed").text.contains("after edit"))


func test_menu_hide_vegetation_switch() -> void:
	var s := await _start()
	var ui := _ui(s)
	_add_scatter(s, [SPRUCE, PEBBLES])
	await _pencil_click(s, ui.perf_indicator().button())
	await _pencil_click(s, ui.perf_menu().vegetation_switch())
	assert_true(s.vegetation_hidden())
	assert_true(ui.perf_menu().vegetation_switch().button_pressed)
	await _pencil_click(s, ui.perf_menu().vegetation_switch())
	assert_false(s.vegetation_hidden())
	assert_eq(s.history.size(), 0)
	assert_eq(s.document.document_revision, 0)


func test_perf_panels_layout_between_history_and_actions() -> void:
	var s := await _start()
	var ui := _ui(s)
	for size in SIZES:
		ui.layout_override = size
		ui.layout()
		var indicator := _rect(ui.perf_indicator())
		var actions := _rect(ui.action_pill())
		var history := _rect(ui.history_tiles())
		assert_near(indicator.position.y, EditorUI.M, 0.5)
		assert_near(indicator.end.x + EditorUI.GAP, actions.position.x, 0.5, "immediately left of the actions")
		assert_true(history.end.x <= indicator.position.x - EditorUI.GAP + 0.5, "history clears the indicator at %s" % size)
		assert_true(_rect(ui.world_pill()).end.x < history.position.x)
		ui.perf_menu().visible = true
		ui.layout()
		var menu := _rect(ui.perf_menu())
		assert_near(menu.end.x, indicator.end.x, 0.5, "menu is right-aligned with the indicator")
		assert_true(menu.position.y >= indicator.end.y)
		ui.perf_menu().visible = false
	ui.layout_override = Vector2.ZERO
