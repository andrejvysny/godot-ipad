extends TestCase
## Continuous-segment kernels: seams, negative coordinates, world edge, capture-once, budget
## (spec §12.1, §12.2, §13.1; TE-08, TE-09).

const SP := WorldConstants.SAMPLE_SPACING


func _doc(height: float = 0.0) -> WorldDocument:
	return WorldDocument.create_flat(height, ControlCodec.grass_value())


func _tx(doc: WorldDocument) -> EditTransaction:
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	return tx


func test_seam_centred_dab_is_four_fold_symmetric_and_captured_once() -> void:
	var doc := _doc()
	var original := doc.duplicate_deep()
	var tx := _tx(doc)
	var r1 := BrushKernels.sculpt_segment(doc, tx, Vector2.ZERO, Vector2.ZERO, 6.0, 2.0, 1.0, 1.0, 0.1)
	var r2 := BrushKernels.sculpt_segment(doc, tx, Vector2.ZERO, Vector2.ZERO, 6.0, 2.0, 1.0, 1.0, 0.1)
	assert_empty_string(r1.error)
	assert_empty_string(r2.error)
	assert_eq((r1.dirty_heights as Array).size(), 4, "all four regions dirty")
	assert_near(doc.get_height_at_sample(0, 0), 0.4, 1e-6, "centre = 2 * rate * dt")
	var asym := 0
	for gz in range(-13, 14):
		for gx in range(-13, 14):
			var h := doc.get_height_at_sample(gx, gz)
			if h != doc.get_height_at_sample(-gx, gz) or h != doc.get_height_at_sample(gx, -gz) \
					or h != doc.get_height_at_sample(gz, gx):
				asym += 1
	assert_eq(asym, 0, "exact mirror and transpose symmetry across seams")
	assert_eq(doc.get_height_at_sample(12, 0), 0.0, "radius edge untouched")
	var change := tx.finish()
	assert_eq(change.height_regions().size(), 4)
	for loc: Vector2i in change.height_regions():
		assert_true(change.before_heights[loc] == original.get_region(loc).heights, "before %s is pre-stroke" % loc)


func test_segment_across_seam_is_continuous() -> void:
	var doc := _doc()
	var tx := _tx(doc)
	BrushKernels.sculpt_segment(doc, tx, Vector2(-3, 0), Vector2(3, 0), 4.0, 2.0, 1.0, 1.0, 0.1)
	var worst := 0.0
	for gz in range(-9, 10):
		for gx in range(-14, 15):
			worst = maxf(worst, absf(doc.get_height_at_sample(gx, gz) - doc.get_height_at_sample(-gx, gz)))
			assert_eq(doc.get_height_at_sample(gx, gz), doc.get_height_at_sample(gx, -gz), "z mirror %d,%d" % [gx, gz])
	assert_true(worst < 1e-6, "x mirror within float rounding (%.9f)" % worst)
	# Mean over the segment at its midpoint: integral of (1 - (u/4)^2)^2 on [-3, 3] / 6.
	var expected := 0.2 * (6.0 - 2.0 * 27.0 / (3.0 * 16.0) * 2.0 + 2.0 * 243.0 / (5.0 * 256.0)) / 6.0
	assert_near(doc.get_height_at_sample(0, 0), expected, 1e-6, "closed-form centre")


func test_te08_negative_coordinates_use_floor_mapping() -> void:
	var doc := _doc()
	var tx := _tx(doc)
	var res := BrushKernels.sculpt_segment(doc, tx, Vector2(-100.25, -60.75), Vector2(-100.25, -60.75), 2.0, 1.0, 1.0, 1.0, 1.0)
	assert_eq(res.dirty_heights, [Vector2i(-1, -1)] as Array[Vector2i], "only region (-1,-1)")
	# Sample (-201, -121) = world (-100.5, -60.5); local (55, 135) in region (-1, -1).
	var region := doc.get_region(Vector2i(-1, -1))
	var h: float = region.heights[135 * 256 + 55]
	assert_near(h, BrushMath.falloff(sqrt(0.125) / 2.0), 1e-6, "floor-based local index")
	assert_eq(doc.get_height_at_sample(-201, -121), h)
	for loc: Vector2i in [Vector2i(0, 0), Vector2i(0, -1), Vector2i(-1, 0)]:
		assert_eq(doc.get_region(loc).heights.count(0.0), WorldConstants.REGION_SAMPLE_COUNT, "%s untouched" % loc)
	var rect: Rect2 = res.rect
	assert_true(rect.position.x >= -102.5 and rect.end.x <= -98.0 and rect.position.y >= -63.0 and rect.end.y <= -58.5, "rect %s" % rect)


func test_te09_world_edge_and_beyond_write_nothing_outside() -> void:
	var doc := _doc()
	var tx := _tx(doc)
	var edge := BrushKernels.sculpt_segment(doc, tx, Vector2(127.5, 127.5), Vector2(127.5, 140.0), 6.0, 2.0, 1.0, 1.0, 0.1)
	assert_empty_string(edge.error)
	assert_eq(edge.dirty_heights, [Vector2i(0, 0)] as Array[Vector2i])
	assert_true(doc.get_height_at_sample(255, 255) > 0.0, "last sample edited")
	var beyond := BrushKernels.sculpt_segment(doc, tx, Vector2(140, -200), Vector2(400, 300), 6.0, 2.0, 1.0, 1.0, 0.1)
	assert_empty_string(beyond.error)
	assert_true((beyond.dirty_heights as Array).is_empty(), "nothing inside the extent")
	var state := BrushKernels.PaintStrokeState.new(doc, tx, 1.0)
	var paint := BrushKernels.paint_segment(state, Vector2(-128, -128), Vector2(-300, -128), 4.0, 1.0, 1.0, 1.0)
	assert_empty_string(paint.error)
	assert_eq(paint.dirty_controls, [Vector2i(-1, -1)] as Array[Vector2i])
	assert_eq(doc.regions.size(), 4, "no new regions")
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		assert_eq(r.heights.size(), WorldConstants.REGION_SAMPLE_COUNT)
		assert_eq(r.control.size(), WorldConstants.REGION_SAMPLE_COUNT)
	var change := tx.finish()
	assert_eq(change.height_regions(), [Vector2i(0, 0)])
	assert_eq(change.control_regions(), [Vector2i(-1, -1)])


func test_te09_missing_region_is_skipped_not_created() -> void:
	var doc := _doc()
	doc.regions.erase(Vector2i(0, 0))
	var tx := _tx(doc)
	var res := BrushKernels.sculpt_segment(doc, tx, Vector2(0, 0), Vector2(0, 0), 4.0, 2.0, 1.0, 1.0, 0.1)
	assert_empty_string(res.error, "missing region is not a budget failure")
	assert_eq(doc.regions.size(), 3, "not recreated")
	assert_eq((res.dirty_heights as Array).size(), 3)


func test_height_clamped_to_document_range() -> void:
	var doc := _doc(63.9)
	var tx := _tx(doc)
	BrushKernels.sculpt_segment(doc, tx, Vector2(10, 10), Vector2(10, 10), 3.0, 50.0, 1.0, 1.0, 1.0)
	assert_eq(doc.get_height_at_sample(20, 20), WorldConstants.HEIGHT_MAX)
	BrushKernels.sculpt_segment(doc, tx, Vector2(10, 10), Vector2(10, 10), 3.0, -500.0, 1.0, 1.0, 1.0)
	assert_eq(doc.get_height_at_sample(20, 20), WorldConstants.HEIGHT_MIN)


func test_budget_exceeded_reports_error() -> void:
	var doc := _doc()
	var tx := _tx(doc)
	tx.max_payload_bytes = WorldConstants.REGION_SAMPLE_COUNT * 8  # exactly one region map
	var res := BrushKernels.sculpt_segment(doc, tx, Vector2(0, 0), Vector2(0, 0), 4.0, 2.0, 1.0, 1.0, 0.1)
	assert_eq(res.error, BrushKernels.ERROR_BUDGET)
	assert_true(tx.budget_exceeded)


func test_capsule_row_span_covers_exact_disc_set() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var missed := 0
	var extra := 0
	for n in 40:
		var a := Vector2(rng.randf_range(-20, 20), rng.randf_range(-20, 20))
		var b := a + Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)) * (0.0 if n % 5 == 0 else 1.0)
		var r := rng.randf_range(0.3, 5.0)
		var cap := BrushKernels.Capsule.new(a, b, r)
		var rows := cap.row_range()
		for gz in range(-60, 61):
			var span := cap.row_span(gz * SP) if gz >= rows.x and gz <= rows.y else Vector2i(1, 0)
			for gx in range(-60, 61):
				var inside := _dist_to_segment(Vector2(gx * SP, gz * SP), a, b) < r
				var in_span := gx >= span.x and gx <= span.y
				if inside and not in_span:
					missed += 1
				if in_span and _dist_to_segment(Vector2(gx * SP, gz * SP), a, b) > r + SP:
					extra += 1
	assert_eq(missed, 0, "no sample within radius is skipped")
	assert_eq(extra, 0, "span is tight")


## Spec §13.4: the result rect must contain every anchor whose bilinear height changed.
func test_result_rect_contains_every_changed_anchor() -> void:
	for seg: Array in [[Vector2(10, 10), Vector2(10, 10), 2.0], [Vector2(-3.3, 4.1), Vector2(1.7, 6.2), 2.4]]:
		var doc := _doc()
		var res := BrushKernels.sculpt_segment(doc, _tx(doc), seg[0], seg[1], seg[2], 1.0, 1.0, 1.0, 1.0)
		var rect: Rect2 = res.rect
		assert_eq(rect, _grown_hull(doc, true), "rect = changed samples grown by one spacing")
		var outside := 0
		for iz in range(-80, 161):
			for ix in range(-80, 161):
				var p := Vector2(ix, iz) * 0.125
				if doc.sample_height(p.x, p.y) != 0.0 and not rect.has_point(p):
					outside += 1
		assert_eq(outside, 0, "changed anchors outside %s" % rect)
	var pdoc := _doc()
	var state := BrushKernels.PaintStrokeState.new(pdoc, _tx(pdoc), 1.0)
	var pres := BrushKernels.paint_segment(state, Vector2(-3.3, 4.1), Vector2(1.7, 6.2), 2.4, 1.0, 1.0, 1.0)
	assert_eq(pres.rect, _grown_hull(pdoc, false), "paint rect = changed samples grown by one spacing")


## Bounds of the samples in [-40, 40]^2 that differ from the flat document, grown by SP.
func _grown_hull(doc: WorldDocument, heights: bool) -> Rect2:
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := -lo
	for gz in range(-40, 41):
		for gx in range(-40, 41):
			var changed := doc.get_height_at_sample(gx, gz) != 0.0 if heights \
					else doc.get_control_at_sample(gx, gz) != ControlCodec.grass_value()
			if changed:
				lo = Vector2i(mini(lo.x, gx), mini(lo.y, gz))
				hi = Vector2i(maxi(hi.x, gx), maxi(hi.y, gz))
	return Rect2(Vector2(lo - Vector2i.ONE) * SP, Vector2(hi - lo + Vector2i(2, 2)) * SP)


func test_non_finite_inputs_are_rejected_without_writing() -> void:
	var doc := _doc()
	var tx := _tx(doc)
	var state := BrushKernels.PaintStrokeState.new(doc, tx, 1.0)
	var results: Array[Dictionary] = [
		BrushKernels.sculpt_segment(doc, tx, Vector2(NAN, 0), Vector2(0, 0), 2.0, 1.0, 1.0, 1.0, 0.1),
		BrushKernels.sculpt_segment(doc, tx, Vector2(0, 0), Vector2(0, 0), NAN, 1.0, 1.0, 1.0, 0.1),
		BrushKernels.sculpt_segment(doc, tx, Vector2(0, 0), Vector2(0, 0), 2.0, 1.0, 1.0, NAN, 0.1),
		BrushKernels.paint_segment(state, Vector2(0, INF), Vector2(0, 0), 2.0, 1.0, 1.0, 1.0),
		BrushKernels.paint_segment(state, Vector2(0, 0), Vector2(0, 0), 2.0, NAN, 1.0, 1.0),
		BrushKernels.paint_segment(state, Vector2(0, 0), Vector2(1, 0), 2.0, 1.0, NAN, 1.0),
	]
	for r: Dictionary in results:
		assert_eq(r.error, BrushKernels.ERROR_INVALID)
		assert_true((r.dirty_heights as Array).is_empty() and (r.dirty_controls as Array).is_empty())
	assert_eq(CanonicalEncoder.authored_hash(doc), CanonicalEncoder.authored_hash(_doc()), "nothing written")


func test_timing_16m_sculpt_step_and_paint_segment() -> void:
	var doc := _doc()
	var tx := _tx(doc)
	var t0 := Time.get_ticks_usec()
	var n := 5
	for i in n:
		# One 1/60 s step of a pencil moving 3 m/s at a 16 m radius.
		BrushKernels.sculpt_segment(doc, tx, Vector2(i * 0.05, 0), Vector2(i * 0.05 + 0.05, 0), 16.0, 2.0, 1.0, 1.0, 1.0 / 60.0)
	var sculpt_ms := (Time.get_ticks_usec() - t0) / 1000.0 / n
	var state := BrushKernels.PaintStrokeState.new(doc, tx, 1.0)
	t0 = Time.get_ticks_usec()
	for i in n:
		BrushKernels.paint_segment(state, Vector2(i * 0.5, 0), Vector2(i * 0.5 + 0.5, 0), 16.0, 1.0, 1.0, 1.0)
	var paint_ms := (Time.get_ticks_usec() - t0) / 1000.0 / n
	print("    TIMING r=16m sculpt_segment %.2f ms/call, paint_segment %.2f ms/call (desktop headless)" % [sculpt_ms, paint_ms])
	assert_true(sculpt_ms > 0.0 and paint_ms > 0.0)


static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var u := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * u)
