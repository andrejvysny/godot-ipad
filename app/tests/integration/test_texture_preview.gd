extends TexturePreviewTestCase


func test_enable_captures_fixed_area_and_changes_only_preview_uniforms() -> void:
	var ctrl := _make(_mixed_doc())
	var hash_before := CanonicalEncoder.authored_hash(_doc)
	var revision := _doc.document_revision
	var rules_before := _adapter.rule_uniforms()
	var debug_before := _adapter.debug_uniforms()
	assert_eq(ctrl.state(), TexturePreviewController.OFF)
	assert_false(_adapter.preview_uniforms().preview_enabled)
	var result := ctrl.enable_at(Vector3(2.0, 0.0, 1.0))
	assert_true(result.ok, str(result))
	assert_eq(ctrl.state(), TexturePreviewController.LOADING)
	await _drive(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.ACTIVE, str(ctrl.status()))
	var st := ctrl.status()
	assert_eq(st.center, Vector3(2.0, 0.0, 1.0))
	assert_eq(st.radius, 20.0, "radius from config texture_preview.radius_m")
	assert_eq(st.generation, 1)
	assert_eq(st.requested, st.ready)
	assert_true(int(st.bytes) > 0)
	var u := _adapter.preview_uniforms()
	assert_true(u.preview_enabled)
	assert_eq(u.preview_area, Vector4(2.0, 1.0, 20.0, 1.5))
	assert_eq(CanonicalEncoder.authored_hash(_doc), hash_before, "authored content untouched")
	assert_eq(_doc.document_revision, revision)
	assert_eq(_adapter.verify_matches_document(_doc).size(), 0, "terrain bytes untouched")
	assert_eq(_adapter.rule_uniforms(), rules_before)
	assert_eq(_adapter.debug_uniforms(), debug_before)
	ctrl.disable("user")
	assert_eq(ctrl.state(), TexturePreviewController.RELEASING)
	assert_false(_adapter.preview_uniforms().preview_enabled, "low-tier bindings restored immediately")
	assert_false(ctrl.enable_at(Vector3.ZERO).ok, "no enable while releasing")
	await _off(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.OFF)
	assert_eq(CanonicalEncoder.authored_hash(_doc), hash_before)
	assert_eq(_adapter.verify_matches_document(_doc).size(), 0)


func test_enable_refuses_without_a_valid_centre_and_clamps_to_the_world() -> void:
	var ctrl := _make(_mixed_doc())
	assert_false(ctrl.enable_at(Vector3(NAN, 0.0, 0.0)).ok)
	assert_eq(ctrl.state(), TexturePreviewController.OFF)
	assert_eq(ctrl.generation, 0, "a refused enable captures nothing")
	var far := ctrl.enable_at(Vector3(5000.0, 3.0, -5000.0))
	assert_true(far.ok)
	var c: Vector3 = ctrl.status().center
	var rect := _doc.layout.world_rect()
	assert_eq(c.x, rect.end.x, "x clamped to the world")
	assert_eq(c.z, rect.position.y, "z clamped to the world")
	assert_eq(c.y, 3.0)
	assert_false(ctrl.enable_at(Vector3.ZERO).ok, "already on")
	ctrl.disable("test")
	var unbound := TexturePreviewController.new(_cache, {})
	assert_false(unbound.enable_at(Vector3.ZERO).ok, "no world bound")


# --- PREVIEW-03 (terrain part) ---------------------------------------------------------------------

func test_preview_binds_area_and_layer_map_and_leaves_low_arrays_untouched() -> void:
	var ctrl := _make(_mixed_doc())
	var assets := _adapter.get_terrain().assets
	var rid_before := assets.get_albedo_array_rid()
	var count_before := assets.get_texture_count()
	ctrl.enable_at(Vector3(0.0, 0.0, 0.0), 12.0)
	await _drive(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.ACTIVE)
	var u := _adapter.preview_uniforms()
	var layers: Vector4i = u.preview_layer
	var mapped := 0
	for slot in 4:
		mapped += 1 if layers[slot] >= 0 else 0
	assert_eq(mapped, ctrl.status().slots.size(), "one layer per previewed slot")
	for slot: int in ctrl.status().slots:
		assert_true(layers[slot] >= 0 and layers[slot] < (u.preview_albedo_array as Texture2DArray).get_layers())
	assert_eq((u.preview_albedo_array as Texture2DArray).get_layers(), (u.preview_normal_array as Texture2DArray).get_layers())
	assert_eq(u.preview_area, Vector4(0.0, 0.0, 12.0, 1.5))
	assert_eq(assets.get_albedo_array_rid(), rid_before, "low-tier array is the same object")
	assert_eq(assets.get_texture_count(), count_before)
	assert_true(ctrl.status().build_ms >= 0.0)
	print("    preview publish: arrays %.2f ms + images %.2f ms for %d slots, %d bytes estimated" % [
		ctrl.status().build_ms, ctrl.status().image_ms, ctrl.status().slots.size(), ctrl.status().bytes])
	ctrl.disable("test")


# --- PREVIEW-04 ----------------------------------------------------------------------------------

func test_missing_texture_is_limited_and_keeps_low_tier_for_that_slot() -> void:
	var ctrl := _make_with(_mixed_doc(), _paths_without(WorldConstants.MATERIAL_DIRT, "albedo"))
	assert_true(ctrl.enable_at(Vector3(0.0, 0.0, 0.0)).ok)
	await _drive(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.LIMITED, str(ctrl.status()))
	var st := ctrl.status()
	assert_eq(st.missing, ["dirt_albedo"])
	assert_eq(TexturePreviewController.status_text(st), "Limited · 1 textures missing")
	var u := _adapter.preview_uniforms()
	var layers: Vector4i = u.preview_layer
	assert_eq(layers[WorldConstants.MATERIAL_DIRT], -1, "dirt keeps the low tier")
	assert_true(layers[WorldConstants.MATERIAL_GRASS] >= 0, "grass is previewed")
	assert_true(u.preview_albedo_array != null and u.preview_normal_array != null, "no null binding")
	ctrl.disable("test")
	await _off(ctrl)


func test_every_texture_missing_is_an_error_and_binds_nothing() -> void:
	var sources := TerrainPreviewParticipant.default_sources()
	for slot: int in sources:
		sources[slot] = {"albedo": "res://assets/terrain/preview/none_a.png", "normal": "res://assets/terrain/preview/none_n.png"}
	var ctrl := _make_with(WorldDocument.create_flat(0.0, AUTO), sources)
	ctrl.enable_at(Vector3.ZERO)
	await _drive(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.ERROR)
	assert_true(str(ctrl.status().reason) != "")
	assert_true(TexturePreviewController.status_text(ctrl.status()).begins_with("Error: "))
	assert_false(_adapter.preview_uniforms().preview_enabled)
	assert_true(_adapter.preview_uniforms().preview_albedo_array == null)
	await tree.process_frame
	assert_true(ctrl.enable_at(Vector3.ZERO).ok, "ERROR can be retried")
	ctrl.disable("test")


func test_over_budget_request_is_limited_not_fatal() -> void:
	var ctrl := _make(_mixed_doc())
	var budgets := _budgets()
	budgets.preview_mib = 9.0  # two 4 MiB estimates fit, a third does not
	_cache = RenderAssetCache.new(budgets)
	var tight := TexturePreviewController.new(_cache, RenderConfig.safe_default().section("texture_preview"))
	tight.bind(_adapter, _doc)
	tight.enable_at(Vector3.ZERO)
	await _drive(tight)
	assert_eq(tight.state(), TexturePreviewController.LIMITED, str(tight.status()))
	assert_true(int(tight.status().ready) < int(tight.status().requested))
	tight.disable("test")
	ctrl.disable("test")


# --- PREVIEW-05 ----------------------------------------------------------------------------------

func test_disable_during_loading_discards_late_results() -> void:
	var ctrl := _make(_mixed_doc())
	var pre := _cache.stats()
	ctrl.enable_at(Vector3.ZERO)
	ctrl.service(2.0)  # starts the first loads
	assert_eq(ctrl.state(), TexturePreviewController.LOADING)
	var g := ctrl.generation
	ctrl.disable("user")
	assert_eq(ctrl.state(), TexturePreviewController.RELEASING)
	assert_true(ctrl.generation > g, "disable bumps the generation")
	await _drain(ctrl)
	await _off(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.OFF, "late completions cannot publish")
	assert_false(_adapter.preview_uniforms().preview_enabled)
	var st := _cache.stats()
	assert_true(int(st.discarded_stale) >= 1, "in-flight loads were discarded: %s" % st)
	assert_eq(st.resident_bytes, pre.resident_bytes)
	assert_eq(st.reserved_bytes, pre.reserved_bytes)
	assert_eq(st.entries, pre.entries)


func test_world_replacement_during_loading_discards_late_results() -> void:
	var ctrl := _make(_mixed_doc())
	var pre := _cache.stats()
	ctrl.enable_at(Vector3.ZERO)
	ctrl.service(2.0)
	var g := ctrl.generation
	ctrl.on_world_replaced()
	assert_true(ctrl.generation > g)
	assert_eq(ctrl.state(), TexturePreviewController.RELEASING)
	assert_false(ctrl.enable_at(Vector3.ZERO).ok, "unbound until the new world is bound")
	await _drain(ctrl)
	await _off(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.OFF)
	assert_false(_adapter.preview_uniforms().preview_enabled)
	assert_eq(_cache.stats().resident_bytes, pre.resident_bytes)
	var fresh := WorldDocument.create_flat(0.0, AUTO)
	assert_empty_string(_adapter.replace_document(fresh))
	ctrl.bind(_adapter, fresh)
	assert_true(ctrl.enable_at(Vector3.ZERO).ok)
	await _drive(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.ACTIVE)
	ctrl.on_world_replaced()
	assert_false(_adapter.preview_uniforms().preview_enabled, "world replacement clears the binding")
	await _off(ctrl)


# --- PREVIEW-06 ----------------------------------------------------------------------------------

func test_preview_keeps_heights_control_holes_and_tint_untouched() -> void:
	var doc := _mixed_doc()
	var hole_loc := Vector2i(0, 0)
	doc.get_region(hole_loc).control[40 * 256 + 40] |= ControlCodec.HOLE_BIT
	doc.get_region(hole_loc).color[(41 * 256 + 41) * 4 + 3] = 200
	var ctrl := _make(doc)
	var hash_before := CanonicalEncoder.authored_hash(doc)
	var control_before := doc.get_region(hole_loc).control.duplicate()
	var heights_before := doc.get_region(hole_loc).heights.duplicate()
	ctrl.enable_at(Vector3(10.0, 0.0, 10.0))
	await _drive(ctrl)
	assert_eq(ctrl.state(), TexturePreviewController.ACTIVE)
	assert_eq(CanonicalEncoder.authored_hash(doc), hash_before)
	assert_eq(doc.get_region(hole_loc).control, control_before)
	assert_eq(doc.get_region(hole_loc).heights, heights_before)
	assert_eq(_adapter.verify_matches_document(doc).size(), 0)
	ctrl.disable("test")
	assert_eq(_adapter.verify_matches_document(doc).size(), 0)
	await _off(ctrl)


func test_shader_derives_blend_weights_from_the_low_tier_samples_only() -> void:
	var code := (load(TerrainAdapter.SHADER_PATH) as Shader).code
	code += FileAccess.get_file_as_string("res://addons/world_painter/terrain/world_terrain_material.gdshaderinc")
	var slot_start := code.find("void sample_slot(")
	var slot_end := code.find("// 2-4 lookups per corner")
	assert_true(slot_start > 0 and slot_end > slot_start, "sample_slot located")
	var body := code.substr(slot_start, slot_end - slot_start)
	assert_true(body.contains("alb.rgb = mix(alb.rgb, p_alb.rgb, pmask);"), "preview colour only replaces RGB")
	assert_false(body.contains("p_alb.a"), "preview alpha is never read")
	assert_false(body.contains("alb = mix("), "albedo.a (blend height) is not mixed")
	assert_true(body.contains("textureGrad(preview_albedo_array, puv, id_dd.xy, id_dd.zw)"), "explicit gradients")
	assert_true(body.contains("textureGrad(preview_normal_array, puv, id_dd.xy, id_dd.zw)"))
	var frag := code.substr(code.find("void fragment()"))
	assert_true(frag.find("base_ddx = dFdxCoarse") < frag.find("float pmask"), "derivatives before the area branch")
	assert_true(frag.contains("pmask = 1.0 - smoothstep("), "mask from world XZ distance")


# --- PREVIEW-07 / MEMORY-05 ------------------------------------------------------------------------

func test_twenty_enable_disable_cycles_return_the_cache_to_its_baseline() -> void:
	var ctrl := _make(_mixed_doc())
	var pre := _cache.stats()
	var last := {}
	for cycle in 20:
		assert_true(ctrl.enable_at(Vector3(1.0, 0.0, 1.0)).ok, "cycle %d" % cycle)
		await _drive(ctrl)
		assert_eq(ctrl.state(), TexturePreviewController.ACTIVE, "cycle %d" % cycle)
		var active := _cache.stats()
		assert_true(int(active.resident_bytes) > int(pre.resident_bytes))
		assert_true(int(active.preview_bytes) <= 128 * RenderAssetCache.MIB)
		ctrl.disable("cycle")
		last = ctrl.status()
		await _off(ctrl)
		var st := _cache.stats()
		assert_eq(st.resident_bytes, pre.resident_bytes, "cycle %d resident" % cycle)
		assert_eq(st.reserved_bytes, pre.reserved_bytes, "cycle %d reserved" % cycle)
		assert_eq(st.preview_bytes, pre.preview_bytes, "cycle %d preview" % cycle)
		assert_eq(st.entries, pre.entries, "cycle %d entries" % cycle)
		assert_false(_adapter.preview_uniforms().preview_enabled)
	assert_true(int(last.released_bytes) > 0, "release reports the bytes it freed")
	assert_eq(_cache.trim(0), 0, "nothing left for a trim to free")
	assert_eq(ctrl.generation, 40, "every enable and disable bumped the generation")


func test_suspend_releases_like_disable_with_the_reason() -> void:
	var ctrl := _make(_mixed_doc())
	var pre := _cache.stats()
	ctrl.enable_at(Vector3.ZERO)
	await _drive(ctrl)
	ctrl.suspend("memory_pressure")
	var st := ctrl.status()
	assert_eq(st.state, TexturePreviewController.RELEASING)
	assert_eq(st.reason, "suspended")
	assert_eq(st.cause, "memory_pressure")
	assert_false(_adapter.preview_uniforms().preview_enabled)
	assert_eq(_cache.stats().resident_bytes, pre.resident_bytes)
	await _off(ctrl)
	assert_eq(ctrl.status().state, TexturePreviewController.OFF)


func test_status_is_an_immutable_copy() -> void:
	var ctrl := _make(_mixed_doc())
	ctrl.enable_at(Vector3.ZERO)
	await _drive(ctrl)
	var st := ctrl.status()
	st.state = "HACKED"
	(st.missing as Array).append("x")
	assert_eq(ctrl.status().state, TexturePreviewController.ACTIVE)
	assert_eq((ctrl.status().missing as Array).size(), 0)
	ctrl.disable("test")
	await _off(ctrl)


# --- session level: PREVIEW-02, UI, bench, deactivation ---------------------------------------------

func test_session_toggle_captures_selected_anchor_and_never_retargets() -> void:
	var s := await _start_session()
	assert_true(s.terrain is TerrainAdapter, "real terrain adapter")
	var a := _place_boulder(s, 20.0, -12.0)
	var b := _place_boulder(s, -30.0, 25.0)
	s.tools.select(a)
	var scale_before := s.get_viewport().scaling_3d_scale
	var profile_before := str(s.status().profile)
	var hash_before := s.authored_hash()
	assert_eq(s.toggle_texture_preview(), "")
	await _session_frames(s, TexturePreviewController.ACTIVE)
	var st := s.texture_preview_status()
	var anchor := s.presenter.anchor_position(a)
	assert_eq(st.center, anchor, "captured the selected object's anchor")
	assert_eq(st.radius, 20.0)
	var ring: BrushRing = s._render._preview_ring
	assert_true(ring != null and ring.is_ring_visible(), "the captured area is outlined while the preview is on")
	var uniforms := s.terrain.preview_uniforms()
	assert_eq(uniforms.preview_area.x, anchor.x)
	assert_eq(uniforms.preview_area.y, anchor.z)
	# Camera moves, selection changes and moving the selected object never retarget.
	s.rig.focus_point(Vector3(-60.0, 0.0, 60.0))
	s.rig.controller.orbit(Vector2(120.0, 40.0), Vector2(1180, 820))
	s.tools.select(b)
	s.tools.select("")
	var moved := s.document.get_object(a)
	moved.set_position(-50.0, s.document.sample_height(-50.0, -50.0), -50.0)
	s.presenter.sync_object(s.document, a)
	for i in 5:
		await tree.process_frame
	var after := s.texture_preview_status()
	assert_eq(after.center, st.center)
	assert_eq(after.radius, st.radius)
	assert_eq(after.generation, st.generation)
	assert_eq(after.state, TexturePreviewController.ACTIVE)
	assert_eq(s.terrain.preview_uniforms().preview_area, uniforms.preview_area)
	assert_eq(s.get_viewport().scaling_3d_scale, scale_before, "profile and resolution unchanged")
	assert_eq(str(s.status().profile), profile_before)
	assert_ne(s.authored_hash(), hash_before, "(the test itself moved an object)")
	assert_eq(s.toggle_texture_preview(), "")
	assert_eq(s.texture_preview_status().state, TexturePreviewController.RELEASING)
	assert_false(s.terrain.preview_uniforms().preview_enabled)
	assert_eq(s.toggle_texture_preview(), "Texture Preview is still releasing.")
	await _session_frames(s, TexturePreviewController.OFF)
	await tree.process_frame
	assert_false(ring.is_ring_visible(), "the outline is gone once the preview is off")


func test_session_uses_camera_pivot_without_selection_and_asks_when_neither_is_valid() -> void:
	var s := await _start_session()
	s.rig.focus_point(Vector3(15.0, 0.0, -9.0))
	assert_eq(s.toggle_texture_preview(), "")
	var c: Vector3 = s.texture_preview_status().center
	assert_near(c.x, 15.0, 1e-3)
	assert_near(c.z, -9.0, 1e-3)
	assert_eq(s.toggle_texture_preview(), "")
	await _session_frames(s, TexturePreviewController.OFF)
	var posted: Array[String] = []
	s.message_posted.connect(func(text: String, _e: bool) -> void: posted.append(text))
	s.rig.focus_point(Vector3(9000.0, 0.0, 9000.0))
	assert_eq(s.toggle_texture_preview(), TexturePreviewController.NO_AREA)
	assert_eq(s.texture_preview_status().state, TexturePreviewController.OFF, "no origin-centred preview")
	assert_true(posted.has(TexturePreviewController.NO_AREA))


func test_session_refuses_during_bench_and_disables_on_deactivation_and_world_replacement() -> void:
	var s := await _start_session()
	s.rig.focus_point(Vector3(5.0, 0.0, 5.0))
	var runner := BenchStub.new()
	s.add_child(runner)
	assert_eq(s.claim_bench(runner), "")
	assert_eq(s.toggle_texture_preview(), EditorSession.BENCH_MESSAGE)
	assert_eq(s.texture_preview_status().state, TexturePreviewController.OFF)
	s.release_bench(runner)
	assert_eq(s.toggle_texture_preview(), "")
	await _session_frames(s, TexturePreviewController.ACTIVE)
	s._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_eq(s.texture_preview_status().state, TexturePreviewController.RELEASING, "deactivation disables")
	assert_eq(s.texture_preview_status().reason, "app_deactivated")
	await _session_frames(s, TexturePreviewController.OFF)
	assert_eq(s.toggle_texture_preview(), "")
	var g: int = s.texture_preview_status().generation
	assert_eq(s.open_fixture("gentle_hills"), "")
	assert_eq(s.texture_preview_status().state, TexturePreviewController.RELEASING, "world replacement disables")
	await _session_frames(s, TexturePreviewController.OFF)
	assert_true(int(s.texture_preview_status().generation) > g)
	assert_false(s.terrain.preview_uniforms().preview_enabled)
	assert_true(s.layers.settle_now(), "the new world's scatter loads are not preview work")
	assert_true(s.presenter.settle_now(), "nor are its object loads")
	assert_true(s.layers.settle_now())
	assert_eq(s.render_cache().stats().loading, 0)


func test_status_text_and_indicator_caption() -> void:
	var st := {"state": "ACTIVE", "center": Vector3(12.4, 0.0, -3.6), "radius": 20.0, "missing": []}
	assert_eq(TexturePreviewController.status_text(st), "Active · area 12, -4 · r 20 m")
	assert_eq(TexturePreviewController.status_text({"state": "OFF"}), "Off")
	assert_eq(TexturePreviewController.status_text({"state": "LOADING"}), "Loading…")
	assert_eq(TexturePreviewController.status_text({"state": "ERROR", "reason": "boom"}), "Error: boom")
	var base := {"profile_label": "Performance", "fps": 60.0, "profile_pending": "", "profile_target_fps": 60}
	var indicator := PerfIndicator.new()
	assert_eq(indicator.caption(base), "Performance · 60 fps")
	assert_eq(indicator.caption(base.merged({"texture_preview": {"state": "ACTIVE"}}, true)), "Performance · 60 fps · Preview")
	assert_eq(indicator.caption(base.merged({"texture_preview": {"state": "LOADING"}}, true)), "Performance · 60 fps")
	indicator.free()
