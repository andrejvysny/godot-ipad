extends TestCase
## IOSNativeInputProvider record decoding and health signalling, driven by hand-built records and a
## fake bridge. Real UIKit delivery is a device test (native/ios_input/README.md), NOT covered here.

const P := preload("res://src/input/ios_native_input_provider.gd")
const STRIDE := IOSNativeInputProvider.RECORD_STRIDE
## Built from an int: GDScript float literals of this size are not correctly rounded.
const MAX_EXACT_INT := 9007199254740991


## Scriptable stand-in for the WPNativeInput singleton's method set.
class FakeBridge extends RefCounted:
	var active := true
	var start_result := true
	var overflow_count := 0
	var stride := 14
	var pending := PackedFloat64Array()
	var cancel_codes: Array[int] = []
	var stopped := false

	func start() -> bool:
		return start_result

	func stop() -> void:
		stopped = true

	func is_active() -> bool:
		return active

	func drain() -> PackedFloat64Array:
		var out := pending.duplicate()
		pending = PackedFloat64Array()
		return out

	func get_record_stride() -> int:
		return stride

	func native_now() -> float:
		return 1234.5

	func get_view_metrics() -> Dictionary:
		return {"view_size_points": Vector2(1180, 820), "content_scale": 2.0,
			"safe_area": Rect2(0, 24, 1180, 776), "metrics_generation": 1}

	func get_capabilities() -> Dictionary:
		return {"platform": "ios", "supported": true, "source_identity": true, "pressure": true}

	func cancel_all(code: int) -> void:
		cancel_codes.append(code)

	func get_diagnostics() -> Dictionary:
		return {"active_contacts": 0, "queued_records": 0, "overflow_count": overflow_count,
			"records_emitted": 0, "ignored_contacts": 0, "observer_attached": active}

	func get_platform_info() -> Dictionary:
		return {"machine": "iPad16,3", "system_name": "iPadOS", "system_version": "26.0",
			"model": "iPad", "idiom": "pad"}


var _provider: IOSNativeInputProvider
var _failures_seen: Array[String] = []


func after_each() -> void:
	if _provider != null:
		_provider.free()
		_provider = null


func _rec(source: float, id: float, phase: float, fields := {}) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(STRIDE)
	r[P.Field.SOURCE] = source
	r[P.Field.POINTER_ID] = id
	r[P.Field.PHASE] = phase
	for key: int in fields:
		r[key] = fields[key]
	return r


func _concat(records: Array[PackedFloat64Array]) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for r in records:
		out.append_array(r)
	return out


func _decode_one(r: PackedFloat64Array) -> PointerSample:
	var samples := P.decode_records(r, STRIDE)
	assert_eq(samples.size(), 1, "one record")
	return samples[0] if samples.size() == 1 else PointerSample.new()


func _bound_provider(bridge: FakeBridge) -> IOSNativeInputProvider:
	_provider = IOSNativeInputProvider.new()
	_provider.provider_failed.connect(func(reason: String) -> void: _failures_seen.append(reason))
	_provider._bind_bridge(bridge)
	return _provider


func test_sources_come_only_from_the_native_type_code() -> void:
	assert_eq(_decode_one(_rec(1, 1, 0)).source, PointerSample.Source.PENCIL, "1 = pencil")
	assert_eq(_decode_one(_rec(2, 1, 0)).source, PointerSample.Source.FINGER, "2 = finger")
	assert_eq(_decode_one(_rec(0, 1, 0)).source, PointerSample.Source.UNKNOWN, "0 = unknown")
	for bogus: float in [3.0, -1.0, 1.5, NAN]:
		assert_eq(_decode_one(_rec(bogus, 1, 0)).source, PointerSample.Source.UNKNOWN,
				"code %s must never become PENCIL" % bogus)
	var pencil_no_pressure := _decode_one(_rec(1, 1, 0, {P.Field.PRESSURE_VALID: 0.0}))
	assert_eq(pencil_no_pressure.source, PointerSample.Source.PENCIL, "identity without pressure")


func test_phases_and_identity_fields() -> void:
	var samples := P.decode_records(_concat([_rec(1, 7, 0), _rec(1, 7, 1), _rec(1, 7, 2),
			_rec(2, 8, 3, {P.Field.CANCEL_REASON: 1.0})]), STRIDE)
	assert_eq(samples.size(), 4)
	var phases: Array[int] = []
	for s in samples:
		phases.append(s.phase)
	assert_eq(phases, [PointerSample.Phase.BEGIN, PointerSample.Phase.MOVE,
			PointerSample.Phase.END, PointerSample.Phase.CANCEL] as Array[int], "phase order kept")
	assert_eq(samples[0].pointer_id, 7)
	assert_eq(samples[3].pointer_id, 8)
	assert_eq(samples[2].cancel_reason, "", "END carries no cancel reason")


func test_timestamp_position_and_sequence_are_not_truncated() -> void:
	var s := _decode_one(_rec(1, 3, 1, {P.Field.TIMESTAMP: 86400.123456789, P.Field.X: 100.25,
			P.Field.Y: 0.125, P.Field.SEQUENCE: float(MAX_EXACT_INT)}))
	assert_eq(s.timestamp_s, 86400.123456789, "float64 timestamp preserved")
	assert_eq(s.position_raw, Vector2(100.25, 0.125), "sub-point position preserved")
	assert_eq(s.sample_sequence, MAX_EXACT_INT, "2^53-1 sequence exact")


func test_pressure_valid_invalid_and_clamped() -> void:
	var valid := _decode_one(_rec(1, 1, 1, {P.Field.PRESSURE_VALID: 1.0, P.Field.PRESSURE: 0.5}))
	assert_true(valid.pressure_valid, "pencil pressure valid")
	assert_near(valid.pressure, 0.5, 0.0, "pressure value")
	var invalid := _decode_one(_rec(2, 1, 1, {P.Field.PRESSURE_VALID: 0.0, P.Field.PRESSURE: 0.9}))
	assert_false(invalid.pressure_valid, "invalid flag wins over a stray value")
	assert_eq(invalid.pressure, 0.0, "invalid pressure never leaks a value")
	var high := _decode_one(_rec(1, 1, 1, {P.Field.PRESSURE_VALID: 1.0, P.Field.PRESSURE: 1.7}))
	assert_eq(high.pressure, 1.0, "clamped to 1")
	var nan_pressure := _decode_one(_rec(1, 1, 1,
			{P.Field.PRESSURE_VALID: 1.0, P.Field.PRESSURE: NAN}))
	assert_false(nan_pressure.pressure_valid, "NaN pressure is not valid")


func test_tilt_decoding() -> void:
	var tilted := _decode_one(_rec(1, 1, 1, {P.Field.TILT_VALID: 1.0, P.Field.TILT_X: 0.25,
			P.Field.TILT_Y: -0.5}))
	assert_true(tilted.tilt_valid)
	assert_eq(tilted.tilt, Vector2(0.25, -0.5))
	var flat := _decode_one(_rec(2, 1, 1, {P.Field.TILT_VALID: 0.0, P.Field.TILT_X: 0.25}))
	assert_false(flat.tilt_valid)
	assert_eq(flat.tilt, Vector2.ZERO)


func test_flags_coalesced_predicted_and_force_estimated() -> void:
	assert_true(_decode_one(_rec(1, 1, 1, {P.Field.FLAGS: 1.0})).is_coalesced, "bit0 coalesced")
	assert_false(_decode_one(_rec(1, 1, 1, {P.Field.FLAGS: 0.0})).is_coalesced, "primary sample")
	var predicted := _decode_one(_rec(1, 1, 1, {P.Field.FLAGS: 2.0}))
	assert_true(predicted.is_predicted, "bit1 predicted")
	assert_false(predicted.is_coalesced)
	var estimated := _decode_one(_rec(1, 1, 1, {P.Field.FLAGS: 4.0}))
	assert_false(estimated.is_coalesced or estimated.is_predicted, "bit2 alone sets neither")


func test_cancel_reason_codes_map_to_names() -> void:
	var expected := {1: "native_cancel", 2: "app_deactivated", 3: "queue_overflow", 4: "explicit",
		5: "view_changed", 0: "provider_failed", 9: "provider_failed"}
	for code: int in expected:
		var s := _decode_one(_rec(1, 1, 3, {P.Field.CANCEL_REASON: float(code)}))
		assert_eq(s.phase, PointerSample.Phase.CANCEL)
		assert_eq(s.cancel_reason, expected[code], "reason code %d" % code)
	var move := _decode_one(_rec(1, 1, 1, {P.Field.CANCEL_REASON: 3.0}))
	assert_eq(move.cancel_reason, "", "reason ignored outside CANCEL")


func test_invalid_phase_is_treated_as_cancel() -> void:
	for bogus: float in [4.0, -1.0, 2.5, NAN]:
		var s := _decode_one(_rec(1, 1, bogus))
		assert_eq(s.phase, PointerSample.Phase.CANCEL, "phase %s" % bogus)
		assert_eq(s.cancel_reason, "invalid_phase")


func test_malformed_layout_returns_empty_with_reason() -> void:
	var one := _rec(1, 1, 0)
	var truncated := one.duplicate()
	truncated.resize(STRIDE - 1)
	var extra := one.duplicate()
	extra.append(0.0)
	assert_eq(P.decode_records(truncated, STRIDE).size(), 0, "short buffer")
	assert_eq(P.decode_records(extra, STRIDE).size(), 0, "15 values")
	assert_eq(P.decode_records(one, 0).size(), 0, "zero stride")
	assert_eq(P.decode_records(one, 13).size(), 0, "stride below 14")
	assert_error_contains(P.layout_error(15, STRIDE), "multiple")
	assert_error_contains(P.layout_error(14, 0), "stride")
	assert_empty_string(P.layout_error(0, STRIDE), "empty buffer is valid")
	assert_eq(P.decode_records(PackedFloat64Array(), STRIDE).size(), 0)


func test_wider_stride_ignores_trailing_fields() -> void:
	var wide := _rec(2, 5, 0)
	wide.append_array(PackedFloat64Array([99.0, 98.0]))
	var samples := P.decode_records(_concat([wide, wide]), STRIDE + 2)
	assert_eq(samples.size(), 2)
	assert_eq(samples[1].source, PointerSample.Source.FINGER)
	assert_eq(samples[1].pointer_id, 5)


func test_provider_drains_and_decodes_through_bridge() -> void:
	var bridge := FakeBridge.new()
	var provider := _bound_provider(bridge)
	assert_true(provider.is_available())
	assert_eq(provider.coordinate_space(), InputProvider.SPACE_UIKIT_POINTS)
	assert_eq(provider.provider_name(), "ios_native_uikit")
	assert_false(provider.is_development())
	assert_eq(provider.now_seconds(), 1234.5, "native clock")
	bridge.pending = _concat([_rec(1, 1, 0), _rec(1, 1, 2)])
	var samples := provider.drain_samples()
	assert_eq(samples.size(), 2)
	assert_eq(provider.drain_samples().size(), 0, "records are drained once")
	assert_true(_failures_seen.is_empty(), "no failure on healthy drain")
	assert_eq(provider.view_metrics().get("metrics_generation"), 1)
	assert_eq(provider.capabilities().get("platform"), "ios")


func test_cancel_all_forwards_explicit_code() -> void:
	var bridge := FakeBridge.new()
	var provider := _bound_provider(bridge)
	provider.cancel_all("modal opened")
	assert_eq(bridge.cancel_codes, [4] as Array[int])
	assert_eq(provider.diagnostics().get("last_cancel_request"), "modal opened")


func test_overflow_increase_emits_provider_failed_once() -> void:
	var bridge := FakeBridge.new()
	bridge.overflow_count = 2
	var provider := _bound_provider(bridge)
	provider.drain_samples()
	assert_true(_failures_seen.is_empty(), "overflows before start are baseline")
	bridge.overflow_count = 3
	bridge.pending = _rec(1, 1, 3, {P.Field.CANCEL_REASON: 3.0})
	var samples := provider.drain_samples()
	assert_eq(_failures_seen, ["queue overflow"] as Array[String])
	assert_eq(samples.size(), 1, "overflow CANCEL still delivered")
	assert_eq(samples[0].cancel_reason, "queue_overflow")
	provider.drain_samples()
	assert_eq(_failures_seen.size(), 1, "no repeat without a new overflow")


func test_bridge_going_inactive_emits_provider_failed_once() -> void:
	var bridge := FakeBridge.new()
	var provider := _bound_provider(bridge)
	bridge.active = false
	bridge.pending = _rec(2, 4, 3, {P.Field.CANCEL_REASON: 5.0})
	var samples := provider.drain_samples()
	assert_eq(_failures_seen, ["bridge inactive"] as Array[String])
	assert_eq(samples.size(), 1, "pending CANCEL delivered with the failure")
	assert_false(provider.is_available())
	provider.drain_samples()
	assert_eq(_failures_seen.size(), 1, "reported once")


func test_malformed_bridge_output_fails_provider_with_diagnostic() -> void:
	var bridge := FakeBridge.new()
	var provider := _bound_provider(bridge)
	var bad := _rec(1, 1, 0)
	bad.resize(STRIDE + 3)
	bridge.pending = bad
	assert_eq(provider.drain_samples().size(), 0, "nothing decoded from a malformed buffer")
	assert_eq(_failures_seen.size(), 1)
	assert_error_contains(_failures_seen[0], "malformed")
	var diag := provider.diagnostics()
	assert_eq(diag.get("decode_errors"), 1)
	assert_error_contains(str(diag.get("last_decode_error")), "multiple")
	assert_true(bridge.stopped, "a broken bridge is stopped for good")
	assert_false(provider.is_available())
	bridge.pending = _rec(1, 2, 0)
	assert_eq(provider.drain_samples().size(), 0, "no further drains")
	assert_eq(bridge.pending.size(), STRIDE, "bridge not drained again")
	provider.cancel_all("explicit")
	assert_true(bridge.cancel_codes.is_empty(), "no cancel forwarded to a stopped bridge")
	assert_eq(_failures_seen.size(), 1, "reported once")


## Review regression: the dropped buffer held the END of contact 1. The bridge has already forgotten
## it, so only the provider can close it; otherwise the router keeps a suppressed contact forever.
func test_malformed_buffer_closes_every_contact_the_provider_opened() -> void:
	var bridge := FakeBridge.new()
	var provider := _bound_provider(bridge)
	bridge.pending = _concat([_rec(1, 1, 0, {P.Field.SEQUENCE: 1.0}),
			_rec(2, 2, 0, {P.Field.SEQUENCE: 2.0}),
			_rec(1, 1, 1, {P.Field.X: 5.5, P.Field.Y: 6.25, P.Field.SEQUENCE: 3.0}),
			_rec(2, 2, 2, {P.Field.SEQUENCE: 4.0}),
			_rec(2, 9, 1, {P.Field.SEQUENCE: 5.0})])  # MOVE without BEGIN never opens a contact
	assert_eq(provider.drain_samples().size(), 5)
	var bad := _rec(1, 1, 2, {P.Field.SEQUENCE: 6.0})
	bad.append(0.0)
	bridge.pending = bad
	var closed := provider.drain_samples()
	assert_eq(_failures_seen.size(), 1)
	if not assert_eq(closed.size(), 1, "exactly the one open contact is closed"):
		return
	var c := closed[0]
	assert_eq(c.pointer_id, 1)
	assert_eq(c.phase, PointerSample.Phase.CANCEL, "never an END")
	assert_eq(c.cancel_reason, "provider_failed")
	assert_eq(c.source, PointerSample.Source.PENCIL, "identity from BEGIN kept")
	assert_eq(c.position_raw, Vector2(5.5, 6.25), "last known position, not a garbage one")
	assert_eq(c.timestamp_s, 1234.5, "native clock")
	assert_eq(c.sample_sequence, 5, "does not run backwards")


func test_failed_start_is_unavailable_and_never_drains() -> void:
	var bridge := FakeBridge.new()
	bridge.start_result = false
	var provider := _bound_provider(bridge)
	bridge.pending = _rec(1, 1, 0)
	assert_false(provider.is_available())
	assert_eq(provider.drain_samples().size(), 0)
	provider.cancel_all("x")
	assert_true(bridge.cancel_codes.is_empty(), "no cancel forwarded to an unstarted bridge")
	assert_true(_failures_seen.is_empty())


func test_diagnostics_merge_bridge_and_platform_info() -> void:
	var provider := _bound_provider(FakeBridge.new())
	var diag := provider.diagnostics()
	for key: String in ["provider", "started", "active_contacts", "queued_records", "overflow_count",
			"records_emitted", "ignored_contacts", "observer_attached", "machine", "system_name",
			"system_version", "model", "idiom"]:
		assert_true(diag.has(key), "diagnostics has %s" % key)
	assert_eq(diag.get("idiom"), "pad")
