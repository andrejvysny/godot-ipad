extends TestCase
## Decorative scatter density and ground-cover radius (spec §4.2, §10): DENSITY-01 (deterministic nested subsets),
## DENSITY-02 (meaningful scatter and manual objects are never thinned), DENSITY-03 (presentation changes leave
## authored data alone), active-area stability during an operation and the ground-cover radius hysteresis.

const GRASS := "nature.cover.grass_tuft_a"
const PEBBLES := "nature.rock.pebbles_a"
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"
const CELL := 16.0

var catalog: AssetCatalog
var doc: WorldDocument
var renderer: ScatterRenderer
var camera: Camera3D


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	doc = WorldCodec.read_generation("res://fixtures/flat", catalog)[0]
	renderer = _new_renderer()


func after_each() -> void:
	renderer.free()
	if camera != null:
		camera.get_parent().remove_child(camera)
		camera.free()
		camera = null


func _asset_of(layer: ScatterLayer, i: int) -> String:
	return doc.assets.definition(layer.binding_of(i)).asset_id


func _new_renderer() -> ScatterRenderer:
	var r := ScatterRenderer.new()
	r.setup(catalog)
	return r


func _profile(outside: float, active: float, radius: float = 100000.0) -> Dictionary:
	var p := RenderConfig.load_from().profile("performance")
	p.size_policy_enabled = false
	p.decorative_density_outside = outside
	p.decorative_density_active = active
	p.ground_cover_radius_m = radius
	return p


func _scatter(ids: Array, n: int, seed_value: int = 3, extent: float = 60.0) -> ScatterLayer:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var layer := ScatterLayer.new()
	for i in n:
		var id: String = ids[i % ids.size()]
		layer.add(doc.assets.bundled_binding_for(id), rng.randf_range(-extent, extent), rng.randf_range(-extent, extent),
				rng.randf_range(-PI, PI), 1.0, 0)
	return layer


func _camera(pos: Vector3, target: Vector3) -> Camera3D:
	if camera == null:
		camera = Camera3D.new()
		tree.root.add_child(camera)
	camera.look_at_from_position(pos, target)
	return camera


## "x,z" of every drawn instance of `asset_id` (cells -128..128 m).
func _drawn(r: ScatterRenderer, asset_id: String) -> Dictionary:
	var out := {}
	for cz in range(-8, 8):
		for cx in range(-8, 8):
			var cell := Vector2i(cx, cz)
			for k in r.rendered_count(cell, asset_id):
				var o := r.instance_transform(cell, asset_id, k).origin
				out["%.2f,%.2f" % [o.x, o.z]] = true
	return out


func _drawn_in(r: ScatterRenderer, asset_id: String, cells: Dictionary) -> Dictionary:
	var out := {}
	for cell: Vector2i in cells:
		for k in r.rendered_count(cell, asset_id):
			var o := r.instance_transform(cell, asset_id, k).origin
			out["%.2f,%.2f" % [o.x, o.z]] = true
	return out


func _subset(a: Dictionary, b: Dictionary) -> bool:
	for key: String in a:
		if not b.has(key):
			return false
	return true


func _render_at(r: ScatterRenderer, d: Dictionary, asset_id: String) -> Dictionary:
	r.set_lod_profile(d)
	r.flush()
	return _drawn(r, asset_id)


# --- DENSITY-01 -------------------------------------------------------------------------------

func test_key_is_fnv1a_over_asset_float32_xz_and_the_world_seed() -> void:
	var seed_value := ScatterDensity.world_seed("world-poc-test")
	assert_eq(seed_value, 2568517603, "FNV-1a 32 of the world id bytes")
	assert_eq(ScatterDensity.key(GRASS, 12.5, -3.25, seed_value), 3107977115)
	assert_eq(ScatterDensity.key(PEBBLES, -100.0, 0.0625, seed_value), 2104228798)
	var xz := PackedFloat32Array([12.5, -3.25, -100.0, 0.0625])
	var keys := ScatterDensity.keys_of(GRASS, xz.to_byte_array(), seed_value)
	assert_eq(keys[0], ScatterDensity.key(GRASS, 12.5, -3.25, seed_value), "batch keys equal single keys")
	assert_eq(keys[1], ScatterDensity.key(GRASS, -100.0, 0.0625, seed_value))
	assert_ne(keys[1], ScatterDensity.key(PEBBLES, -100.0, 0.0625, seed_value), "the asset id is part of the key")
	assert_true(ScatterDensity.keeps(0, 0.25) and not ScatterDensity.keeps(0, 0.0))
	assert_true(ScatterDensity.keeps(4294967295, 1.0) and not ScatterDensity.keeps(1073741824, 0.25), "strictly below")


func test_densities_form_nested_subsets_stable_across_rebuilds_and_sessions() -> void:
	doc.scatter = _scatter([GRASS], 3000)
	renderer.rebuild_all(doc)
	var d25 := _render_at(renderer, _profile(0.25, 0.25), GRASS)
	var d50 := _render_at(renderer, _profile(0.5, 0.5), GRASS)
	var d75 := _render_at(renderer, _profile(0.75, 0.75), GRASS)
	var d100 := _render_at(renderer, _profile(1.0, 1.0), GRASS)
	assert_true(_subset(d25, d50) and _subset(d50, d75) and _subset(d75, d100), "0.25 ⊂ 0.5 ⊂ 0.75 ⊂ 1.0")
	assert_eq(d100.size(), 3000)
	for pair: Array in [[d25, 0.25], [d50, 0.5], [d75, 0.75]]:
		assert_near(float((pair[0] as Dictionary).size()) / 3000.0, float(pair[1]), 0.04, "density %s" % pair[1])
	var stats := renderer.density_stats()
	assert_eq(stats.decorative_total, 3000)
	assert_eq(stats.decorative_drawn, 3000)
	assert_true(stats.cells_drawn > 10)
	renderer.rebuild_all(doc)
	assert_eq(_render_at(renderer, _profile(0.5, 0.5), GRASS), d50, "same subset after a rebuild")
	var reloaded := WorldCodec.read_generation("res://fixtures/flat", catalog)[0] as WorldDocument
	reloaded.assets.bundled_binding_for(GRASS)  # bundled bindings are content-addressed: same ids
	reloaded.scatter = doc.scatter.clone()
	var session2 := _new_renderer()
	session2.rebuild_all(reloaded)
	assert_eq(_render_at(session2, _profile(0.5, 0.5), GRASS), d50, "same subset in another session of the same world")
	reloaded.world_id = "another-world"
	session2.rebuild_all(reloaded)
	assert_ne(_render_at(session2, _profile(0.5, 0.5), GRASS), d50, "the world seed changes the subset")
	session2.free()


func test_keys_do_not_depend_on_unrelated_instances() -> void:
	var layer := _scatter([GRASS], 1000)
	doc.scatter = layer
	renderer.set_lod_profile(_profile(0.5, 0.5))
	renderer.rebuild_all(doc)
	renderer.flush()
	var before := _drawn(renderer, GRASS)
	var extra := _scatter([GRASS], 300, 99)
	for i in extra.count():
		layer.add(doc.assets.bundled_binding_for(GRASS), extra.x[i], extra.z[i], 0.0, 1.0, 0)
	renderer.mark_rect(doc.layout.extent_rect())
	renderer.flush()
	var added := _drawn(renderer, GRASS)
	assert_true(_subset(before, added), "unrelated additions never remove a drawn instance")
	var drop := PackedInt32Array()
	for i in range(0, 1000, 3):
		drop.append(i)
	var dropped_keys := {}
	for i in drop:
		dropped_keys["%.2f,%.2f" % [layer.x[i], layer.z[i]]] = true
	layer.remove_indices(drop)
	renderer.mark_rect(doc.layout.extent_rect())
	renderer.flush()
	var after := _drawn(renderer, GRASS)
	for key: String in added:
		assert_eq(after.has(key), not dropped_keys.has(key), "only removed instances change: " + key)


# --- DENSITY-02 -------------------------------------------------------------------------------

func test_meaningful_scatter_and_manual_objects_are_never_thinned() -> void:
	var layer := _scatter([SPRUCE, BOULDER, GRASS], 900)
	doc.scatter = layer
	var spruces := 0
	var boulders := 0
	for i in layer.count():
		spruces += 1 if _asset_of(layer, i) == SPRUCE else 0
		boulders += 1 if _asset_of(layer, i) == BOULDER else 0
	var presenter := ObjectPresenter.new()
	presenter.setup(catalog)
	tree.root.add_child(presenter)
	for k in 20:
		var rec := ObjectRecord.new()
		rec.object_id = ObjectRecord.new_uuid_v4()
		rec.binding_id = doc.assets.bundled_binding_for(SPRUCE)
		rec.set_position(-50.0 + float(k) * 4.0, 0.0, 70.0)
		doc.put_object(rec)
	presenter.rebuild(doc)
	assert_true(presenter.settle_now())
	var object_instances := int(presenter.render_stats().instances)
	assert_eq(object_instances, 20)
	var config := RenderConfig.load_from()
	var profiles: Array[Dictionary] = [_profile(0.0, 0.0), _profile(0.0, 1.0), config.profile("performance"),
			config.profile("balanced"), config.profile("detailed")]
	renderer.rebuild_all(doc)
	for p in profiles:
		renderer.set_lod_profile(p)
		renderer.flush()
		var drawn_meaningful := 0
		for cz in range(-4, 4):
			for cx in range(-4, 4):
				drawn_meaningful += renderer.rendered_count(Vector2i(cx, cz), SPRUCE) + renderer.rendered_count(Vector2i(cx, cz), BOULDER)
		assert_eq(drawn_meaningful, spruces + boulders, "meaningful scatter is drawn in full at density %s/%s" % [
				p.decorative_density_outside, p.decorative_density_active])
		assert_eq(int(presenter.render_stats().instances), object_instances, "manual objects are untouched by scatter profiles")
	tree.root.remove_child(presenter)
	presenter.free()


# --- DENSITY-03 -------------------------------------------------------------------------------

func test_profile_density_radius_hiding_and_camera_changes_never_touch_authored_data() -> void:
	doc.scatter = _scatter([GRASS, PEBBLES, SPRUCE, BOULDER], 800)
	var hash_before := CanonicalEncoder.authored_hash(doc)
	var bytes := doc.scatter.encode()
	var revision := doc.document_revision
	_camera(Vector3(0.0, 20.0, 50.0), Vector3.ZERO)
	renderer.set_camera(camera)
	renderer.rebuild_all(doc)
	var rule := RenderConfig.load_from().vegetation_rule()
	var config := RenderConfig.load_from()
	for name in RenderConfig.PROFILE_NAMES:
		renderer.set_lod_profile(config.profile(name))
		renderer.flush()
	renderer.set_lod_profile(_profile(0.1, 0.9, 12.0))
	renderer.set_vegetation_hidden(true, rule)
	renderer.flush()
	for pos in [Vector3(80.0, 10.0, 0.0), Vector3(-60.0, 10.0, -60.0), Vector3(0.0, 90.0, 1.0)]:
		camera.global_position = pos
		renderer.flush()
	renderer.set_vegetation_hidden(false, rule)
	renderer.flush()
	assert_eq(CanonicalEncoder.authored_hash(doc), hash_before)
	assert_eq(doc.scatter.encode(), bytes)
	assert_eq(doc.document_revision, revision)


# --- Active area ------------------------------------------------------------------------------

func test_active_area_density_is_frozen_for_the_operation_and_may_change_after_release() -> void:
	doc.scatter = _scatter([GRASS], 4000, 5, 90.0)
	renderer.set_lod_profile(_profile(0.25, 0.75))
	var area := ActiveEditArea.new(32.0, 250)
	renderer.set_active_area(area)
	_camera(Vector3(0.0, 20.0, 60.0), Vector3.ZERO)
	renderer.set_camera(camera)
	renderer.rebuild_all(doc)
	renderer.flush()
	var spot := Vector3(60.0, 0.0, -60.0)
	assert_true(area.pinned_cells(CELL).is_empty(), "no pins yet")
	var outside_drawn := _drawn_in(renderer, GRASS, _cells_around(spot, 12.0)).size()
	area.begin("op-1", spot, 12.0)
	renderer.flush()
	var frozen := area.pinned_cells(CELL)
	assert_true(frozen.size() >= 4)
	var total_inside := _count_authored_in(frozen)
	var at_start := _drawn_in(renderer, GRASS, frozen)
	assert_true(at_start.size() > outside_drawn, "more local detail while editing")
	assert_near(float(at_start.size()) / float(total_inside), 0.75, 0.12, "active density inside the pinned cells")
	for pos in [Vector3(-70.0, 25.0, 40.0), Vector3(-60.0, 25.0, -70.0), Vector3(70.0, 25.0, 60.0)]:
		camera.look_at_from_position(pos, Vector3(pos.x, 0.0, pos.z - 30.0))
		renderer.flush()
		assert_eq(_drawn_in(renderer, GRASS, frozen), at_start, "the frozen subset does not change while the camera orbits")
	area.end("op-1", "finished")
	renderer.flush()
	assert_eq(_drawn_in(renderer, GRASS, frozen), at_start, "pins linger for the settle interval")
	area.tick(Time.get_ticks_msec() + 5000)
	assert_false(area.has_pins())
	renderer.flush()
	var released := _drawn_in(renderer, GRASS, frozen)
	assert_true(released.size() < at_start.size(), "after release the area follows the camera pivot again")
	assert_true(_subset(released, at_start), "nested: the released subset is part of the frozen one")


func _cells_around(p: Vector3, radius: float) -> Dictionary:
	var a := ActiveEditArea.new(32.0, 250)
	a.begin("probe", p, radius)
	return a.pinned_cells(CELL)


func _count_authored_in(cells: Dictionary) -> int:
	var n := 0
	for i in doc.scatter.count():
		if cells.has(Vector2i(floori(doc.scatter.x[i] / CELL), floori(doc.scatter.z[i] / CELL))):
			n += 1
	return n


# --- Ground-cover radius ------------------------------------------------------------------------

## PREF-08: ground cover keeps a representative density while navigating: full density inside the radius,
## halved per distance band (sqrt 2 steps), not drawn beyond 4 radii; band changes need the hysteresis margin.
func test_ground_cover_density_bands_follow_the_distance_with_hysteresis() -> void:
	var layer := ScatterLayer.new()
	for i in 400:
		layer.add(doc.assets.bundled_binding_for(GRASS), 32.5 + (i % 20) * 0.75, 0.5 + (i / 20) * 0.75, 0.0, 1.0, 0)
	doc.scatter = layer  # one 16 m cell: x 32..48, z 0..16
	var cam := _camera(Vector3(-400.0, 1.0, 8.0), Vector3(40.0, 1.0, 8.0))
	renderer.set_camera(cam)
	renderer.set_lod_profile(_profile(1.0, 1.0, 25.0))
	renderer.rebuild_all(doc)
	var key := Vector2i(2, 0)
	var scale_f := LodPolicy.effective_distance(1.0, cam.fov, cam.get_viewport().get_visible_rect().size.y)
	var r := 25.0 / scale_f  # metric distance of the radius
	var steps: Array = [  # [metric distance to the cell box, expected band]
		[r * 5.0, -1], [r * 3.9, -1], [r * 3.5, 4], [r * 0.5, 0], [r * 1.05, 0], [r * 1.2, 1],
		[r * 0.95, 1], [r * 0.85, 0], [r * 4.2, 4], [r * 4.5, -1]]
	for step: Array in steps:
		cam.global_position = Vector3(32.0 - float(step[0]), 1.0, 8.0)
		renderer.flush()
		var cell: ScatterCell = renderer._engine.buckets.cell(ScatterCell.DECORATIVE, key)
		var band: int = cell.band if cell.wanted else -1
		assert_eq(band, int(step[1]), "band at %.1f m (radius %.1f m)" % [step[0], r])
		if band >= 0:
			var drawn := renderer.rendered_count(key, GRASS)
			var expected := 400.0 * LodPolicy.ground_cover_factor(band)
			assert_true(absf(drawn - expected) <= maxf(expected * 0.35, 6.0), "~%d of 400 drawn at band %d, got %d" % [
					int(expected), band, drawn])
	assert_eq(renderer.stats().authored, 400)
	assert_eq(doc.scatter.count(), 400)
