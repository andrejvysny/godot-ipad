extends TestCase
## WORLD-02 integration on the 64-region km1 layout: brush clipping at the seams and the +-512 m edges,
## terrain picking at the corners, and the per-schema object and scatter limits.

const SP := WorldConstants.SAMPLE_SPACING
const PEBBLES := "nature.rock.pebbles_a"

var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func _km() -> WorldDocument:
	return WorldDocument.create_flat(0.0, ControlCodec.grass_value(), WorldLayout.km1(), _catalog)


## Schema 2 limits are selected through the in-memory schema number (documents are schema 4 in memory).
func _legacy() -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, _catalog)
	doc.schema_version = 2
	return doc


func _tx(doc: WorldDocument) -> EditTransaction:
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	return tx


## Samples whose height differs from 0 within the global sample window [lo, hi] (inclusive, may leave the layout).
func _changed(doc: WorldDocument, lo: Vector2i, hi: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for gz in range(lo.y, hi.y + 1):
		for gx in range(lo.x, hi.x + 1):
			var h := doc.get_height_at_sample(gx, gz)
			if not is_nan(h) and h != 0.0:
				out.append(Vector2i(gx, gz))
	return out


func _assert_disc_clipped(doc: WorldDocument, centre: Vector2, radius: float, what: String) -> Array[Vector2i]:
	var gc := Vector2i(roundi(centre.x / SP), roundi(centre.y / SP))
	var window := roundi(radius / SP) + 3
	var changed := _changed(doc, gc - Vector2i(window, window), gc + Vector2i(window, window))
	var expected := 0
	for gz in range(gc.y - window, gc.y + window + 1):
		for gx in range(gc.x - window, gc.x + window + 1):
			var d := Vector2(gx * SP, gz * SP).distance_to(centre)
			var valid := doc.layout.is_valid_sample(gx, gz)
			if valid and d < radius - 0.01:
				expected += 1
				assert_true(changed.has(Vector2i(gx, gz)), "%s: sample (%d, %d) inside the brush changed" % [what, gx, gz])
			if not valid or d > radius + 0.01:
				assert_false(changed.has(Vector2i(gx, gz)), "%s: sample (%d, %d) must not change" % [what, gx, gz])
	assert_true(expected > 0 and changed.size() >= expected, "%s: %d changed, >= %d expected" % [what, changed.size(), expected])
	return changed


func test_sculpt_dab_on_the_x0_z0_seams_touches_all_four_regions_symmetrically() -> void:
	var doc := _km()
	var res := BrushKernels.sculpt_segment(doc, _tx(doc), Vector2.ZERO, Vector2.ZERO, 6.0, 2.0, 1.0, 1.0, 0.1)
	assert_empty_string(res.error)
	var dirty: Array = res.dirty_heights
	dirty.sort()
	assert_eq(dirty, [Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 0)])
	assert_near(doc.get_height_at_sample(0, 0), 0.2, 1e-6)
	assert_near(doc.get_height_at_sample(-1, 0), doc.get_height_at_sample(0, -1), 1e-7, "mirror across the seams")
	_assert_disc_clipped(doc, Vector2.ZERO, 6.0, "seam dab")


func test_sculpt_stroke_clips_exactly_at_the_four_world_corners() -> void:
	for corner in [Vector2(-512.0, -512.0), Vector2(511.5, -512.0), Vector2(-512.0, 511.5), Vector2(511.5, 511.5)]:
		var doc := _km()
		var tx := _tx(doc)
		var res := BrushKernels.sculpt_segment(doc, tx, corner, corner, 6.0, 2.0, 1.0, 1.0, 0.1)
		assert_empty_string(res.error)
		assert_eq((res.dirty_heights as Array).size(), 1, "one region at corner %s" % str(corner))
		assert_true(doc.get_height_at_sample(roundi(corner.x / SP), roundi(corner.y / SP)) > 0.0, "corner sample raised")
		_assert_disc_clipped(doc, corner, 6.0, "corner %s" % str(corner))


func test_sculpt_far_from_the_origin_is_not_clipped_to_the_legacy_extent() -> void:
	var doc := _km()
	var res := BrushKernels.sculpt_segment(doc, _tx(doc), Vector2(300.0, -400.0), Vector2(340.0, -380.0), 5.0, 2.0, 1.0, 1.0, 0.1)
	assert_empty_string(res.error)
	assert_false((res.dirty_heights as Array).is_empty())
	assert_true(doc.get_height_at_sample(640, -780) > 0.0, "stroke at x=320 m, z=-390 m changed samples")
	var beyond := BrushKernels.sculpt_segment(doc, _tx(doc), Vector2(600.0, 0.0), Vector2(900.0, 100.0), 6.0, 2.0, 1.0, 1.0, 0.1)
	assert_true((beyond.dirty_heights as Array).is_empty(), "a stroke entirely outside the layout changes nothing")


func test_paint_at_the_far_corner_changes_only_valid_control_samples() -> void:
	var doc := _km()
	var state := BrushKernels.PaintStrokeState.new(doc, _tx(doc), 1.0)
	var res := BrushKernels.paint_segment(state, Vector2(511.5, 511.5), Vector2(540.0, 540.0), 4.0, 1.0, 1.0, 1.0)
	assert_empty_string(res.error)
	assert_eq(res.dirty_controls, [Vector2i(3, 3)])
	assert_ne(doc.get_control_at_sample(1023, 1023), ControlCodec.grass_value(), "corner sample painted")


func test_picker_hits_every_corner_and_seam_and_rejects_just_outside() -> void:
	var doc := _km()
	var corners := {Vector2(-512.0, -512.0): Vector2i(-4, -4), Vector2(511.5, -512.0): Vector2i(3, -4),
		Vector2(-512.0, 511.5): Vector2i(-4, 3), Vector2(511.5, 511.5): Vector2i(3, 3),
		Vector2(0.0, 0.0): Vector2i(0, 0), Vector2(-0.5, -0.5): Vector2i(-1, -1), Vector2(-0.5, 0.0): Vector2i(-1, 0),
		Vector2(127.5, 128.0): Vector2i(0, 1), Vector2(-128.5, -128.0): Vector2i(-2, -1)}
	for p: Vector2 in corners:
		var hit := TerrainPicker.raycast(doc, Vector3(p.x, 40.0, p.y), Vector3.DOWN)
		assert_true(hit.ok, "hit at %s: %s" % [str(p), hit.reason])
		assert_eq(hit.region, corners[p], "region at %s" % str(p))
		assert_near(hit.position.x, p.x, 1e-6)
		assert_near(hit.position.z, p.y, 1e-6)
		assert_eq(TerrainPicker.region_at(doc.layout, p.x, p.y), corners[p])
	for p: Vector2 in [Vector2(-512.01, 0.0), Vector2(0.0, -512.01), Vector2(511.51, 0.0), Vector2(0.0, 511.51), Vector2(700.0, 700.0)]:
		var miss := TerrainPicker.raycast(doc, Vector3(p.x, 40.0, p.y), Vector3.DOWN)
		assert_false(miss.ok, "outside at %s" % str(p))
		assert_eq(miss.reason, "outside")
		assert_eq(TerrainPicker.region_at(doc.layout, p.x, p.y), TerrainHit.NO_REGION)


func test_picker_ray_from_far_outside_reaches_the_far_corner_area() -> void:
	var doc := _km()
	var origin := Vector3(1200.0, 400.0, 1200.0)
	var target := Vector3(500.0, 0.0, 500.0)
	var hit := TerrainPicker.raycast(doc, origin, target - origin, 3000.0)
	assert_true(hit.ok, hit.reason)
	assert_near(hit.position.x, 500.0, 0.05)
	assert_near(hit.position.z, 500.0, 0.05)
	var short := TerrainPicker.raycast(doc, origin, target - origin, 500.0)
	assert_eq(short.reason, "no_hit", "a ray shorter than the distance to the ground misses")


# --- Limits ------------------------------------------------------------------------------

func _boulder_binding() -> String:
	return WorldAssetLock.new(_catalog).bundled_binding_for("nature.rock.boulder_a")


func _object(n: int) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = "%08x-0000-4000-8000-%012d" % [n, n]
	r.binding_id = _boulder_binding()
	r.grounding = WorldConstants.GROUNDING_FIXED
	return r


func test_object_limit_is_per_schema() -> void:
	var legacy := _legacy()
	var km := _km()
	assert_eq(legacy.max_objects(), 2000)
	assert_eq(km.max_objects(), 50000)
	for i in 1999:
		legacy.put_object(_object(i))
	assert_empty_string(ToolCommands.object_limit_error(legacy), "one below the limit")
	legacy.put_object(_object(1999))
	assert_eq(ToolCommands.object_limit_error(legacy), "Object limit reached (2000).")
	for i in 50000:
		km.put_object(_object(i))
	assert_eq(ToolCommands.object_limit_error(km), "Object limit reached (50000).")
	km.remove_object(_object(7).object_id)
	assert_empty_string(ToolCommands.object_limit_error(km))


func test_duplicate_is_refused_at_the_limit_without_touching_the_document() -> void:
	var doc := _legacy()
	for i in 2000:
		doc.put_object(_object(i))
	var ctx := ToolContext.new()
	ctx.document = doc
	ctx.catalog = _catalog
	var res := ToolCommands.duplicate_object(ctx, doc.get_object(_object(5).object_id))
	assert_eq(res.error, "Object limit reached (2000).")
	assert_true(res.change == null and res.id == "")
	assert_eq(doc.objects.size(), 2000)


func test_scatter_limit_follows_the_schema() -> void:
	var cfg := {"name": "T", "items": [{"asset_id": PEBBLES, "weight": 1.0}], "density": 1.0, "spacing": 0.2,
			"slope_min": 0.0, "slope_max": 90.0, "align": false}
	var legacy := ScatterPlacer.new(_legacy(), _catalog, cfg, false, 1)
	assert_eq(legacy.max_instances, 20000)
	assert_eq(legacy.limit_message(), "Scatter limit reached (20000).")
	var km: WorldDocument = SessionWorldOps.new_layout_world(WorldLayout.km1(), "flat", _catalog)[0]
	var placer := ScatterPlacer.new(km, _catalog, cfg, false, 1)
	assert_eq(placer.max_instances, 100000)
	assert_eq(placer.limit_message(), "Scatter limit reached (100000).")
	_catalog.get_asset(PEBBLES).scatter_mesh = "res://assets/test_scatter_mesh.tres"
	var binding := km.assets.bundled_binding_for(PEBBLES)
	for i in 100000:
		assert_true(km.scatter.add(binding, -500.0 + float(i % 1000) * 0.9, -500.0 + float(i / 1000) * 9.0, 0.0, 1.0, 0, 100000))
	assert_false(km.scatter.add(binding, 0.0, 0.0, 0.0, 1.0, 0, 100000), "layer refuses past its schema limit")
	assert_eq(placer.try_add(10.5, 10.5), ScatterPlacer.Result.LIMIT)
	assert_true(placer.limit_reached)
	assert_eq(km.scatter.count(), 100000)
	assert_eq(WorldValidator.validate(km, _catalog).size(), 0, "a full km1 layer is a valid world")
