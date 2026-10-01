extends ScatterTestCase
## Scatter renderer cost measurements (HOST, printed): rebuild, dab and the edit-path frames on a 1 km world.


func test_perf_rebuild_all_20000_instances() -> void:
	var layer := ScatterLayer.new()
	var ids := [SPRUCE, GRASS, PEBBLES, FERN, BOULDER]
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in WorldConstants.MAX_SCATTER_INSTANCES:
		var id: String = ids[i % ids.size()]
		layer.add(id, catalog.get_asset(id).version, rng.randf_range(-127.0, 127.0), rng.randf_range(-127.0, 127.0),
				rng.randf_range(-PI, PI), 1.0, ScatterLayer.FLAG_TILT if i % 2 == 0 else 0)
	doc.scatter = layer
	var t0 := Time.get_ticks_usec()
	_build()
	var full_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	renderer.mark_rect(Rect2(0.0, 0.0, 20.0, 20.0), true)
	renderer.flush()
	var one_cell_ms := float(renderer.stats().last_rebuild_ms)
	print("    PERF scatter rebuild_all+settle 20000: %.1f ms (%d multimeshes); dirty re-drape of a 20 m rect: %.2f ms" % [
			full_ms, renderer.stats().multimeshes, one_cell_ms])
	assert_eq(renderer.stats().instances, 20000)
	assert_true(full_ms < 15000.0, "rebuild_all sanity bound")
	assert_true(one_cell_ms < full_ms, "a dirty cell is cheaper than a full rebuild")


func test_perf_scatter_dab_cost() -> void:
	doc.scatter = ScatterLayer.new()
	var placer := ScatterPlacer.new(doc, catalog, {"name": "Meadow", "items": [{"asset_id": GRASS, "weight": 1.0}],
			"density": 3.0, "spacing": 0.35, "slope_min": 0.0, "slope_max": 90.0, "align": true}, true, 2)
	var tries := ScatterOperation.dab_tries(3.0, 7.0, 0.7, 1.0)
	var t0 := Time.get_ticks_usec()
	var dabs := 40
	for d in dabs:
		var c := Vector2(-60.0 + float(d) * 3.5, 20.0)
		for _i in tries:
			var a := placer.rng().randf() * TAU
			var r := 7.0 * sqrt(placer.rng().randf())
			placer.try_add(c.x + cos(a) * r, c.y + sin(a) * r)
	var per_dab_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(dabs)
	print("    PERF scatter dab (meadow, r 7, %d tries): %.3f ms/dab, %d instances" % [tries, per_dab_ms, doc.scatter.count()])
	assert_true(per_dab_ms < 50.0, "dab sanity bound")


## Per-frame renderer cost of a scatter brush stroke, an erase stroke and a sculpt stroke on a 1 km world with
## about 100,000 scatter instances (HOST measurement, printed; spec §14).
func test_perf_edit_path_frame_cost_on_km1_100k() -> void:
	var km := WorldDocument.create_flat(0.0, ControlCodec.grass_value(), WorldLayout.km1())
	var rect := km.layout.world_rect()
	var limit := int(WorldLimits.for_schema(km.layout.schema_version()).max_scatter_instances)
	var ids := [SPRUCE, GRASS, PEBBLES, FERN, BOULDER, WILD]
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var layer := ScatterLayer.new()
	for i in limit - 1500:
		var id: String = ids[i % ids.size()]
		layer.add(id, catalog.get_asset(id).version, rng.randf_range(rect.position.x, rect.end.x - 1.0),
				rng.randf_range(rect.position.y, rect.end.y - 1.0), rng.randf_range(-PI, PI), 1.0, ScatterLayer.FLAG_TILT, limit)
	km.scatter = layer
	var center := Vector3(0.0, 0.0, 0.0)
	_camera_at(Vector3(0.0, 30.0, 40.0), center)
	renderer.set_camera(camera)
	renderer.set_lod_profile(RenderConfig.load_from().profile("balanced"))
	var t0 := Time.get_ticks_usec()
	renderer.rebuild_all(km)
	var bucket_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	assert_true(renderer.settle_now(60000.0), "km1 settles")
	var settle_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("    PERF km1 %d scatter: rebuild_all (bucketing) %.0f ms, settle all cells %.0f ms, %d cells / %d multimeshes" % [
			layer.count(), bucket_ms, settle_ms, renderer.stats().cells, renderer.stats().multimeshes])
	var placer := ScatterPlacer.new(km, catalog, {"name": "Meadow", "items": [{"asset_id": GRASS, "weight": 1.0},
			{"asset_id": SPRUCE, "weight": 0.2}], "density": 3.0, "spacing": 0.35, "slope_min": 0.0,
			"slope_max": 90.0, "align": true}, false, 5)
	var scatter_ms := PackedFloat64Array()
	for d in 40:
		var c := Vector2(-40.0 + float(d) * 2.0, 10.0)
		for _i in ScatterOperation.dab_tries(3.0, 7.0, 0.7, 1.0):
			var a := placer.rng().randf() * TAU
			var r := 7.0 * sqrt(placer.rng().randf())
			placer.try_add(c.x + cos(a) * r, c.y + sin(a) * r)
		var f0 := Time.get_ticks_usec()
		renderer.mark_rect(Rect2(c - Vector2(7.0, 7.0), Vector2(14.0, 14.0)))
		renderer.service_frame(1.0)
		scatter_ms.append(float(Time.get_ticks_usec() - f0) / 1000.0)
	var erase_ms := PackedFloat64Array()
	for d in 8:
		var c := Vector2(-30.0 + float(d) * 4.0, 10.0)
		var index := ScatterIndex.new(km.scatter)
		index.remove_indices(index.indices_in_disc(c.x, c.y, 5.0))
		var f0 := Time.get_ticks_usec()
		renderer.mark_rect(Rect2(c - Vector2(5.0, 5.0), Vector2(10.0, 10.0)))
		renderer.service_frame(1.0)
		erase_ms.append(float(Time.get_ticks_usec() - f0) / 1000.0)
	var sculpt_ms := PackedFloat64Array()
	for d in 40:
		var c := Vector2(-40.0 + float(d) * 2.0, -10.0)
		var region := km.get_region(Vector2i(floori(c.x / 128.0), floori(c.y / 128.0)))
		if region != null:
			region.heights[(int(c.y / 0.5) % 256 + 256) % 256 * 256 + (int(c.x / 0.5) % 256 + 256) % 256] += 0.05
			km.invalidate_height_range(Vector2i(floori(c.x / 128.0), floori(c.y / 128.0)))
		var f0 := Time.get_ticks_usec()
		renderer.mark_rect(Rect2(c - Vector2(7.0, 7.0), Vector2(14.0, 14.0)), true)
		renderer.service_frame(1.0)
		sculpt_ms.append(float(Time.get_ticks_usec() - f0) / 1000.0)
	_print_frames("scatter brush stroke", scatter_ms)
	_print_frames("erase stroke", erase_ms)
	_print_frames("sculpt stroke under scatter", sculpt_ms)
	assert_true(renderer.settle_now(60000.0))
	assert_eq(renderer.stats().authored, km.scatter.count())


func _print_frames(label: String, samples: PackedFloat64Array) -> void:
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for v in samples:
		total += v
	print("    PERF km1 100k %s: renderer frame mean %.2f ms, p95 %.2f ms, max %.2f ms (%d frames)" % [
			label, total / float(samples.size()), sorted[int(float(sorted.size()) * 0.95)], sorted[sorted.size() - 1], samples.size()])
