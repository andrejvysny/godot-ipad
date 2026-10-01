extends TestCase
## RenderPlatformTelemetry: explicit unavailable values, injected events, and (macOS host only) the native class.
## Desktop evidence only; iPad thermal/memory behaviour is NOT RUN here.


func test_unavailable_path() -> void:
	var t := RenderPlatformTelemetry.new(true)
	assert_false(t.is_native_available(), "forced unavailable")
	var s := t.sample()
	assert_eq(s["thermal"], "unavailable")
	assert_eq(s["thermal_level"], -1)
	assert_eq(s["footprint_mib"], null, "footprint is null, not 0")
	assert_eq(s["memory_warnings"], 0)
	assert_eq(s["source"], "unavailable")


func test_injected_thermal_and_warnings() -> void:
	var t := RenderPlatformTelemetry.new(true)
	t.inject_thermal(3)
	t.inject_memory_warning(2)
	t.inject_memory_warning()
	var s := t.sample()
	assert_eq(s["thermal"], "critical")
	assert_eq(s["thermal_level"], 3)
	assert_eq(s["memory_warnings"], 3)
	assert_eq(s["source"], "injected")
	assert_eq(s["footprint_mib"], null)
	assert_eq(t.sample()["memory_warnings"], 0, "warnings are consumed by a sample")
	assert_eq(t.sample()["thermal"], "critical", "injected thermal persists")


func test_inject_levels_and_clear() -> void:
	var t := RenderPlatformTelemetry.new(true)
	var names := ["nominal", "fair", "serious", "critical"]
	for i in 4:
		t.inject_thermal(i)
		assert_eq(t.sample()["thermal"], names[i])
	t.inject_thermal(9)
	assert_eq(t.sample()["thermal_level"], 3, "clamped")
	t.inject_memory_warning(1)
	t.clear_injection()
	var s := t.sample()
	assert_eq(s["source"], "unavailable")
	assert_eq(s["thermal_level"], -1)
	assert_eq(s["memory_warnings"], 0)


func test_native_on_macos_host() -> void:
	if OS.get_name() != "macOS":
		print("       (skipped: native telemetry host checks only run on macOS)")
		return
	var t := RenderPlatformTelemetry.new()
	assert_true(t.is_native_available(), "native class available")
	var s := t.sample()
	assert_eq(s["source"], "macos_native")
	assert_true(int(s["thermal_level"]) >= 0 and int(s["thermal_level"]) <= 3, "thermal in [0,3]")
	assert_true(s["footprint_mib"] != null and float(s["footprint_mib"]) > 0.0, "footprint > 0 MiB")
	assert_eq(s["memory_warnings"], 0)
	t.inject_thermal(2)
	assert_eq(t.sample()["source"], "injected")
	t.clear_injection()
	assert_eq(t.sample()["source"], "macos_native")


func test_sample_cost() -> void:
	var t := RenderPlatformTelemetry.new()
	var n := 2000
	var t0 := Time.get_ticks_usec()
	for i in n:
		t.sample()
	var per_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)
	print("       sample() cost: %.4f ms (native=%s)" % [per_ms, str(t.is_native_available())])
	assert_true(per_ms < 0.1, "sample() under 0.1 ms")
