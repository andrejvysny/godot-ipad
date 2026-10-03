extends TestCase
## ScatterIndex and ScatterPlacer candidate rules (docs/editor-v2.md §6), headless on synthetic terrain.

const SPRUCE := "nature.tree.spruce_a"
const FERN := "nature.cover.fern_a"
const BOULDER := "nature.rock.boulder_a"
const PEBBLES := "nature.rock.pebbles_a"
const BINDING := "b00000000000000000000000000000000"  # index tests never resolve it

var catalog: AssetCatalog


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]


func _flat() -> WorldDocument:
	return WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, catalog)


## Terrain rising `slope` m per m along +X (tan of the surface angle).
func _ramp(slope: float) -> WorldDocument:
	var doc := _flat()
	for loc: Vector2i in doc.regions:
		var heights := (doc.get_region(loc) as RegionBuffers).heights
		for i in heights.size():
			heights[i] = slope * float(loc.x * 256 + (i % 256)) * WorldConstants.SAMPLE_SPACING
	return doc


func _config(items: Array, spacing := 1.0, smin := 0.0, smax := 90.0, align := false) -> Dictionary:
	var out: Array[Dictionary] = []
	for entry: Array in items:
		out.append({"asset_id": entry[0], "weight": entry[1]})
	return {"name": "T", "items": out, "density": 1.0, "spacing": spacing, "slope_min": smin,
			"slope_max": smax, "align": align}


func _placer(doc: WorldDocument, config: Dictionary, avoid := false, seed_value := 1) -> ScatterPlacer:
	return ScatterPlacer.new(doc, catalog, config, avoid, seed_value)


func test_add_respects_asset_ranges_and_align_flag() -> void:
	var doc := _flat()
	var p := _placer(doc, _config([[SPRUCE, 1.0]], 0.2, 0.0, 90.0, true), false, 7)
	var asset := catalog.get_asset(SPRUCE)
	for i in 100:
		assert_eq(p.try_add(float(i % 10) * 5.0 - 20.0, float(i / 10) * 5.0 - 20.0), ScatterPlacer.Result.ADDED)
	assert_eq(doc.scatter.count(), 100)
	for i in 100:
		assert_true(asset.scale_in_range(doc.scatter.scale[i]), "scale %s" % doc.scatter.scale[i])
		assert_true(absf(doc.scatter.yaw[i]) <= PI, "yaw")
		assert_eq(doc.scatter.flags[i], ScatterLayer.FLAG_TILT)
	var q := _placer(_flat(), _config([[SPRUCE, 1.0]]), false, 7)
	q.try_add(1.0, 1.0)
	assert_eq(q.index().layer().flags[0], 0, "no align flag by default")


func test_slope_window_and_missing_samples_reject() -> void:
	var ramp := _ramp(0.3)  # about 16.7 degrees
	assert_eq(_placer(ramp, _config([[SPRUCE, 1.0]], 1.0, 0.0, 10.0)).try_add(10.0, 10.0), ScatterPlacer.Result.SLOPE)
	assert_eq(_placer(ramp, _config([[SPRUCE, 1.0]], 1.0, 20.0, 60.0)).try_add(10.0, 10.0), ScatterPlacer.Result.SLOPE)
	assert_eq(_placer(ramp, _config([[SPRUCE, 1.0]], 1.0, 10.0, 30.0)).try_add(10.0, 10.0), ScatterPlacer.Result.ADDED)
	var holed := _flat()
	var region := holed.get_region(Vector2i(0, 0)) as RegionBuffers
	region.control[20 * 256 + 20] = region.control[20 * 256 + 20] | ControlCodec.HOLE_BIT
	assert_eq(_placer(holed, _config([[SPRUCE, 1.0]])).try_add(10.1, 10.1), ScatterPlacer.Result.NO_SAMPLE, "hole")
	assert_eq(_placer(holed, _config([[SPRUCE, 1.0]])).try_add(500.0, 0.0), ScatterPlacer.Result.OUTSIDE)
	assert_eq(holed.scatter.count(), 0)


func test_min_distance_uses_spacing_and_footprint() -> void:
	var doc := _flat()
	var p := _placer(doc, _config([[SPRUCE, 1.0]], 1.4))
	assert_eq(p.try_add(10.0, 10.0), ScatterPlacer.Result.ADDED)
	assert_eq(p.try_add(11.0, 10.0), ScatterPlacer.Result.SPACING)
	assert_eq(p.try_add(11.5, 10.0), ScatterPlacer.Result.ADDED)
	var rocks := _flat()
	var r := _placer(rocks, _config([[BOULDER, 1.0]], 0.2))  # 0.8 * 1.2 m footprint beats 0.2 m spacing
	assert_eq(r.try_add(0.0, 0.0), ScatterPlacer.Result.ADDED)
	assert_eq(r.try_add(0.8, 0.0), ScatterPlacer.Result.SPACING)
	assert_eq(r.try_add(1.0, 0.0), ScatterPlacer.Result.ADDED)


func test_avoid_objects_clearance_and_toggle() -> void:
	var doc := _flat()
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = doc.assets.bundled_binding_for(BOULDER)
	rec.set_position(20.0, 0.0, 20.0)
	doc.put_object(rec)
	var config := _config([[SPRUCE, 1.0]], 1.4)  # reach = 1.2 + 0.5 * 1.4 = 1.9 m
	assert_eq(_placer(doc, config, true).try_add(21.5, 20.0), ScatterPlacer.Result.OBJECT)
	assert_eq(_placer(doc, config, true).try_add(22.5, 20.0), ScatterPlacer.Result.ADDED)
	var off := _flat()
	off.assets.bundled_binding_for(BOULDER)
	off.put_object(rec.clone())
	assert_eq(_placer(off, config, false).try_add(21.5, 20.0), ScatterPlacer.Result.ADDED, "avoid off")
	rec.uniform_scale = 2.0
	var big := _flat()
	big.assets.bundled_binding_for(BOULDER)
	big.put_object(rec.clone())
	assert_eq(_placer(big, config, true).try_add(22.5, 20.0), ScatterPlacer.Result.OBJECT, "footprint scales")


func test_same_seed_same_layer_different_seed_differs() -> void:
	var bytes: Array[PackedByteArray] = []
	for seed_value in [11, 11, 12]:
		var doc := _flat()
		var p := _placer(doc, _config([[SPRUCE, 6.0], [FERN, 3.0], [BOULDER, 1.0]], 0.3), false, seed_value)
		for i in 200:
			p.try_add(float(i % 20) * 3.0 - 30.0, float(i / 20) * 3.0 - 30.0)
		bytes.append(doc.scatter.encode())
	assert_eq(bytes[0], bytes[1], "deterministic per seed")
	assert_ne(bytes[0], bytes[2], "seed matters")


func test_weighted_pick_follows_weights() -> void:
	var doc := _flat()
	var p := _placer(doc, _config([[SPRUCE, 6.0], [FERN, 3.0], [BOULDER, 1.0]], 0.2), false, 3)
	for i in 1600:
		p.try_add(float(i % 40) * 3.0 - 60.0, float(i / 40) * 3.0 - 60.0)
	var counts := {}
	for i in doc.scatter.count():
		var asset_id := doc.assets.definition(doc.scatter.binding_of(i)).asset_id
		counts[asset_id] = int(counts.get(asset_id, 0)) + 1
	var spruce_share := float(counts[SPRUCE]) / 1600.0
	assert_true(spruce_share > 0.5 and spruce_share < 0.7, "spruce share %.2f" % spruce_share)
	assert_true(int(counts[FERN]) > int(counts[BOULDER]), "fern outweighs boulder")


func test_limit_stops_adding_and_flags_once() -> void:
	var doc := _flat()
	doc.schema_version = 2  # in-memory schema is 4 now; the 20000 limit is the schema 2 one
	var binding := doc.assets.bundled_binding_for(PEBBLES)
	for i in WorldConstants.MAX_SCATTER_INSTANCES:
		doc.scatter.add(binding, -120.0 + float(i % 200), -120.0 + float(i / 200), 0.0, 1.0, 0)
	var p := _placer(doc, _config([[PEBBLES, 1.0]], 0.2))
	assert_false(p.limit_reached)
	assert_eq(p.try_add(50.0, 50.0), ScatterPlacer.Result.LIMIT)
	assert_true(p.limit_reached)
	assert_eq(doc.scatter.count(), WorldConstants.MAX_SCATTER_INSTANCES)
	assert_eq(p.limit_message(), "Scatter limit reached (20000).")


func test_empty_source_never_adds() -> void:
	var p := _placer(_flat(), _config([]))
	assert_false(p.has_source())
	assert_eq(p.try_add(0.0, 0.0), ScatterPlacer.Result.NO_SOURCE)


func test_dab_try_and_erase_formulas() -> void:
	assert_eq(ScatterOperation.dab_tries(0.6, 7.0, 0.7, 1.0), roundi(0.6 * PI * 49.0 * 0.05 * 0.7))
	assert_eq(ScatterOperation.dab_tries(3.0, 7.0, 1.0, 0.5), roundi(3.0 * PI * 49.0 * 0.05 * 0.5))
	assert_eq(ScatterOperation.dab_tries(0.1, 1.0, 0.05, 0.2), 1, "at least one try")
	assert_eq(ScatterOperation.erase_probability(0.0, 1.0), 0.0)
	assert_near(ScatterOperation.erase_probability(1.0, 1.0), 0.7, 1e-9)
	assert_near(ScatterOperation.erase_probability(0.5, 0.4), 0.14, 1e-9)
	assert_true(ScatterOperation.erase_probability(5.0, 5.0) <= 1.0, "clamped")
	assert_eq(FillOperation.fill_tries(1.0, 100.0), 60)
	assert_eq(FillOperation.fill_tries(5.0, 10000.0), 6000, "capped")


func test_index_queries_match_brute_force_and_survive_removal() -> void:
	var layer := ScatterLayer.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 300:
		layer.add(BINDING, rng.randf_range(-30.0, 30.0), rng.randf_range(-30.0, 30.0), 0.0, 1.0, 0)
	var index := ScatterIndex.new(layer)
	var found := index.indices_in_disc(3.0, -4.0, 9.0)
	var expected := PackedInt32Array()
	for i in layer.count():
		if Vector2(layer.x[i], layer.z[i]).distance_squared_to(Vector2(3.0, -4.0)) <= 81.0:
			expected.append(i)
	found.sort()
	assert_eq(found, expected)
	assert_true(index.has_within(layer.x[10], layer.z[10], 0.01))
	assert_false(index.has_within(500.0, 500.0, 5.0))
	index.remove_indices(found)
	assert_eq(layer.count(), 300 - expected.size())
	assert_eq(index.indices_in_disc(3.0, -4.0, 9.0).size(), 0, "removed instances are gone from the index")
	assert_eq(index.indices_in_disc(0.0, 0.0, 100.0).size(), layer.count())
	layer.add(BINDING, 3.0, -4.0, 0.0, 1.0, 0)
	index.add_last()
	assert_eq(index.indices_in_disc(3.0, -4.0, 1.0).size(), 1)
