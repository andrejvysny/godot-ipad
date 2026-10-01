extends TestCase
## The WPNativeInput GDExtension on the macOS host: it must load, register its singleton, and be an
## inert no-op. Also IOSNativeInputProvider end to end through the real InputSystem with a fake
## bridge. Desktop evidence only; iPad/Pencil behaviour is NOT RUN here.

const SINGLETON := "WPNativeInput"
const GDEXTENSION_PATH := "res://addons/wp_native_input/wp_native_input.gdextension"
const DecodeTest := preload("res://tests/unit/test_native_record_decode.gd")
const P := preload("res://src/input/ios_native_input_provider.gd")


func _bridge() -> Object:
	return Engine.get_singleton(SINGLETON) if Engine.has_singleton(SINGLETON) else null


func _is_macos_host() -> bool:
	if OS.get_name() == "macOS":
		return true
	print("       (skipped: WPNativeInput host checks only run on macOS)")
	return false


func test_extension_loads_and_registers_singleton() -> void:
	if not _is_macos_host():
		return
	assert_true(GDExtensionManager.is_extension_loaded(GDEXTENSION_PATH), "extension loaded")
	assert_true(ClassDB.class_exists(SINGLETON), "class registered")
	assert_false(ClassDB.can_instantiate(SINGLETON), "abstract: no second observer instance")
	assert_true(Engine.has_singleton(SINGLETON), "engine singleton registered")


func test_macos_bridge_is_inert() -> void:
	if not _is_macos_host():
		return
	var bridge := _bridge()
	if not assert_true(bridge != null, "singleton present"):
		return
	assert_eq(bridge.call("get_record_stride"), 15, "record stride")
	assert_eq(bridge.call("start"), false, "start() refuses on macOS")
	assert_eq(bridge.call("is_active"), false)
	var caps: Dictionary = bridge.call("get_capabilities")
	assert_eq(caps.get("platform"), "macos")
	assert_eq(caps.get("supported"), false)
	for key: String in ["source_identity", "pressure", "tilt", "coalesced", "native_cancel",
			"native_timestamps"]:
		assert_eq(caps.get(key), false, "capability %s" % key)
	bridge.call("cancel_all", 4)
	var drained: PackedFloat64Array = bridge.call("drain")
	assert_eq(drained.size(), 0, "drain() empty")
	bridge.call("stop")


func test_macos_bridge_reports_shapes() -> void:
	if not _is_macos_host():
		return
	var bridge := _bridge()
	if not assert_true(bridge != null, "singleton present"):
		return
	var t0: float = bridge.call("native_now")
	var t1: float = bridge.call("native_now")
	assert_true(t0 > 0.0 and t1 >= t0, "native clock is monotonic seconds")
	var metrics: Dictionary = bridge.call("get_view_metrics")
	assert_eq(metrics.get("view_size_points"), Vector2.ZERO)
	assert_eq(typeof(metrics.get("content_scale")), TYPE_FLOAT)
	assert_eq(metrics.get("safe_area"), Rect2())
	assert_eq(metrics.get("metrics_generation"), 0)
	var diag: Dictionary = bridge.call("get_diagnostics")
	for key: String in ["active_contacts", "queued_records", "overflow_count", "records_emitted",
			"ignored_contacts"]:
		assert_eq(diag.get(key), 0, "diagnostic %s" % key)
	assert_eq(diag.get("observer_attached"), false)
	assert_eq(diag.get("attach_status"), "unsupported_platform")
	var info: Dictionary = bridge.call("get_platform_info")
	assert_eq(info.get("system_name"), "macOS")
	assert_ne(str(info.get("machine")), "", "uname machine")
	assert_ne(str(info.get("system_version")), "", "OS version")


func test_provider_ready_is_harmless_on_macos() -> void:
	if not _is_macos_host():
		return
	var provider := IOSNativeInputProvider.new()
	tree.root.add_child(provider)
	await tree.process_frame
	assert_false(provider.is_available(), "never available off iOS")
	assert_eq(provider.drain_samples().size(), 0)
	provider.cancel_all("test")
	assert_eq(provider.coordinate_space(), InputProvider.SPACE_UIKIT_POINTS)
	assert_eq(provider.diagnostics().get("started"), false)
	provider.free()


func _pencil_record(id: int, phase: int, pos: Vector2) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(P.RECORD_STRIDE)
	r[P.Field.SOURCE] = 1.0
	r[P.Field.POINTER_ID] = float(id)
	r[P.Field.PHASE] = float(phase)
	r[P.Field.X] = pos.x
	r[P.Field.Y] = pos.y
	return r


## Review regression: a malformed buffer that swallowed the END of an active stroke must leave the
## router idle, not holding a suppressed contact that no record will ever release.
func test_malformed_buffer_leaves_input_system_idle() -> void:
	var bridge := DecodeTest.FakeBridge.new()
	var provider := IOSNativeInputProvider.new()
	provider._bind_bridge(bridge)
	var sys := InputSystem.new()
	sys.provider_override = provider
	var tools: Array[String] = []
	sys.tool_action.connect(func(a: Dictionary) -> void:
		tools.append(("%s %s" % [a.type, a.get("reason", "")]).strip_edges()))
	tree.root.add_child(sys)
	bridge.pending = _pencil_record(1, PointerSample.Phase.BEGIN, Vector2(300, 200)) \
			+ _pencil_record(1, PointerSample.Phase.MOVE, Vector2(305, 200))
	sys.run_frame()
	var bad := _pencil_record(1, PointerSample.Phase.END, Vector2(310, 200))
	bad.append(0.0)
	bridge.pending = bad
	for i in 4:
		sys.run_frame()
	assert_eq(tools, ["tool_begin", "tool_move", "tool_cancel provider_failed"] as Array[String],
			"the stroke rolls back once")
	assert_eq(sys.router.state_name(), "IDLE", "no contact left waiting for a release")
	assert_true(sys.router.contacts().is_empty())
	assert_true(bridge.stopped)
	assert_false(provider.is_available())
	tree.root.remove_child(sys)
	sys.free()
