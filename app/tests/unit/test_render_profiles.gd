extends TestCase
## RenderConfig validation and RenderProfileController policy (rendering spec §4, §22.1; PROFILE-01, -02, -03).


func _shipped() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(RenderConfig.PATH))


## Writes `data` to scratch and loads it through the real file path.
func _load(data: Dictionary) -> RenderConfig:
	var path := scratch_dir() + "/rendering_profiles.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	return RenderConfig.load_from(path)


func _assert_rejected(data: Dictionary, why: String) -> void:
	var config := _load(data)
	assert_ne(config.error, "", why + ": expected an error")
	assert_eq(config.profile("performance"), RenderConfig.safe_default().profile("performance"), why + ": safe default")
	assert_eq(config.profile("detailed").scale_3d, 1.0, why)


func test_shipped_config_validates_and_matches_safe_default() -> void:
	var config := RenderConfig.load_from()
	assert_eq(config.error, "")
	assert_eq(RenderConfig.validate(_shipped()), "")
	assert_eq(RenderConfig.validate(RenderConfig.safe_default()._data), "", "safe_default validates")
	assert_eq(RenderConfig.safe_default().error, "")
	for name in config.profile_names():
		assert_eq(config.profile(name), RenderConfig.safe_default().profile(name), name)
	for section in RenderConfig.SECTION_KEYS:
		assert_eq(config.section(section), RenderConfig.safe_default().section(section), section)
	assert_eq(config.profile("performance").scale_3d, 0.65)
	assert_eq(config.startup_profile(), "performance")


func test_missing_or_garbled_file_falls_back() -> void:
	assert_ne(RenderConfig.load_from("res://config/nope.json").error, "")
	var path := scratch_dir() + "/bad.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{not json")
	file.close()
	assert_ne(RenderConfig.load_from(path).error, "")


func test_invalid_configs_fall_back_with_error() -> void:
	var d := _shipped()
	d.profiles.balanced.shadows = true
	_assert_rejected(d, "shadows true")
	d = _shipped()
	d.profiles.performance.complex_effects = true
	_assert_rejected(d, "complex effects")
	d = _shipped()
	d.startup_profile = "balanced"
	_assert_rejected(d, "startup balanced")
	d = _shipped()
	d.profiles.performance.extra = 1
	_assert_rejected(d, "unknown profile key")
	d = _shipped()
	d.extra = {}
	_assert_rejected(d, "unknown top-level key")
	d = _shipped()
	d.profiles.performance.erase("msaa")
	_assert_rejected(d, "missing key")
	d = _shipped()
	d.erase("budgets")
	_assert_rejected(d, "missing section")
	d = _shipped()
	d.profiles.performance.scale_3d = 0.4
	_assert_rejected(d, "scale 0.4")
	d = _shipped()
	d.budgets.inflight_loads = 2.5
	_assert_rejected(d, "non-integer inflight_loads")
	d = _shipped()
	d.profiles.balanced.decorative_density_outside = 1.0
	d.profiles.balanced.decorative_density_active = 0.5
	_assert_rejected(d, "outside > active")
	d = _shipped()
	d.profiles.erase("detailed")
	d.profiles.custom = _shipped().profiles.detailed
	_assert_rejected(d, "unknown profile set")
	d = _shipped()
	d.profiles.performance.target_fps = 45
	_assert_rejected(d, "fps")
	d = _shipped()
	d.profiles.performance.low_texture_max_edge_px = 500
	_assert_rejected(d, "non power of two")
	d = _shipped()
	d.cells.overview_levels_m = [128, 100]
	_assert_rejected(d, "descending levels")
	d = _shipped()
	d.cells.overview_levels_m = [100, 200]
	_assert_rejected(d, "levels not multiples of objects_m")
	for bad: Array in [[], [32], [96, 192], [64, 192], [64, 128, 256, 512, 1024], [128, 128], [64, "128"]]:
		d = _shipped()
		d.cells.overview_levels_m = bad
		_assert_rejected(d, "overview levels %s" % str(bad))
	for good: Array in [[128], [64, 128, 256], [64, 256], [128, 512], [64, 128, 256, 512]]:
		d = _shipped()
		d.cells.overview_levels_m = good
		assert_eq(RenderConfig.validate(d), "", "overview levels %s are valid" % str(good))
	d = _shipped()
	d.budgets.managed_soft_mib = 600
	_assert_rejected(d, "soft above ceiling")
	d = _shipped()
	d.budgets.main_thread_soft_ms = 3.0
	_assert_rejected(d, "soft ms above max scheduled")
	d = _shipped()
	d.texture_preview.fallback_texture_edge_px = 2048
	_assert_rejected(d, "fallback edge")
	d = _shipped()
	d.vegetation.categories = []
	_assert_rejected(d, "empty categories")
	d = _shipped()
	d.schema_version = RenderConfig.SCHEMA_VERSION + 1
	_assert_rejected(d, "schema version")


func test_vegetation_rule_classifies_assets() -> void:
	var catalog := AssetCatalog.load_from()[0] as AssetCatalog
	var config := RenderConfig.load_from()
	assert_true(config.is_vegetation(catalog.get_asset("nature.tree.spruce_a")))
	assert_true(config.is_vegetation(catalog.get_asset("nature.cover.grass_tuft_a")))
	assert_false(config.is_vegetation(catalog.get_asset("nature.rock.pebbles_a")), "excluded ground cover")
	assert_false(config.is_vegetation(catalog.get_asset("nature.rock.boulder_a")))
	assert_false(config.is_vegetation(null))
	assert_true(RenderConfig.rule_is_vegetation(config.vegetation_rule(), catalog.get_asset("nature.tree.spruce_a")))


func test_accessors_return_copies() -> void:
	var config := RenderConfig.load_from()
	var p := config.profile("performance")
	p.scale_3d = 0.9
	assert_eq(config.profile("performance").scale_3d, 0.65)
	config.section("budgets").inflight_loads = 7
	assert_eq(config.section("budgets").inflight_loads, 2.0)


# --- controller ------------------------------------------------------------------------------

func _controller(applied: Array) -> RenderProfileController:
	var c := RenderProfileController.new(RenderConfig.load_from())
	c.set_apply_hook(func(name: String, profile: Dictionary) -> void: applied.append([name, profile.scale_3d]))
	return c


func test_startup_is_performance() -> void:
	var applied := []
	var c := _controller(applied)
	c.apply_startup()
	assert_eq(c.active_name(), "performance")
	assert_eq(applied, [["performance", 0.65]])
	assert_eq(c.generation(), 1)
	assert_eq(c.pending_name(), "")


func test_busy_request_waits_for_operation_end_and_applies_once() -> void:
	var applied := []
	var c := _controller(applied)
	c.apply_startup()
	var pending_events := []
	c.pending_changed.connect(func(name: String) -> void: pending_events.append(name))
	assert_eq(c.request_profile("balanced", true), {"status": "pending", "name": "balanced"})
	assert_eq(c.active_name(), "performance")
	assert_eq(c.pending_name(), "balanced")
	assert_eq(c.request_profile("detailed", true).status, "pending", "latest wins")
	assert_eq(c.pending_name(), "detailed")
	c.operation_ended()
	assert_eq(c.active_name(), "detailed")
	assert_eq(c.pending_name(), "")
	c.operation_ended()
	assert_eq(applied.size(), 2, "startup plus exactly one switch")
	assert_eq(c.generation(), 2)
	assert_eq(pending_events, ["balanced", "detailed", ""])


func test_idle_request_applies_immediately() -> void:
	var applied := []
	var c := _controller(applied)
	c.apply_startup()
	assert_eq(c.request_profile("balanced", false), {"status": "applied", "name": "balanced"})
	assert_eq(c.active_profile().scale_3d, 0.75)
	assert_eq(applied.size(), 2)


func test_same_profile_is_unchanged_and_clears_pending() -> void:
	var applied := []
	var c := _controller(applied)
	c.apply_startup()
	c.request_profile("balanced", true)
	assert_eq(c.request_profile("performance", true), {"status": "unchanged", "name": "performance"})
	assert_eq(c.pending_name(), "")
	c.operation_ended()
	assert_eq(applied.size(), 1, "nothing was applied after startup")


func test_unknown_profile() -> void:
	var c := _controller([])
	c.apply_startup()
	assert_eq(c.request_profile("ultra", false), {"status": "unknown", "name": "ultra"})
	assert_eq(c.request_profile("", true).status, "unknown")
	assert_eq(c.active_name(), "performance")
	assert_eq(c.pending_name(), "")


func test_size_and_overview_thresholds_validate() -> void:
	var d := _shipped()
	d.size_visibility.object_show_px = d.size_visibility.object_hide_px
	_assert_rejected(d, "show must exceed hide")
	d = _shipped()
	d.overview_view.exit_pitch_deg = d.overview_view.enter_pitch_deg
	_assert_rejected(d, "pitch hysteresis")
	d = _shipped()
	d.size_visibility.mid_near_px = d.size_visibility.far_mid_px
	_assert_rejected(d, "tier order")
	d = _shipped()
	d.size_visibility.object_hide_px = NAN
	assert_ne(RenderConfig.validate(d), "")
