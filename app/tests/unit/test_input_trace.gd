extends TestCase
## InputTrace ring, persistence, determinism and the recorded fixture traces (spec §18.3).

const FIXTURE_DIR := "res://tests/input_traces"
const FIXTURES: PackedStringArray = [
	"palm_rest_then_pencil.json", "finger_joins_pencil_stroke.json", "pencil_during_orbit.json",
	"two_to_one_finger.json", "stroke_crosses_ui.json", "native_cancel_mid_stroke.json",
]
const UI_RAIL := Rect2(0, 0, 100, 820)

var _saved: PackedStringArray = []


func after_each() -> void:
	for f in _saved:
		DirAccess.remove_absolute(InputTrace.TRACE_DIR + f)
	_saved.clear()


func _sample(source: int, id: int, phase: int, pos: Vector2) -> PointerSample:
	var s := PointerSample.new()
	s.source = source
	s.pointer_id = id
	s.phase = phase
	s.position_raw = pos
	s.position_viewport = pos
	return s


func _router_for(config: Dictionary) -> InputRouter:
	var r := InputRouter.new()
	r.orbit_threshold = float(config.get("orbit_threshold", 5.0))
	var rects: Array[Rect2] = []
	for v: Variant in config.get("ui_rects", []):
		var a: Array = v
		rects.append(Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3])))
	r.ui_hit_test = func(p: Vector2) -> bool:
		for rect in rects:
			if rect.has_point(p):
				return true
		return false
	return r


func test_ring_is_bounded_and_keeps_newest() -> void:
	var t := InputTrace.new(5)
	t.start()
	for i in 8:
		t.record_event("mark", {"i": i})
	assert_eq(t.size(), 5)
	assert_eq(t.dropped, 3)
	var e := t.entries()
	assert_eq(e[0].data.i, 3, "oldest kept")
	assert_eq(e[4].data.i, 7, "newest last")
	t.clear()
	assert_eq(t.size(), 0)
	assert_eq(t.dropped, 0)
	assert_eq(InputTrace.new().capacity, 10000, "default bound")


func test_records_only_while_started() -> void:
	var t := InputTrace.new()
	t.record_sample(_sample(PointerSample.Source.PENCIL, 1, PointerSample.Phase.BEGIN, Vector2.ONE))
	assert_eq(t.size(), 0, "off by default")
	t.start()
	t.record_sample(_sample(PointerSample.Source.PENCIL, 1, PointerSample.Phase.BEGIN, Vector2.ONE))
	t.record_action({"type": "tool_begin", "sample": _sample(1, 1, 0, Vector2(3, 4))})
	t.stop()
	t.record_event("cancel_all", {"reason": "explicit"})
	assert_eq(t.size(), 2)
	var action: Dictionary = t.entries()[1].data
	assert_eq(action.sample.vp, [3.0, 4.0], "actions are JSON-safe")


func test_sample_dict_round_trip() -> void:
	var s := _sample(PointerSample.Source.FINGER, 42, PointerSample.Phase.CANCEL, Vector2(12.5, 7.25))
	s.position_raw = Vector2(6.25, 3.625)
	s.pressure_valid = true
	s.pressure = 0.5
	s.tilt_valid = true
	s.tilt = Vector2(0.25, -0.5)
	s.is_coalesced = true
	s.sample_sequence = 99
	s.mapping_generation = 3
	s.cancel_reason = "queue_overflow"
	var json: Variant = JSON.parse_string(JSON.stringify(s.to_dict()))
	var back := InputTrace.sample_from_dict(json)
	assert_eq(back.to_dict(), s.to_dict())


func test_save_load_replay_is_deterministic() -> void:
	var r := _router_for({"ui_rects": [[0, 0, 100, 820]]})
	var t := InputTrace.new()
	t.start()
	var script := [
		[PointerSample.Source.FINGER, 10, PointerSample.Phase.BEGIN, Vector2(600, 400)],
		[PointerSample.Source.FINGER, 10, PointerSample.Phase.MOVE, Vector2(630.5, 410.25)],
		[PointerSample.Source.FINGER, 11, PointerSample.Phase.BEGIN, Vector2(800, 400)],
		[PointerSample.Source.FINGER, 11, PointerSample.Phase.MOVE, Vector2(840, 420)],
		[PointerSample.Source.PENCIL, 1, PointerSample.Phase.BEGIN, Vector2(300, 300)],
		[PointerSample.Source.PENCIL, 1, PointerSample.Phase.MOVE, Vector2(50, 300)],
		[PointerSample.Source.PENCIL, 1, PointerSample.Phase.MOVE, Vector2(320, 310)],
		[PointerSample.Source.FINGER, 11, PointerSample.Phase.END, Vector2(840, 420)],
		[PointerSample.Source.PENCIL, 1, PointerSample.Phase.END, Vector2(320, 310)],
		[PointerSample.Source.PENCIL, 2, PointerSample.Phase.BEGIN, Vector2(40, 40)],
	]
	for step: Array in script:
		var s := _sample(step[0], step[1], step[2], step[3])
		t.record_sample(s)
		for a in r.process(s):
			t.record_action(a)
	t.record_event("cancel_all", {"reason": "explicit"})
	for a in r.cancel_all("explicit"):
		t.record_action(a)
	var name := "test_trace_%d.json" % Time.get_ticks_usec()
	assert_empty_string(t.save(name), "save")
	_saved.append(name)
	var text := FileAccess.get_file_as_string(InputTrace.TRACE_DIR + name)
	assert_false(text.contains("user://") or text.contains("/Users/") or text.contains("res://"),
			"no filesystem paths in trace")
	var loaded := InputTrace.load_file(InputTrace.TRACE_DIR + name)
	assert_empty_string(loaded.error, "load")
	var recorded: Array = []
	for e: Dictionary in loaded.entries:
		if e.kind == "action":
			recorded.append(e.data)
	assert_true(recorded.size() >= 8, "session produced actions (%d)" % recorded.size())
	var replayed := InputTrace.replay(_router_for({"ui_rects": [[0, 0, 100, 820]]}), loaded.entries)
	assert_empty_string(InputTrace.match_actions(replayed, recorded), "replay equals recording")
	var again := InputTrace.replay(_router_for({"ui_rects": [[0, 0, 100, 820]]}), loaded.entries)
	assert_empty_string(InputTrace.match_actions(again, recorded), "second replay identical")


func test_save_rejects_paths() -> void:
	var t := InputTrace.new()
	assert_error_contains(t.save("../escape.json"), "plain name")
	assert_error_contains(t.save("sub/x.json"), "plain name")
	assert_error_contains(t.save(""), "plain name")


func test_load_rejects_non_traces() -> void:
	assert_error_contains(InputTrace.load_file("res://tests/input_traces/missing.json").error, "cannot read")
	assert_error_contains(InputTrace.load_file("res://project.godot").error, "not a trace")


func _good_sample() -> Dictionary:
	return _sample(PointerSample.Source.PENCIL, 1, PointerSample.Phase.BEGIN, Vector2(300, 300)).to_dict()


func _save_raw(entries: Array, format: Variant = InputTrace.FORMAT) -> String:
	var name := "test_malformed_%d_%d.json" % [Time.get_ticks_usec(), randi()]
	var f := FileAccess.open(InputTrace.TRACE_DIR + name, FileAccess.WRITE)
	f.store_string(JSON.stringify({"format": format, "version": 1, "entries": entries}))
	f.close()
	_saved.append(name)
	return InputTrace.TRACE_DIR + name


func test_malformed_entries_are_rejected_not_defaulted() -> void:
	DirAccess.make_dir_recursive_absolute(InputTrace.TRACE_DIR)
	var cases := {
		"unknown phase": ["phase", "TAP"],
		"unknown source": ["source", "STYLUS"],
		"id is not an integer": ["id", "one"],
		"raw is not": ["raw", [1]],
		"vp is not": ["vp", "here"],
		"pressure is not a number": ["pressure", "hard"],
		"predicted is not a boolean": ["predicted", 1],
	}
	for needle: String in cases:
		var bad := _good_sample()
		bad[cases[needle][0]] = cases[needle][1]
		assert_eq(InputTrace.sample_from_dict(bad), null, needle)
		var loaded := InputTrace.load_file(_save_raw([{"kind": "sample", "data": _good_sample()},
				{"kind": "sample", "data": bad}]))
		assert_error_contains(loaded.error, "entry 1", needle)
		assert_error_contains(loaded.error, needle)
		assert_true(loaded.entries.is_empty(), "%s: nothing half-loaded" % needle)
	for entries: Array in [[[1, 2]], [{"kind": "sample", "data": [1]}], [{"kind": "gesture", "data": {}}],
			[{"kind": "event", "data": {"op": "explode"}}], [{"kind": "event", "data": {"op": "set_modal"}}]]:
		assert_error_contains(InputTrace.load_file(_save_raw(entries)).error, "entry 0", str(entries))
	assert_error_contains(InputTrace.load_file(_save_raw([], 7)).error, "format")


func test_replay_skips_malformed_entries_with_diagnostic() -> void:
	var bad_phase := _good_sample()
	bad_phase.phase = "TAP"
	var bad_id := _good_sample()
	bad_id.id = "x"
	var entries := [bad_phase, [1, 2], {"kind": "sample", "data": bad_phase},
			{"kind": "sample", "data": bad_id}, {"kind": "sample", "data": _good_sample()}]
	var actions := InputTrace.replay(_router_for({}), entries)
	var types := PackedStringArray()
	for a in actions:
		types.append(a.type if a.type != "diagnostic" else "diagnostic:" + str(a.code))
	assert_eq(types, PackedStringArray(["diagnostic:invalid_trace_entry", "diagnostic:invalid_trace_entry",
			"diagnostic:invalid_trace_entry", "diagnostic:invalid_trace_entry", "tool_begin"]),
			"no bogus BEGIN, no script error, valid entry still replayed")


func test_match_actions_reports_mismatch() -> void:
	var got: Array[Dictionary] = [{"type": "camera_orbit", "delta": Vector2(1, 2)}]
	assert_empty_string(InputTrace.match_actions(got, [{"type": "camera_orbit", "delta": [1, 2.00001]}]))
	assert_error_contains(InputTrace.match_actions(got, [{"type": "camera_orbit", "delta": [1, 3]}]), "delta")
	assert_error_contains(InputTrace.match_actions(got, []), "expected 0 actions")


func test_fixture_traces_replay_to_expected_actions() -> void:
	for f in FIXTURES:
		var loaded := InputTrace.load_file(FIXTURE_DIR.path_join(f))
		if not assert_empty_string(loaded.error, f):
			continue
		var data: Dictionary = loaded.data
		var r := _router_for(data.router)
		var actions := InputTrace.replay(r, loaded.entries)
		assert_empty_string(InputTrace.match_actions(actions, data.expected_actions), f)
		assert_eq(r.state_name(), str(data.expected_final_state), "%s final state" % f)
		assert_true(r.contacts().is_empty(), "%s: no stale contacts" % f)


func test_fixture_set_is_complete() -> void:
	var present := DirAccess.get_files_at(FIXTURE_DIR)
	for f in FIXTURES:
		assert_true(present.has(f), "fixture %s present" % f)
