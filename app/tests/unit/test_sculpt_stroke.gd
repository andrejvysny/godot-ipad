extends TestCase
## Time-integrated raise/lower strokes (spec §13.1, §16; TE-04, TE-05, TE-12).

const STEP := 1.0 / 60.0
const SAMPLE_HZ := 229.0


func _doc() -> WorldDocument:
	return WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, AssetCatalog.load_from()[0])


func _settings(radius: float = 6.0, direction: float = 1.0, pressure: bool = true) -> Dictionary:
	return {"radius": radius, "direction": direction, "speed_m_per_s": 2.0, "strength": 1.0,
			"pressure_enabled": pressure, "fixed_step_s": STEP}


func _begin(doc: WorldDocument, settings: Dictionary, t0: float, pos: Vector2, pf: float = 1.0) -> SculptStroke:
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise", settings)
	var s := SculptStroke.new()
	s.begin(doc, tx, settings, t0, pos, pf)
	return s


## Advances in `frame` second increments up to t_end, then finishes; returns the first error.
func _hold(s: SculptStroke, t0: float, t_end: float, frame: float) -> String:
	var t := t0
	while t + frame < t_end:
		t += frame
		var r := s.advance_to(t)
		if r.error != "":
			return r.error
	return s.finish(t_end).error


## Advances frame by frame (60 Hz) from t_from to t_to; returns the merged result.
func _tick(s: SculptStroke, t_from: float, t_to: float) -> Dictionary:
	var merged := BrushKernels.empty_result()
	var t := t_from
	while t < t_to:
		t = minf(t + 1.0 / 60.0, t_to)
		BrushKernels.merge_result(merged, s.advance_to(t))
	return merged


func _heights(doc: WorldDocument) -> Dictionary:
	var out := {}
	for loc: Vector2i in doc.regions:
		out[loc] = doc.get_region(loc).heights.duplicate()
	return out


func _max_diff(a: Dictionary, b: Dictionary) -> float:
	var worst := 0.0
	for loc: Vector2i in a:
		var ha: PackedFloat32Array = a[loc]
		var hb: PackedFloat32Array = b[loc]
		for i in ha.size():
			worst = maxf(worst, absf(ha[i] - hb[i]))
	return worst


func test_stationary_raise_grows_at_speed_times_dt() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(), 10.0, Vector2(10, 10))
	assert_empty_string(_hold(s, 10.0, 11.0, 1.0 / 60.0))
	assert_near(doc.get_height_at_sample(20, 20), 2.0, 1e-4, "centre after 1 s at 2 m/s")
	# (1 - 0.5^2)^2 of the centre rate at half radius.
	assert_near(doc.get_height_at_sample(26, 20), 2.0 * 0.5625, 1e-4, "falloff at q = 0.5")
	assert_eq(doc.get_height_at_sample(32, 20), 0.0, "radius edge")


func test_lower_direction_and_partial_final_interval() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(4.0, -1.0), 0.0, Vector2(-30, 40))
	s.advance_to(0.1)
	var r := s.finish(0.125)
	assert_empty_string(r.error)
	assert_near(doc.get_height_at_sample(-60, 80), -0.25, 1e-5, "resolves the final partial step exactly")


func test_pressure_factor_scales_rate_and_off_means_full() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(), 0.0, Vector2(-40, -40), 0.2)
	assert_empty_string(_hold(s, 0.0, 0.5, 1.0 / 60.0))
	assert_near(doc.get_height_at_sample(-80, -80), 0.2 * 2.0 * 0.5, 1e-5, "factor 0.2")
	var s2 := _begin(doc, _settings(6.0, 1.0, false), 0.0, Vector2(40, 40), 0.2)
	assert_empty_string(_hold(s2, 0.0, 0.5, 1.0 / 60.0))
	assert_near(doc.get_height_at_sample(80, 80), 1.0, 1e-5, "pressure off ignores the factor")


## Fixed 229 Hz sample timeline (deliberately not aligned with the 60 Hz steps) replayed at several frame cadences with jitter; samples are
## delivered only once `lag` seconds after their timestamp, as in a live session.
func _replay(fps: float, jitter_seed: int, direction: float = 1.0, lag: float = 0.0) -> Dictionary:
	var doc := _doc()
	var t0 := 5.0
	var duration := 1.5
	var s := _begin(doc, _settings(5.0, direction), t0, _path(0.0), _path_pf(0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = jitter_seed
	var n_samples := int(duration * SAMPLE_HZ)
	var next := 1
	var frame := 0
	while true:
		frame += 1
		var now := t0 + frame / fps + rng.randf_range(-0.3, 0.3) / fps
		if now >= t0 + duration:
			break
		while next <= n_samples and float(next) / SAMPLE_HZ + lag <= now - t0:
			var u := float(next) / SAMPLE_HZ
			s.add_sample(t0 + u, _path(u), _path_pf(u))
			next += 1
		assert_empty_string(s.advance_to(now).error, "advance at %.1f Hz" % fps)
	while next <= n_samples:
		var u := float(next) / SAMPLE_HZ
		s.add_sample(t0 + u, _path(u), _path_pf(u))
		next += 1
	assert_empty_string(s.finish(t0 + duration).error)
	return _heights(doc)


func _path(u: float) -> Vector2:
	return Vector2(-8.0 + 10.0 * u, 3.0 * sin(2.5 * u))


func _path_pf(u: float) -> float:
	return BrushMath.pressure_factor(true, 0.5 + 0.4 * sin(4.0 * u), true)


func test_te04_timed_raise_replay_independent_of_frame_rate() -> void:
	var h30 := _replay(30.0, 1)
	var h60 := _replay(60.0, 2)
	var h144 := _replay(144.0, 3)
	var d1 := _max_diff(h30, h60)
	var d2 := _max_diff(h60, h144)
	var d3 := _max_diff(h30, h144)
	print("    TE-04 raise max |dh| 30v60 %.6f m, 60v144 %.6f m, 30v144 %.6f m" % [d1, d2, d3])
	assert_true(d1 < 0.01 and d2 < 0.01 and d3 < 0.01, "below 1 cm")
	var peak := 0.0
	for loc: Vector2i in h60:
		for h in (h60[loc] as PackedFloat32Array):
			peak = maxf(peak, h)
	assert_true(peak > 0.3, "stroke actually raised terrain (peak %.3f)" % peak)
	var l30 := _replay(30.0, 4, -1.0)
	var l144 := _replay(144.0, 5, -1.0)
	var dl := _max_diff(l30, l144)
	print("    TE-04 lower max |dh| 30v144 %.6f m" % dl)
	assert_true(dl < 0.01, "lower below 1 cm")


func test_te04_prerecorded_timeline_is_bit_identical_across_cadences() -> void:
	var results: Array[Dictionary] = []
	for fps: float in [30.0, 60.0, 144.0]:
		var doc := _doc()
		var s := _begin(doc, _settings(5.0), 0.0, _path(0.0), _path_pf(0.0))
		for k in range(1, 361):
			s.add_sample(k / 240.0, _path(k / 240.0), _path_pf(k / 240.0))
		assert_empty_string(_hold(s, 0.0, 1.5, 1.0 / fps))
		results.append(_heights(doc))
	assert_eq(_max_diff(results[0], results[1]), 0.0, "30 vs 60")
	assert_eq(_max_diff(results[1], results[2]), 0.0, "60 vs 144")


## Samples reach the stroke one or more frames after their timestamp (UIKit -> router latency).
## Within the input latency allowance no step is processed ahead of the known input.
func test_te04_lagged_delivery_independent_of_frame_rate() -> void:
	var reference := _replay(60.0, 9, 1.0, 0.0)
	for lag: float in [1.0 / 60.0, 0.025, 0.04]:
		var h30 := _replay(30.0, 11, 1.0, lag)
		var h144 := _replay(144.0, 12, 1.0, lag)
		var d := maxf(_max_diff(h30, h144), maxf(_max_diff(h30, reference), _max_diff(h144, reference)))
		print("    TE-04 lag %.3f s max |dh| vs 30/144/zero-lag %.6f m" % [lag, d])
		assert_true(d < 0.01, "lag %.3f below 1 cm (%.6f)" % [lag, d])
		assert_eq(d, 0.0, "lag %.3f within the allowance is exact" % lag)


## An invalid hit reported late must not have been sculpted with the held position (spec §11.3).
## 240 Hz samples, a pause (invalid hit) at 0.5 s, resume at 1.0 s; every event arrives 30 ms late.
func test_late_pause_writes_nothing_in_invalid_interval() -> void:
	var events: Array = []
	for k in range(1, 121):
		events.append([k / 240.0, "add", Vector2(-20.0 + 10.0 * k / 120.0, 0.0)])
	events.append([0.5, "pause", Vector2.ZERO])
	events.append([1.0, "resume", Vector2(10, 0)])
	for k in range(1, 61):
		events.append([1.0 + k / 240.0, "add", Vector2(10.0 + 5.0 * k / 60.0, 0.0)])
	var live := _doc()
	var s := _begin(live, _settings(3.0), 0.0, Vector2(-20, 0))
	var next := 0
	var now := 0.0
	while now < 1.3:
		now += 1.0 / 60.0
		while next < events.size() and float(events[next][0]) + 0.03 <= now:
			_apply(s, events[next])
			next += 1
		assert_empty_string(s.advance_to(now).error)
	assert_empty_string(s.finish(1.3).error)
	var recorded := _doc()
	var s2 := _begin(recorded, _settings(3.0), 0.0, Vector2(-20, 0))
	for e: Array in events:
		_apply(s2, e)
	assert_empty_string(_hold(s2, 0.0, 1.3, 1.0 / 60.0))
	assert_eq(_max_diff(_heights(live), _heights(recorded)), 0.0, "late events match the recorded timeline")
	assert_eq(live.get_height_at_sample(0, 0), 0.0, "gap untouched")
	assert_true(live.get_height_at_sample(-20, 0) > 0.0, "first segment raised")


func _apply(s: SculptStroke, e: Array) -> void:
	match str(e[1]):
		"add":
			s.add_sample(e[0], e[2], 1.0)
		"pause":
			s.pause(e[0])
		"resume":
			s.resume(e[0], e[2], 1.0)


func test_invalid_times_and_step_fail_without_hanging() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(), 0.0, Vector2(0, 0))
	assert_eq(s.advance_to(NAN).error, SculptStroke.ERROR_INVALID, "NaN now")
	s.cancel()
	var s2 := _begin(doc, _settings(), NAN, Vector2(0, 0))
	assert_eq(s2.error, SculptStroke.ERROR_INVALID, "NaN t0 rejected at begin")
	assert_eq(s2.advance_to(1.0).error, SculptStroke.ERROR_INVALID)
	for step: float in [0.0, -1.0, NAN, INF]:
		var bad := _settings()
		bad.fixed_step_s = step
		var s3 := _begin(doc, bad, 0.0, Vector2(0, 0))
		assert_eq(s3.advance_to(0.1).error, SculptStroke.ERROR_INVALID, "fixed_step_s %s" % step)
	assert_eq(doc.get_height_at_sample(0, 0), 0.0, "nothing written")


func test_non_finite_pressure_is_full_strength_and_never_nan() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(), 0.0, Vector2(0, 0), NAN)
	s.add_sample(0.2, Vector2(0, 0), INF)
	assert_empty_string(_hold(s, 0.0, 0.5, 1.0 / 60.0))
	assert_near(doc.get_height_at_sample(0, 0), 1.0, 1e-5, "factor 1 at 2 m/s for 0.5 s")


func test_non_finite_position_fails_the_stroke_without_writing() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(), 0.0, Vector2(0, 0))
	s.add_sample(0.05, Vector2(NAN, 0), 1.0)
	var err := _hold(s, 0.0, 0.2, 1.0 / 60.0)
	assert_eq(err, BrushKernels.ERROR_INVALID)
	s.cancel()
	var bad := 0
	for loc: Vector2i in doc.regions:
		for h in doc.get_region(loc).heights:
			if not is_finite(h) or h != 0.0:
				bad += 1
	assert_eq(bad, 0, "no NaN and fully rolled back")


func test_paused_gap_is_not_sculpted() -> void:
	var doc := _doc()
	var s := _begin(doc, _settings(3.0), 0.0, Vector2(-20, 0))
	s.add_sample(0.5, Vector2(-10, 0), 1.0)
	s.pause(0.5)
	assert_empty_string(_tick(s, 0.0, 0.9).error)
	s.resume(1.0, Vector2(10, 0), 1.0)
	s.add_sample(1.25, Vector2(20, 0), 1.0)
	assert_empty_string(_tick(s, 0.9, 1.25).error)
	assert_empty_string(s.finish(1.25).error)
	assert_eq(doc.get_height_at_sample(0, 0), 0.0, "gap midpoint untouched")
	assert_eq(doc.get_height_at_sample(-12, 0), 0.0, "no bridge from the pause point")
	assert_true(doc.get_height_at_sample(-30, 0) > 0.0, "first segment raised")
	assert_true(doc.get_height_at_sample(30, 0) > 0.0, "second segment raised")


## ADR 0012: a long main-loop gap never cancels; the backlog is applied in bounded merged work.
func test_long_gap_applies_backlog_without_error() -> void:
	var exact_doc := _doc()
	var exact := _begin(exact_doc, _settings(), 0.0, Vector2(0, 0))
	assert_empty_string(_tick(exact, 0.0, 1.1).error)
	var doc := _doc()
	var s := _begin(doc, _settings(), 0.0, Vector2(0, 0))
	assert_empty_string(s.advance_to(0.1).error)
	var pieces := s.pieces_applied
	assert_empty_string(s.advance_to(1.1).error, "a 1 s gap is not an error")
	assert_eq(s.steps_processed, exact.steps_processed, "every step's time is processed")
	assert_true(s.pieces_applied - pieces <= SculptStroke.MERGED_INTERVALS, "bounded work: %d pieces" % (s.pieces_applied - pieces))
	var d := absf(doc.get_height_at_sample(0, 0) - exact_doc.get_height_at_sample(0, 0))
	assert_true(d < 1e-4, "stationary raise volume preserved (|dh| %.6f)" % d)
	assert_empty_string(s.finish(1.2).error)


func test_backlog_of_a_moving_dense_stroke_stays_close_to_exact() -> void:
	var exact_doc := _doc()
	var exact := _begin(exact_doc, _settings(5.0), 0.0, _path(0.0), _path_pf(0.0))
	var doc := _doc()
	var s := _begin(doc, _settings(5.0), 0.0, _path(0.0), _path_pf(0.0))
	for k in range(1, 361):
		exact.add_sample(k / 240.0, _path(k / 240.0), _path_pf(k / 240.0))
		s.add_sample(k / 240.0, _path(k / 240.0), _path_pf(k / 240.0))
	assert_empty_string(_hold(exact, 0.0, 1.5, 1.0 / 60.0))
	var calls := 0
	var t := 0.0
	while t + 0.25 < 1.5:  # 4 fps: every advance is far behind
		t += 0.25
		var before := s.pieces_applied
		assert_empty_string(s.advance_to(t).error)
		calls = maxi(calls, s.pieces_applied - before)
	assert_empty_string(s.finish(1.5).error)
	assert_true(calls < 15 * 4, "merged advances use far fewer kernel calls than 60 per 0.25 s (%d)" % calls)
	var d := _max_diff(_heights(exact_doc), _heights(doc))
	print("    backlog merge max |dh| vs exact %.6f m" % d)
	assert_true(d < 0.02, "merged result stays within 2 cm of the exact stroke (%.6f)" % d)


func test_smooth_backlog_is_stable() -> void:
	var doc := _doc()
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for i in r.heights.size():
			r.heights[i] = 4.0 if (i / 7) % 2 == 0 else -4.0
	doc.invalidate_all_height_ranges()
	var settings := _settings(8.0)
	settings["kind"] = "smooth"
	var s := _begin(doc, settings, 0.0, Vector2(0, 0))
	assert_empty_string(s.advance_to(3.0).error, "3 s backlog of smoothing")
	assert_empty_string(s.finish(3.0).error)
	var h := doc.get_height_at_sample(0, 0)
	assert_true(is_finite(h) and h >= -4.0 and h <= 4.0, "smoothing never overshoots: %f" % h)


func test_te12_cancel_after_touching_four_regions_restores_hash() -> void:
	var doc := _doc()
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = doc.assets.bundled_binding_for("nature.rock.boulder_a")
	rec.set_position(1.0, 0.0, 1.0)
	doc.put_object(rec)
	var before := CanonicalEncoder.authored_hash(doc)
	var s := _begin(doc, _settings(8.0), 0.0, Vector2(-2, -2))
	s.add_sample(0.2, Vector2(2, 2), 1.0)
	var r := _tick(s, 0.0, 0.3)
	assert_empty_string(r.error)
	assert_eq((r.dirty_heights as Array).size(), 4, "all four regions touched")
	assert_true((r.rect as Rect2).has_point(Vector2(0, 0)), "result rect covers the stroke")
	assert_ne(CanonicalEncoder.authored_hash(doc), before)
	s.cancel()
	assert_eq(CanonicalEncoder.authored_hash(doc), before, "pre-stroke authored hash")


func test_te05_raise_then_undo_redo_is_byte_exact() -> void:
	var doc := _doc()
	var hist := CommandHistory.new()
	var before_bytes := _region_bytes(doc)
	var tx := EditTransaction.new()
	tx.begin(doc, "sculpt", "Raise")
	var s := SculptStroke.new()
	s.begin(doc, tx, _settings(6.0), 0.0, Vector2(1, -1), 0.7)
	s.add_sample(0.3, Vector2(-1, 1), 0.9)
	assert_empty_string(_hold(s, 0.0, 0.4, 1.0 / 60.0))
	var change := tx.finish()
	assert_true(change != null)
	doc.bump_revision()
	hist.push_already_applied(change)
	var after_bytes := _region_bytes(doc)
	assert_ne(after_bytes, before_bytes)
	hist.undo(doc)
	assert_eq(_region_bytes(doc), before_bytes, "undo exact")
	hist.redo(doc)
	assert_eq(_region_bytes(doc), after_bytes, "redo exact")


func _region_bytes(doc: WorldDocument) -> PackedByteArray:
	var out := PackedByteArray()
	for loc in doc.sorted_region_locations():
		out.append_array(doc.get_region(loc).height_bytes())
	return out
