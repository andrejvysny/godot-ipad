extends TestCase
## Coverage-based material paint and the path preset (spec §11.2, §12.3, §15.5; TE-03, TE-05,
## TE-12, PA-00).

const OTHER_BITS := 0x00003FFE  # nav, hole, reserved, uv scale, uv rotation

var _last_tx: EditTransaction


func _doc(control: int = ControlCodec.grass_value()) -> WorldDocument:
	return WorldDocument.create_flat(0.0, control)


func _brush(target: float = 1.0, strength: float = 0.8, radius: float = 4.0, pressure: bool = true) -> Dictionary:
	return {"radius": radius, "target_blend": target, "strength": strength,
			"pressure_enabled": pressure, "falloff_kind": PaintStroke.FALLOFF_BRUSH}


func _begin(doc: WorldDocument, settings: Dictionary, pos: Vector2, pf: float = 1.0) -> PaintStroke:
	var tx := EditTransaction.new()
	tx.begin(doc, "paint", "Paint", settings)
	var s := PaintStroke.new()
	s.begin(doc, tx, settings, pos, pf)
	_last_tx = tx
	return s


func _blend(doc: WorldDocument, gx: int, gz: int) -> int:
	return ControlCodec.get_blend(doc.get_control_at_sample(gx, gz))


func _controls(doc: WorldDocument) -> Dictionary:
	var out := {}
	for loc: Vector2i in doc.regions:
		out[loc] = doc.get_region(loc).control.duplicate()
	return out


func _max_blend_diff(a: Dictionary, b: Dictionary) -> int:
	var worst := 0
	for loc: Vector2i in a:
		var ca: PackedInt32Array = a[loc]
		var cb: PackedInt32Array = b[loc]
		for i in ca.size():
			if ca[i] != cb[i]:
				worst = maxi(worst, absi(ControlCodec.get_blend(ca[i]) - ControlCodec.get_blend(cb[i])))
	return worst


func test_lone_tap_paints_one_dab() -> void:
	var doc := _doc()
	var s := _begin(doc, _brush(1.0, 1.0), Vector2(20, 20))
	assert_empty_string(s.finish(0.0).error)
	assert_eq(_blend(doc, 40, 40), 255, "centre full dirt")
	assert_eq(_blend(doc, 44, 40), ControlCodec.quantize_blend(0.5625), "falloff at q = 0.5")
	assert_eq(_blend(doc, 48, 40), 0, "radius edge")


func test_stationary_paint_holds() -> void:
	var doc := _doc()
	var s := _begin(doc, _brush(), Vector2(5, 5))
	var after_first := _controls(doc)
	for i in 30:
		s.add_sample(i / 60.0, Vector2(5, 5), 1.0)
	assert_eq(_max_blend_diff(after_first, _controls(doc)), 0, "holding still changes nothing")
	assert_true(_controls(doc) == after_first, "bytes identical")


func test_pressure_mapping_and_pressure_off() -> void:
	var doc := _doc()
	var s := _begin(doc, _brush(1.0, 1.0), Vector2(-20, -20), BrushMath.pressure_factor(true, 0.0, true))
	s.finish(0.0)
	assert_eq(_blend(doc, -40, -40), ControlCodec.quantize_blend(0.2), "p = 0 -> factor 0.2")
	var s2 := _begin(doc, _brush(1.0, 1.0, 4.0, false), Vector2(20, -20), 0.2)
	s2.finish(0.0)
	assert_eq(_blend(doc, 40, -40), 255, "pressure disabled -> factor 1")
	var s3 := _begin(doc, _brush(1.0, 1.0), Vector2(-20, 20), BrushMath.pressure_factor(false, 0.0, true))
	s3.finish(0.0)
	assert_eq(_blend(doc, -40, 40), 255, "unavailable pressure is never zero strength")


func test_paused_gap_is_not_painted() -> void:
	var doc := _doc()
	var s := _begin(doc, _brush(1.0, 1.0, 2.0), Vector2(-20, 0))
	s.add_sample(0.1, Vector2(-10, 0), 1.0)
	s.pause(0.2)
	s.add_sample(0.3, Vector2(10, 0), 1.0)  # first sample after a pause starts a new segment
	s.add_sample(0.4, Vector2(20, 0), 1.0)
	s.finish(0.4)
	assert_eq(_blend(doc, 0, 0), 0, "gap untouched")
	assert_eq(_blend(doc, -30, 0), 255)
	assert_eq(_blend(doc, 30, 0), 255)


func test_grass_repaint_restores_blend() -> void:
	var doc := _doc(ControlCodec.encode_paint(0, 255))
	var s := _begin(doc, _brush(0.0, 1.0), Vector2(0, 0))
	s.finish(0.0)
	assert_eq(_blend(doc, 0, 0), 0, "grass target")
	assert_eq(_blend(doc, 4, 0), ControlCodec.quantize_blend(1.0 - 0.5625))


## Fixture strokes sampled at a given callback rate over 1.5 s.
func _paint_fixture(hz: float, curved: bool, settings: Dictionary = _brush(1.0, 0.8, 4.0)) -> Dictionary:
	var doc := _doc()
	var s := _begin(doc, settings, _fixture_pos(0.0, curved), _fixture_pf(0.0))
	var n := int(1.5 * hz)
	for k in range(1, n + 1):
		var u := k / hz
		assert_empty_string(s.add_sample(u, _fixture_pos(u, curved), _fixture_pf(u)).error)
	s.finish(1.5)
	return _controls(doc)


func _fixture_pos(u: float, curved: bool) -> Vector2:
	if not curved:
		return Vector2(-15.0 + 20.0 * u, -6.0 + 8.0 * u)
	var angle := -0.3 * PI + (1.1 * PI) * (u / 1.5)
	return Vector2(10.0 * cos(angle), 10.0 * sin(angle))


func _fixture_pf(u: float) -> float:
	return BrushMath.pressure_factor(true, 0.5 + 0.4 * sin(3.0 * u), true)


func test_te03_callback_rate_independence() -> void:
	for curved: bool in [false, true]:
		var c30 := _paint_fixture(30.0, curved)
		var c60 := _paint_fixture(60.0, curved)
		var c120 := _paint_fixture(120.0, curved)
		var d := maxi(maxi(_max_blend_diff(c30, c60), _max_blend_diff(c60, c120)), _max_blend_diff(c30, c120))
		print("    TE-03 %s max blend level difference 30/60/120 Hz: %d" % ["curved" if curved else "straight", d])
		assert_true(d <= 1, "%s differs by %d levels" % ["curved" if curved else "straight", d])
		assert_true(c60 != _controls(_doc()), "fixture painted something")


func _rate_diff(curved: bool, settings: Dictionary) -> int:
	var c30 := _paint_fixture(30.0, curved, settings)
	var c60 := _paint_fixture(60.0, curved, settings)
	var c120 := _paint_fixture(120.0, curved, settings)
	return maxi(maxi(_max_blend_diff(c30, c60), _max_blend_diff(c60, c120)), _max_blend_diff(c30, c120))


## TE-03 for the shipped presets (path widths 2/3/6 m, brush radius 1-16 m), each rate sampling
## the straight fixture independently.
func test_te03_shipped_presets_straight_fixture() -> void:
	var presets: Array[Dictionary] = [PaintStroke.path_settings(2.0), PaintStroke.path_settings(3.0),
			PaintStroke.path_settings(6.0), _brush(1.0, 1.0, 1.0), _brush(1.0, 0.8, 16.0)]
	for settings: Dictionary in presets:
		var d := _rate_diff(false, settings)
		assert_true(d <= 1, "%s %.1f m differs by %d levels" % [settings.falloff_kind, settings.radius, d])


## TE-03 curved: one 240 Hz Pencil trace delivered in 30/60/120 Hz callbacks (4/2/... coalesced
## samples per callback). Independently sampling a curve at each rate changes the input polyline
## itself (chord error), which no kernel can undo; see the stream report.
func test_te03_curved_trace_batched_into_callback_rates() -> void:
	for settings: Dictionary in [PaintStroke.path_settings(2.0), _brush(1.0, 1.0, 1.0)]:
		var results: Array[Dictionary] = []
		for hz: float in [30.0, 60.0, 120.0]:
			var doc := _doc()
			var s := _begin(doc, settings, _fixture_pos(0.0, true), _fixture_pf(0.0))
			var k := 1
			for frame in range(1, int(1.5 * hz) + 1):
				while k <= 360 and k / 240.0 <= frame / hz:
					assert_empty_string(s.add_sample(k / 240.0, _fixture_pos(k / 240.0, true), _fixture_pf(k / 240.0)).error)
					k += 1
			s.finish(1.5)
			results.append(_controls(doc))
		assert_eq(_max_blend_diff(results[0], results[1]), 0, "30 vs 60")
		assert_eq(_max_blend_diff(results[1], results[2]), 0, "60 vs 120")


func test_path_falloff_ignores_pressure_even_if_enabled() -> void:
	var with_pressure := PaintStroke.path_settings(3.0)
	with_pressure.pressure_enabled = true
	var a := _paint_fixture(60.0, true, with_pressure)
	var b := _paint_fixture(60.0, true, PaintStroke.path_settings(3.0))
	assert_true(a == b, "path paints with factor 1 whatever the pressure")


func test_non_finite_pressure_is_full_strength() -> void:
	var doc := _doc()
	var s := _begin(doc, _brush(1.0, 1.0), Vector2(20, 20), NAN)
	s.add_sample(0.1, Vector2(24, 20), INF)
	assert_empty_string(s.finish(0.1).error)
	assert_eq(_blend(doc, 40, 40), 255, "NaN factor -> 1")
	assert_eq(_blend(doc, 44, 40), 255, "coverage from the first dab is not NaN-poisoned")
	assert_eq(_blend(doc, 48, 40), 255, "INF factor -> 1")
	assert_eq(_blend(doc, 40, 44), ControlCodec.quantize_blend(0.5625), "falloff at q = 0.5, factor 1")


func test_reserved_and_unrelated_bits_preserved() -> void:
	var base := ControlCodec.grass_value() | OTHER_BITS
	var doc := _doc(base)
	doc.get_region(Vector2i(0, 0)).control[3 * 256 + 3] = base | ControlCodec.AUTO_BIT
	var s := _begin(doc, _brush(1.0, 1.0, 5.0), Vector2(-3, -3))
	s.add_sample(0.2, Vector2(3, 3), 1.0)
	s.finish(0.2)
	var painted := 0
	var bad := 0
	for loc: Vector2i in doc.regions:
		var ctrl := doc.get_region(loc).control
		for i in ctrl.size():
			var v := ctrl[i] & 0xFFFFFFFF
			if (v & ~ControlCodec.PAINT_OWNED_MASK & 0xFFFFFFFF) != OTHER_BITS:
				bad += 1
			if ControlCodec.get_blend(v) > 0:
				painted += 1
				if ControlCodec.get_base(v) != 0 or ControlCodec.get_overlay(v) != 1:
					bad += 1
	assert_eq(bad, 0, "unrelated bits preserved and invariant held")
	assert_true(painted > 100, "painted %d samples" % painted)
	# v2 rules (docs/editor-v2.md §4) keep the auto bit: manual paint sits over the rule layer.
	assert_eq(doc.get_control_at_sample(3, 3), ControlCodec.encode_paint(base, 255) | ControlCodec.AUTO_BIT, "auto bit kept where painted")


func test_te12_cancel_after_touching_four_regions_restores_hash() -> void:
	var doc := _doc()
	var before := CanonicalEncoder.authored_hash(doc)
	var s := _begin(doc, _brush(), Vector2(-3, 2))
	var r := s.add_sample(0.1, Vector2(3, -2), 1.0)
	assert_eq((r.dirty_controls as Array).size(), 4)
	var touched := s.cancel()
	assert_eq((touched.controls as Array).size(), 4)
	assert_eq(CanonicalEncoder.authored_hash(doc), before)


func test_te05_paint_undo_redo_byte_exact() -> void:
	var doc := _doc(ControlCodec.grass_value() | OTHER_BITS)
	var before := _controls(doc)
	var hist := CommandHistory.new()
	var s := _begin(doc, _brush(), Vector2(-3, 2))
	s.add_sample(0.1, Vector2(3, -2), 0.6)
	s.finish(0.1)
	var change := _last_tx.finish()
	doc.bump_revision()
	hist.push_already_applied(change)
	var after := _controls(doc)
	hist.undo(doc)
	assert_true(_controls(doc) == before, "undo exact")
	hist.redo(doc)
	assert_true(_controls(doc) == after, "redo exact")


func test_pa00_path_preset_width_controlled_dirt() -> void:
	var doc := _doc()
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.asset_id = "nature.tree.spruce_a"
	rec.asset_version = 1
	rec.set_position(0.0, 0.0, 5.1)
	doc.put_object(rec)
	var before_hash := CanonicalEncoder.authored_hash(doc)
	var settings := PaintStroke.path_settings(3.0)
	var a := Vector2(-20.0, 5.1)
	var b := Vector2(20.0, 5.1)
	var s := _begin(doc, settings, a, 0.1)  # pressure is ignored by the preset
	for k in range(1, 41):
		s.add_sample(k * 0.02, a.lerp(b, k / 40.0), 0.1)
	assert_empty_string(s.finish(0.8).error)
	var tx := _last_tx
	var inner_bad := 0
	var outer_bad := 0
	for gz in range(0, 24):
		for gx in range(-50, 51):
			var p := Vector2(gx * 0.5, gz * 0.5)
			var d := _dist_to_segment(p, a, b)
			var v := doc.get_control_at_sample(gx, gz)
			if d <= 0.9 and ControlCodec.get_blend(v) != 255:
				inner_bad += 1
			if d >= 1.5 and v != ControlCodec.grass_value():
				outer_bad += 1
	assert_eq(inner_bad, 0, "within 0.9 m of the centreline is full dirt")
	assert_eq(outer_bad, 0, "beyond 1.5 m unchanged")
	assert_true(doc.get_object(rec.object_id).equals(rec), "object untouched")
	assert_true(tx.captured_object_ids().is_empty(), "no object captured")
	var change := tx.finish()
	var hist := CommandHistory.new()
	doc.bump_revision()
	hist.push_already_applied(change)
	assert_eq(hist.size(), 1, "one transaction")
	hist.undo(doc)
	assert_eq(CanonicalEncoder.authored_hash(doc), before_hash, "one undo restores paint")


func test_timing_paint_segment_via_stroke() -> void:
	var doc := _doc()
	var s := _begin(doc, _brush(1.0, 0.8, 16.0), Vector2(0, 0))
	var t0 := Time.get_ticks_usec()
	for k in range(1, 11):
		s.add_sample(k / 120.0, Vector2(k * 0.05, 0), 1.0)
	print("    TIMING r=16m paint piece via PaintStroke %.2f ms" % ((Time.get_ticks_usec() - t0) / 10000.0))
	assert_empty_string(s.finish(0.1).error)


static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var u := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * u)
