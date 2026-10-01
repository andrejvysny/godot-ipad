extends TestCase
## Paint-family kernels: the 4-layer rules, alphas, spray and tint maps (docs/editor-v2.md §3, §4).

const SP := WorldConstants.SAMPLE_SPACING
const RGB_LUSH := Vector3i(38, 108, 40)


func _doc(control: int = ControlCodec.default_value()) -> WorldDocument:
	return WorldDocument.create_flat(0.0, control)


func _settings(op: String, layer: int, radius: float, extra: Dictionary = {}) -> Dictionary:
	var s := {"radius": radius, "strength": 1.0, "target_blend": 1.0, "pressure_enabled": false,
			"falloff_kind": PaintStroke.FALLOFF_BRUSH, "op": op, "layer": layer, "tint": 1}
	s.merge(extra, true)
	return s


## Runs one stroke through the points and returns its finished change (null when nothing changed).
func _stroke(doc: WorldDocument, settings: Dictionary, points: Array[Vector2]) -> WorldChange:
	var tx := EditTransaction.new()
	tx.begin(doc, "paint", "Paint", settings)
	var s := PaintStroke.new()
	s.begin(doc, tx, settings, points[0], 1.0)
	for i in range(1, points.size()):
		s.add_sample(i * 0.01, points[i], 1.0)
	assert_empty_string(s.finish(1.0).error)
	return tx.finish()


func _blend(doc: WorldDocument, gx: int, gz: int) -> int:
	return ControlCodec.get_blend(doc.get_control_at_sample(gx, gz))


func _alpha(doc: WorldDocument, gx: int, gz: int) -> int:
	return doc.get_color_at_sample(gx, gz) & 0xFF


func _changed_extent(before: PackedInt32Array, after: PackedInt32Array) -> Vector2:
	var lo_x := 1 << 20
	var hi_x := -(1 << 20)
	var lo_z := 1 << 20
	var hi_z := -(1 << 20)
	for i in before.size():
		if before[i] != after[i]:
			lo_x = mini(lo_x, i % 256)
			hi_x = maxi(hi_x, i % 256)
			lo_z = mini(lo_z, i / 256)
			hi_z = maxi(hi_z, i / 256)
	return Vector2(hi_x - lo_x + 1, hi_z - lo_z + 1)


func test_dab_coverage_never_exceeds_the_continuous_kernel() -> void:
	var exact := _doc()
	var dabs := _doc()
	var points: Array[Vector2] = [Vector2(20, 20), Vector2(24, 21)]
	_stroke(exact, _settings("paint", 1, 4.0), points)
	# stamp + soft is isotropic soft: the same weight, but through discrete dabs.
	_stroke(dabs, _settings("paint", 1, 4.0, {"alpha_mode": "stamp"}), points)
	var worst_over := 0
	var worst_under := 0
	var centre := 0
	for gz in range(30, 55):
		for gx in range(30, 62):
			var d := _blend(dabs, gx, gz) - _blend(exact, gx, gz)
			worst_over = maxi(worst_over, d)
			worst_under = maxi(worst_under, -d)
			centre = maxi(centre, _blend(dabs, gx, gz))
	assert_eq(worst_over, 0, "max over a subset of points cannot exceed the continuous max")
	assert_true(worst_under < 40, "dab spacing 0.15 r stays close, worst %d levels" % worst_under)
	assert_eq(centre, 255, "dab centres reach full strength")


func test_hard_alpha_has_a_full_strength_core() -> void:
	var doc := _doc()
	_stroke(doc, _settings("paint", 1, 5.0, {"shape": "hard"}), [Vector2(20, 20)] as Array[Vector2])
	assert_eq(_blend(doc, 40, 40), 255, "centre")
	assert_eq(_blend(doc, 45, 40), 255, "q = 0.5 inside the 0.82 core")
	assert_eq(_blend(doc, 49, 40), ControlCodec.quantize_blend(0.1 / 0.18), "q = 0.9 on the rim ramp")
	assert_eq(_blend(doc, 50, 40), 0, "radius edge")


func test_ring_alpha_leaves_the_centre_unpainted() -> void:
	var doc := _doc()
	_stroke(doc, _settings("paint", 1, 7.5, {"shape": "ring"}), [Vector2(20, 20)] as Array[Vector2])
	assert_eq(doc.get_control_at_sample(40, 40), ControlCodec.default_value(), "centre untouched")
	assert_true(_blend(doc, 50, 40) > 250, "ring crest at q = 0.667")


func test_stamp_follows_stroke_direction_and_circle_ignores_it() -> void:
	var stamp := _doc()
	var circle := _doc()
	var down: Array[Vector2] = [Vector2(20, 20), Vector2(20, 50)]
	_stroke(stamp, _settings("paint", 1, 6.0, {"shape": "streak", "alpha_mode": "stamp"}), down)
	_stroke(circle, _settings("paint", 1, 6.0, {"shape": "streak", "alpha_mode": "circle"}), down)
	# The streak is long along its local +X. Ahead of the stroke end (20, 50) is +Z, beside it +X.
	assert_true(_blend(stamp, 40, 106) > 100, "stamp: elongated ahead along the stroke")
	assert_eq(_blend(stamp, 46, 100), 0, "stamp: narrow beside the stroke")
	assert_eq(_blend(circle, 40, 106), 0, "circle: the angle is ignored, narrow along Z")
	assert_true(_blend(circle, 46, 100) > 100, "circle: elongated along X")


func test_pattern_is_anchored_in_world_space() -> void:
	var a := _doc()
	var shifted_by_tile := _doc()
	var shifted_off_tile := _doc()
	var settings := _settings("paint", 1, 5.0, {"shape": "splat", "alpha_mode": "pattern"})  # tile 3.5 m
	_stroke(a, settings, [Vector2(20, 20)] as Array[Vector2])
	_stroke(shifted_by_tile, settings, [Vector2(23.5, 20)] as Array[Vector2])
	_stroke(shifted_off_tile, settings, [Vector2(21.0, 20)] as Array[Vector2])
	var tile_diff := 0
	var off_diff := 0
	for gz in range(26, 56):
		for gx in range(26, 60):
			tile_diff += 1 if _blend(a, gx, gz) != _blend(shifted_by_tile, gx + 7, gz) else 0
			off_diff += 1 if _blend(a, gx, gz) != _blend(shifted_off_tile, gx + 2, gz) else 0
	assert_eq(tile_diff, 0, "a whole tile shift reproduces the stamp")
	assert_true(off_diff > 20, "a partial shift changes the revealed pattern (%d)" % off_diff)


func test_spray_is_deterministic_per_seed_and_sparser_than_paint() -> void:
	var paint := _doc()
	var spray_a := _doc()
	var spray_a2 := _doc()
	var spray_b := _doc()
	var pts: Array[Vector2] = [Vector2(20, 20), Vector2(24, 20)]
	_stroke(paint, _settings("paint", 1, 5.0), pts)
	_stroke(spray_a, _settings("spray", 1, 5.0, {"seed": 3.7}), pts)
	_stroke(spray_a2, _settings("spray", 1, 5.0, {"seed": 3.7}), pts)
	_stroke(spray_b, _settings("spray", 1, 5.0, {"seed": 11.3}), pts)
	assert_true(spray_a.get_region(Vector2i(0, 0)).control == spray_a2.get_region(Vector2i(0, 0)).control, "same seed")
	assert_true(spray_a.get_region(Vector2i(0, 0)).control != spray_b.get_region(Vector2i(0, 0)).control, "other seed")
	var high := 0
	var total := 0
	var spray_max := 0
	var paint_sum := 0
	var spray_sum := 0
	for gz in range(36, 46):
		for gx in range(40, 52):
			total += 1
			high += 1 if _blend(spray_a, gx, gz) > 40 else 0
			spray_max = maxi(spray_max, _blend(spray_a, gx, gz))
			paint_sum += _blend(paint, gx, gz)
			spray_sum += _blend(spray_a, gx, gz)
	assert_true(spray_max <= roundi(0.35 * 255.0), "spray is capped at 0.35 coverage (%d)" % spray_max)
	assert_true(high > total / 5 and high < total * 4 / 5, "broken coverage: %d of %d samples dense" % [high, total])
	assert_true(spray_sum < paint_sum / 3, "spray %d much lighter than paint %d" % [spray_sum, paint_sum])


func test_erase_spray_removes_035_of_the_paint() -> void:
	var doc := _doc(ControlCodec.encode_paint(0, 255) | ControlCodec.AUTO_BIT)
	_stroke(doc, _settings("erase_spray", 1, 4.0), [Vector2(20, 20)] as Array[Vector2])
	assert_eq(_blend(doc, 40, 40), 166, "255 * (1 - 0.35)")


func test_erase_reveals_the_rule_layer() -> void:
	var doc := _doc(ControlCodec.encode_paint(0, 255))  # manual base grass, overlay dirt, no auto bit
	assert_eq(doc.get_control_at_sample(40, 40) & ControlCodec.AUTO_BIT, 0)
	_stroke(doc, _settings("erase", 1, 4.0), [Vector2(20, 20)] as Array[Vector2])
	var v := doc.get_control_at_sample(40, 40)
	assert_eq(v & ControlCodec.AUTO_BIT, ControlCodec.AUTO_BIT, "auto bit restored")
	assert_eq(ControlCodec.get_blend(v), 0, "no manual blend left at full coverage")
	assert_eq(PickOperation.layer_at(doc, 20.0, 20.0), WorldConstants.MATERIAL_GRASS, "rule layer shows")


func test_painting_four_layers_follows_the_rules_in_sequence() -> void:
	var doc := _doc()
	var at := [Vector2(20, 20)] as Array[Vector2]
	_stroke(doc, _settings("paint", 2, 4.0), at)
	var v := doc.get_control_at_sample(40, 40)
	assert_eq([ControlCodec.get_overlay(v), ControlCodec.get_blend(v), v & 1], [2, 255, 1], "rock over the rule layer")
	_stroke(doc, _settings("paint", 3, 4.0), at)
	v = doc.get_control_at_sample(40, 40)
	assert_eq([ControlCodec.get_base(v), ControlCodec.get_overlay(v), ControlCodec.get_blend(v), v & 1],
			[2, 3, 255, 0], "sand collapses the rock into the manual base")


func test_tint_and_untint_write_the_colour_map_only() -> void:
	var doc := _doc()
	var control_before := doc.get_region(Vector2i(0, 0)).control.duplicate()
	var change := _stroke(doc, _settings("tint", 1, 4.0), [Vector2(20, 20)] as Array[Vector2])
	assert_eq(doc.get_color_at_sample(40, 40), TintCodec.pack(RGB_LUSH, 255), "full tint at the centre")
	assert_true(doc.get_region(Vector2i(0, 0)).control == control_before, "control untouched")
	assert_true(change.before_controls.is_empty() and change.before_heights.is_empty())
	assert_eq(change.before_colors.size(), 1)
	assert_eq(doc.get_color_at_sample(48, 40) & 0xFF, 0, "radius edge")
	_stroke(doc, _settings("untint", 1, 4.0), [Vector2(20, 20)] as Array[Vector2])
	assert_eq(doc.get_color_at_sample(40, 40), TintCodec.pack(RGB_LUSH, 0), "removed, colour kept")


func test_tint_across_region_seams_is_symmetric_and_undoable() -> void:
	var doc := _doc()
	var before := doc.duplicate_deep()
	var tx := EditTransaction.new()
	tx.begin(doc, "paint", "Tint")
	var state := BrushKernels.PaintStrokeState.new(doc, tx, 1.0)
	state.op = "tint"
	state.tint_rgb = RGB_LUSH
	var res := BrushKernels.paint_segment(state, Vector2(-3.5, -0.25), Vector2(3.0, -0.25), 4.0, 1.0, 1.0, 1.0, "brush")
	assert_empty_string(res.error)
	assert_eq((res.dirty_colors as Array).size(), 4, "all four regions marked")
	assert_true((res.dirty_controls as Array).is_empty())
	var worst := 0
	for gz in range(-9, 8):
		for gx in range(-14, 14):
			worst = maxi(worst, absi(_alpha(doc, gx, gz) - _alpha(doc, -1 - gx, gz)))
			worst = maxi(worst, absi(_alpha(doc, gx, gz) - _alpha(doc, gx, -1 - gz)))
	assert_true(worst <= 1, "no seam discontinuity or asymmetry (%d)" % worst)
	assert_true(_alpha(doc, 0, -1) > 200 and _alpha(doc, -1, -1) > 200, "stroke crosses the seam")
	var change := tx.finish()
	assert_eq(change.before_colors.size(), 4)
	for loc: Vector2i in change.before_colors:
		assert_true(change.before_colors[loc] == before.get_region(loc).color, "before bytes %s" % loc)
		assert_true(change.after_colors[loc] != change.before_colors[loc])


func test_start_maps_make_painting_a_pure_function_of_coverage() -> void:
	var once := _doc()
	var twice := _doc()
	var pts: Array[Vector2] = [Vector2(20, 20), Vector2(26, 22)]
	var doubled: Array[Vector2] = [Vector2(20, 20), Vector2(26, 22), Vector2(20, 20), Vector2(26, 22)]
	for op in ["paint", "tint"]:
		_stroke(once, _settings(op, 2, 4.0), pts)
		_stroke(twice, _settings(op, 2, 4.0), doubled)
	var worst := 0
	var oc := once.get_region(Vector2i(0, 0))
	var tc := twice.get_region(Vector2i(0, 0))
	for i in oc.control.size():
		worst = maxi(worst, absi(ControlCodec.get_blend(oc.control[i]) - ControlCodec.get_blend(tc.control[i])))
		worst = maxi(worst, absi(int(oc.color[i * 4 + 3]) - int(tc.color[i * 4 + 3])))
	assert_true(worst <= 1, "retracing the stroke changes nothing beyond float noise (%d levels)" % worst)
	assert_true(worst > 0 or oc.control != PackedInt32Array(), "painted")


func test_invalid_input_writes_nothing() -> void:
	var doc := _doc()
	var tx := EditTransaction.new()
	tx.begin(doc, "paint", "Paint")
	var state := BrushKernels.PaintStrokeState.new(doc, tx, 1.0)
	state.op = "tint"
	var res := BrushKernels.paint_segment(state, Vector2(0, NAN), Vector2.ZERO, 4.0, 1.0, 1.0, 1.0, "brush")
	assert_eq(res.error, BrushKernels.ERROR_INVALID)
	assert_true((res.dirty_colors as Array).is_empty())
