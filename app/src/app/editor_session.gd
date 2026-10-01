class_name EditorSession
extends Node3D
## Composition root and world lifecycle of the editor (spec §4, §16, §17). Owns input, camera,
## terrain, presenter, tools, storage and history. Frame order: InputSystem (-1000) routes
## input, then this node (1000) advances tools, freezes the camera and flushes terrain.
## Expected failures are returned as strings and posted as messages; nothing here calls push_error.

signal status_changed()
signal message_posted(text: String, is_error: bool)
signal world_replaced()

const BUSY_MESSAGE := "Finish or cancel the current operation first."
const BENCH_MESSAGE := "Render bench is running. Abort it first."
const BENCH_RUNNING := "Render bench is already running."
const SIMULATOR_NOTE := "SIMULATOR preview; no hardware gate. P toggles probe/UI and fingers."
const SCRIPTED_PROVIDER := "res://src/app/scripted_input_provider.gd"
const EDITOR_UI := "res://src/ui/editor_ui.gd"
const SELFTEST := "res://src/app/editor_selftest.gd"
const RENDER_BENCH := "res://src/diagnostics/render_bench.gd"
const STATUS_INTERVAL_MSEC := 250

var storage_root := "user://worlds"
var start_fixture := "gentle_hills"
var provider_override: InputProvider = null
var platform_override := ""
var force_simulator_preview := false
var build_ui := true

var document: WorldDocument
var catalog: AssetCatalog
var defaults: Dictionary = {}
var render_config: RenderConfig
var render_profiles: RenderProfileController
var input := InputSystem.new()
var rig: OrbitCameraRig
var terrain: TerrainView
var presenter := ObjectPresenter.new()
var layers := WorldLayers.new()
var tools := ToolController.new()
var history: CommandHistory
var storage := WorldStorage.new()
var frames := FrameStats.new(600)
var ui: Node = null
var sun: DirectionalLight3D
var ready_for_input := false
var boot_error := ""
var last_message := ""
var last_message_is_error := false

var _selftest := false
var _bench: Node = null  # the claimed RenderBench runner
var _bench_args: Dictionary = {}
var _fault_armed := false
var _last_evicted := 0
var _last_frame_usec := 0
var _last_status_msec := 0
var _tool_ctx: ToolContext
var _op_max_gap_ms := 0.0
var _last_cancel_reason := ""
var _render: SessionRender


func _ready() -> void:
	process_priority = 1000
	var args := OS.get_cmdline_user_args()
	if args.has("--input-lab"):
		get_tree().change_scene_to_file.call_deferred("res://scenes/input_lab.tscn")
		return
	_apply_user_args(args)
	var error := _load_config()
	if error == "":
		error = _open_world()
	if error == "":
		error = _build_scene()
	if error != "":
		_boot_failed(error)
		return
	_build_tools_and_input()
	storage.save_state_changed.connect(func(_state: Dictionary) -> void: status_changed.emit())
	ui = _attach_module(EDITOR_UI, "") if build_ui else null
	if ui != null:
		ui.call("setup", self)
	ready_for_input = true
	print("Editor ready: ", input.provider_label())
	var runner := _attach_module(SELFTEST, "Self-test module is missing.") if _selftest else null
	if runner != null:
		runner.call("start", self)
	if _bench_args.has("error"):
		post_message(str(_bench_args.error), true)
	elif _bench_args.has("enabled"):
		start_render_bench(_bench_args.counts, _bench_args.frames, _bench_args)


## Optional modules load by path so the session also boots in tests and tools without them.
func _attach_module(path: String, missing_message: String) -> Node:
	if not ResourceLoader.exists(path):
		if missing_message != "":
			post_message(missing_message, true)
		return null
	var node := load(path).new() as Node
	add_child(node)
	return node


func start_render_bench(counts := PackedInt32Array(), frames := 0, options := {}) -> String:
	return SessionWorldOps.start_bench(self, RENDER_BENCH, counts, frames, options)


## Session-level exclusivity of the render bench: one claimed runner at a time.
func claim_bench(runner: Node) -> String:
	if bench_active():
		return BENCH_RUNNING
	_bench = runner
	return ""


func release_bench(runner: Node) -> void:
	_bench = null if _bench == runner else _bench
	status_changed.emit()


func bench_active() -> bool:
	return is_instance_valid(_bench) and bool(_bench.call("is_running"))


func abort_render_bench(reason: String) -> void:
	if bench_active():
		_bench.call("abort", reason)


func _bench_blocks() -> bool:  # true, with BENCH_MESSAGE posted, while a bench owns the session
	if bench_active():
		post_message(BENCH_MESSAGE, true)
	return bench_active()


func _apply_user_args(args: PackedStringArray) -> void:
	for arg in args:
		if arg.begins_with("--storage-root="):
			storage_root = arg.trim_prefix("--storage-root=")
		elif arg.begins_with("--start-fixture="):
			start_fixture = arg.trim_prefix("--start-fixture=")
	_bench_args = SessionWorldOps.parse_bench_args(args)
	_selftest = args.has("--editor-selftest")
	if _selftest and provider_override == null and ResourceLoader.exists(SCRIPTED_PROVIDER):
		provider_override = load(SCRIPTED_PROVIDER).new() as InputProvider


func _boot_failed(error: String) -> void:
	boot_error = error
	print("Editor startup failed: ", error)
	post_message("Startup failed: " + error, true)


func _load_config() -> String:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://config/poc_defaults.json"))
	if typeof(parsed) != TYPE_DICTIONARY:
		return "Cannot read config/poc_defaults.json."
	defaults = parsed
	_render = SessionRender.new(self)
	render_config = _render.config
	render_profiles = _render.profiles
	var loaded := AssetCatalog.load_from()
	if loaded[1] != "":
		return str(loaded[1])
	catalog = loaded[0]
	add_child(storage)
	var error := storage.configure(storage_root, int(defaults.storage.keep_generations), catalog)
	history = CommandHistory.new(int(defaults.history.max_actions), int(defaults.history.max_bytes))
	return error


func _open_world() -> String:
	var opened := SessionWorldOps.open_start_world(storage, catalog, start_fixture)
	if opened.error != "":
		return opened.error
	document = opened.doc
	if opened.checkpoint:
		_request_checkpoint()
	else:
		storage.warm_snapshot_cache(document)
	post_message(opened.message, opened.is_error)
	return ""


func _build_scene() -> String:
	rig = OrbitCameraRig.new(defaults.camera)
	rig.height_sampler = document.sample_height
	add_child(rig)
	reset_camera()
	var simulator := force_simulator_preview or SimulatorInputProvider.simulator_available()
	if simulator:
		terrain = SimulatorTerrainPreview.new()
		if provider_override == null:
			provider_override = SimulatorInputProvider.new()
		post_message(SIMULATOR_NOTE)
	else:
		var adapter := TerrainAdapter.new()
		adapter.set_camera(rig.get_camera())
		adapter.set_process(false)
		terrain = adapter
	add_child(terrain)
	var error := terrain.initialize(document)
	if error != "":
		return error
	presenter.setup(catalog, _render.registry(), _render.cache)
	presenter.set_camera(rig.get_camera())
	presenter.set_debug_limit(int(render_config.section("ui").max_debug_labels))
	add_child(presenter)
	presenter.rebuild(document)
	layers.setup(catalog)
	add_child(layers)
	layers.rebuild(document)
	sun = SceneLighting.build(self)
	RenderCounters.enable(get_viewport())
	render_profiles.apply_startup()
	if render_config.error != "":
		post_message(render_config.error, true)
	return ""


func _build_tools_and_input() -> void:
	_tool_ctx = SessionWorldOps.make_tool_context(self)
	tools.operation_started.connect(func(_tool: String) -> void: _op_max_gap_ms = 0.0)
	tools.operation_cancelled.connect(func(reason: String) -> void: _last_cancel_reason = reason)
	add_child(tools)
	tools.setup(_tool_ctx)
	_render.bind_tools(tools)
	layers.bind_tools(tools)
	input.provider_override = provider_override
	input.platform_override = platform_override
	add_child(input)
	input.camera_action.connect(rig.handle_camera_action)
	input.tool_action.connect(_on_tool_action)
	input.diagnostic.connect(func(action: Dictionary) -> void: post_message(str(action.message)))
	input.ui_cancelled.connect(_on_ui_cancelled)
	input.trace.start()
	tools.editing_enabled = input.editing_enabled()


# --- Frame loop and input ----------------------------------------------------------------

func _process(_delta: float) -> void:
	if not ready_for_input:
		return
	var now_usec := Time.get_ticks_usec()
	if _last_frame_usec > 0:
		var gap_ms := float(now_usec - _last_frame_usec) / 1000.0
		frames.add(gap_ms)
		if tools.has_active_operation():
			_op_max_gap_ms = maxf(_op_max_gap_ms, gap_ms)
		var stall_s := float(defaults.brush.stall_cancel_s)
		if gap_ms / 1000.0 > stall_s and tools.has_active_operation() and not tools.has_object_edit():
			input.cancel_all("tool_error")
			post_message("Stroke cancelled: frame stall over %d ms." % roundi(stall_s * 1000.0), true)
	_last_frame_usec = now_usec
	tools.advance(input.active_provider().now_seconds())
	rig.frozen = tools.has_active_operation()
	_render.service_frame()
	terrain.flush()
	if Time.get_ticks_msec() - _last_status_msec >= STATUS_INTERVAL_MSEC:
		_last_status_msec = Time.get_ticks_msec()
		status_changed.emit()


func _on_tool_action(action: Dictionary) -> void:
	if bench_active():
		return
	tools.editing_enabled = input.editing_enabled()
	tools.handle_tool_action(action)


func _on_ui_cancelled(reason: String) -> void:
	if tools.has_object_edit():
		tools.cancel_active("ui_cancel")
	if ui != null and ui.has_method("on_ui_cancelled"):
		ui.call("on_ui_cancelled", reason)


func _input(event: InputEvent) -> void:
	if ready_for_input and event is InputEventKey and event.pressed and not event.echo \
			and not (input.is_development_input() and SessionWorldOps.dev_key(tools, event.keycode)):
		SessionWorldOps.simulator_key(input, get_viewport(), event.keycode)


func _notification(what: int) -> void:
	if not ready_for_input:
		return
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST]:
		abort_render_bench("app_deactivated")
		input.cancel_all("app_deactivated")
		tools.cancel_active("app_deactivated")
		var error := SessionWorldOps.ensure_saved(storage, document)
		if error != "":
			post_message("Saving on deactivation failed: " + error, true)


# --- Editing -----------------------------------------------------------------------------

func commit(change: WorldChange) -> void:
	document.bump_revision()
	history.push_already_applied(change)
	if history.evicted_count > _last_evicted:
		_last_evicted = history.evicted_count
		post_message("Undo limit reached: oldest action dropped. The world is unchanged.")
	_request_checkpoint()
	status_changed.emit()


func undo() -> String:
	return _step(false)


func redo() -> String:
	return _step(true)


func _step(forward: bool) -> String:
	if _bench_blocks():
		return BENCH_MESSAGE
	if tools.has_active_operation():
		post_message(BUSY_MESSAGE, true)
		return BUSY_MESSAGE
	var label := history.peek_redo_label() if forward else history.peek_undo_label()
	var change := history.redo(document) if forward else history.undo(document)
	if change == null:
		var nothing := "Nothing to redo" if forward else "Nothing to undo"
		post_message(nothing)
		return nothing
	SessionWorldOps.present_change(self, change)
	_request_checkpoint()
	post_message(("Redid " if forward else "Undid ") + label)
	return ""


func cancel_active() -> void:
	input.cancel_all("explicit")
	tools.cancel_active("explicit")


func _request_checkpoint() -> String:
	var error := storage.request_checkpoint(document)
	if _fault_armed:
		_fault_armed = false
		storage.fault_injection = {}  # the queued job already copied it
	if error != "":
		post_message(error, true)
	return error


# --- World lifecycle ---------------------------------------------------------------------

func save_now() -> String:
	if _bench_blocks():
		return BENCH_MESSAGE
	if tools.has_active_operation():
		post_message(BUSY_MESSAGE, true)
		return BUSY_MESSAGE
	var error := _request_checkpoint()
	if error == "":
		post_message("Saving revision %d" % document.document_revision)
	return error


func export_world() -> Dictionary:
	if _bench_blocks():
		return {"path": "", "error": BENCH_MESSAGE}
	if tools.has_active_operation():
		post_message(BUSY_MESSAGE, true)
		return {"path": "", "error": BUSY_MESSAGE}
	var revision := document.document_revision
	var result := SessionWorldOps.export_verified(storage, document, catalog)
	post_message(str(result.error) if result.error != "" else "Exported revision %d (verified): %s" % [
			revision, str(result.path).get_file()], result.error != "")
	return result


func open_fixture(fixture: String) -> String:
	return SessionWorldOps.open_replacing(self, SessionWorldOps.load_fixture.bind(fixture, catalog),
			"Opened %s as a new world" % fixture.capitalize())


## kind: "flat" or "hills" (SessionWorldOps.NEW_WORLD_KINDS).
func open_new_world(kind: String) -> String:
	return SessionWorldOps.open_replacing(self, SessionWorldOps.new_layout_world.bind(WorldLayout.km1(), kind, catalog),
			"Opened new 1 km world (%s)" % kind)


func _replace_document(doc: WorldDocument) -> void:
	document = doc
	tools.set_document(doc)
	var error := terrain.replace_document(doc)
	if error != "":
		post_message(error, true)
	presenter.rebuild(doc)
	layers.rebuild(doc)
	rig.height_sampler = doc.sample_height
	reset_camera()
	history.clear()
	_last_evicted = history.evicted_count
	_request_checkpoint()
	world_replaced.emit()
	status_changed.emit()


func reset_camera() -> void:
	SessionWorldOps.reset_camera(rig, document)


func focus_selection() -> String:
	var id := tools.selected_id()
	if id == "":
		post_message("Select an object to focus.", true)
		return "Select an object to focus."
	rig.focus_bounds(presenter.world_bounds(id))
	return ""


## Profile and vegetation calls delegate to SessionRender (spec §4.1, §15.4).
func request_profile(name: String) -> Dictionary:
	return _render.request_profile(name)


func set_vegetation_hidden(on: bool) -> void:
	_render.set_vegetation_hidden(on)


func vegetation_hidden() -> bool:
	return _render.vegetation_hidden


func invalidate_slow_status() -> void:
	_render.invalidate_slow_status()


func render_registry() -> RenderAssetRegistry: return _render.registry()


func render_cache() -> RenderAssetCache: return _render.cache


# --- Diagnostics -------------------------------------------------------------------------

func save_trace() -> String:
	var error := SessionWorldOps.save_trace_files(self)
	post_message("Trace and evidence saved in user://traces/." if error == "" else error, error != "")
	return error


func authored_hash() -> String:
	return CanonicalEncoder.authored_hash(document)


## Spec WP06 fault injection: the next checkpoint fails while writing objects.json.
func inject_save_failure() -> void:
	_fault_armed = true
	storage.fault_injection = {"fail_on_file": "objects.json"}
	post_message("Fault injection: the next save will fail.")


## reason: queue_overflow | mapping_changed | app_deactivated
func simulate_cancel(reason: String) -> void:
	post_message("Fault injection: simulated cancel '%s'." % reason)
	input.cancel_all(reason)


func post_message(text: String, is_error := false) -> void:
	last_message = text
	last_message_is_error = is_error
	message_posted.emit(text, is_error)
	status_changed.emit()


## Reads back the GPU texture layers and reports whether they match the document.
func verify_gpu_terrain() -> String:
	var report := SessionWorldOps.gpu_report(terrain.verify_gpu())
	post_message(report.text, report.is_error)
	return report.text


## Live fields are cheap and computed on every call; frame percentiles, render counters and stats that sort or
## query the RenderingServer are cached for 1000 / diagnostics_refresh_hz ms (spec §15.3).
func status() -> Dictionary:
	var revision := document.document_revision
	var slow := _render.slow_status()
	return {"stroke_state": tools.stroke_state(), "revision": revision, "bench_active": bench_active(),
		"save_text": storage.status_text(revision), "save_state": storage.get_save_state(),
		"object_count": document.objects.size(), "selected_id": tools.selected_id(),
		"render_scale": get_viewport().scaling_3d_scale,
		"world_id": document.world_id, "operation_id": tools.active_operation_id(),
		"last_hit": SessionWorldOps.hit_text(tools.last_hit()), "last_stroke": SessionWorldOps.with_gap(_tool_ctx.last_stroke, _op_max_gap_ms),
		"last_cancel": _last_cancel_reason}.merged(slow).merged(_render.profile_status(float(slow.frame_p50_ms))).merged(
			SessionWorldOps.tool_status(tools)).merged(SessionWorldOps.history_status(history)).merged(
			SessionWorldOps.input_status(input))
