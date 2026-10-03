class_name InputLab
extends Node3D
## Composition stays small until signed physical-device input and rendering pass G1.

const ACTIVE_WORLD := "user://input_lab/active_world.txt"
var document: WorldDocument
var catalog: AssetCatalog
var input := InputSystem.new()
var adapter := TerrainAdapter.new()
var storage := WorldStorage.new()
var rig := OrbitCameraRig.new()
var probe := LabProbe.new()
var history := CommandHistory.new()
var calibration := LabCalibration.new()
var runtime := LabRuntimeDiagnostics.new()
var _panel := VBoxContainer.new()
var _status := Label.new()
var _source := Label.new()
var _message := "Pressure disabled. Pencil paints; fingers navigate and use controls."
var _object: Node3D
var _last_sample: Dictionary = {}
var _last_begin: Dictionary = {}
var _coalesced := 0
var _predicted := 0
var _diagnostics := Label.new()
var _last_operation := ""
var _radius := HSlider.new()
var _radius_before := 4.0
var _slider_active := false
var _frame_gap := 0.0
var _ready_for_input := false
var _simulator_preview: SimulatorTerrainPreview
var _last_ui_action: Dictionary = {}
var _last_gui_event: Dictionary = {}
var _last_button := ""


func _ready() -> void:
	process_priority = 1000
	_write_startup("Initializing Input Lab")
	_build_ui()
	var loaded := AssetCatalog.load_from()
	if loaded[1] != "":
		_boot_failed(loaded[1])
		return
	catalog = loaded[0]
	add_child(storage)
	var error := storage.configure("user://input_lab/worlds", 3, catalog)
	if error != "":
		_boot_failed(error)
		return
	if not _load_document():
		return
	probe.document = document
	rig.height_sampler = document.sample_height
	add_child(rig)
	error = _initialize_terrain()
	if error != "":
		_boot_failed(error)
		return
	_build_light()
	_show_object()
	_connect_input()
	_ready_for_input = true
	_set_controls_enabled(true)
	runtime.capture_enabled = OS.get_cmdline_user_args().has("--lab-diagnostics")
	runtime.capture_frame(get_viewport())
	_write_startup("Ready: " + input.provider_label())
	print("Input Lab ready: ", input.provider_label())


func _connect_input() -> void:
	input.camera_action.connect(rig.handle_camera_action)
	input.tool_action.connect(_tool_action)
	input.ui_cancelled.connect(_cancel_slider)
	input.sample_received.connect(_observe_sample)
	input.diagnostic.connect(_diagnostic)
	input.ui_action.connect(func(action: Dictionary) -> void: _last_ui_action = InputTrace.normalize_action(action))
	add_child(input)
	input.trace.start()


func _initialize_terrain() -> String:
	if SimulatorInputProvider.simulator_available():
		adapter.free()
		adapter = null
		_simulator_preview = SimulatorTerrainPreview.new()
		add_child(_simulator_preview)
		input.provider_override = SimulatorInputProvider.new()
		_message = "SIMULATOR preview; no hardware gate. P toggles probe/UI and fingers."
		return _simulator_preview.initialize(document)
	adapter.set_camera(rig.get_camera())
	adapter.set_process(false)
	add_child(adapter)
	return adapter.initialize(document)


func _boot_failed(error: String) -> void:
	_set_controls_enabled(false)
	_write_startup("Startup failed: " + error)
	_status.text = "Startup failed: " + error
	push_error(error)


func _write_startup(message: String) -> void:
	var file := FileAccess.open("user://input_lab_startup.txt", FileAccess.WRITE)
	if file != null:
		file.store_string(message)


func _load_document() -> bool:
	if FileAccess.file_exists(ACTIVE_WORLD):
		var id := FileAccess.get_file_as_string(ACTIVE_WORLD).strip_edges()
		var recovered := storage.recover_latest_valid(id, catalog)
		if recovered.doc != null:
			document = recovered.doc
			_message = "Recovered revision %d; skipped %d invalid generations." % [
				document.document_revision, recovered.skipped.size()]
			return true
		_message = "Recovery failed: %s. Fresh probe loaded." % recovered.error
	var loaded := WorldCodec.read_generation("res://fixtures/gentle_hills", catalog)
	if loaded[1] != "":
		_boot_failed(loaded[1])
		return false
	document = loaded[0]
	document.world_id = ObjectRecord.new_uuid_v4()
	document.document_revision = 0
	var record := ObjectRecord.new()
	var asset := catalog.get_asset("nature.rock.boulder_a")
	record.object_id = ObjectRecord.new_uuid_v4()
	record.binding_id = document.assets.bundled_binding_for(asset.asset_id)
	record.set_position(0, document.sample_height(0, 0), 0)
	document.objects.clear()
	document.put_object(record)
	return true


func _build_light() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.shadow_enabled = true
	add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.18, 0.27, 0.34)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color.WHITE
	settings.ambient_light_energy = 0.5
	environment.environment = settings
	add_child(environment)


func _show_object() -> void:
	if is_instance_valid(_object):
		_object.queue_free()
	var record := document.get_object(document.sorted_object_ids()[0])
	var asset := document.assets.definition(record.binding_id)
	_object = catalog.instantiate_preview(asset.asset_id)
	_object.transform = record.node_transform(asset.anchor_local)
	add_child(_object)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var margin := MarginContainer.new()
	margin.position = Vector2(16, 16)
	margin.custom_minimum_size = Vector2(320, 0)
	layer.add_child(margin)
	var background := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.1, 0.95)
	background.add_theme_stylebox_override("panel", style)
	margin.add_child(background)
	background.add_child(_panel)
	input.ui_hits.register(_panel)
	_panel.add_child(_source)
	_source.text = "INPUT LAB — G1 NOT RUN"
	_source.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_source.custom_minimum_size.x = 320
	_panel.add_child(_status)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 320
	_button("Checkpoint probe", _checkpoint)
	_button("Reload durable probe", _reload)
	_button("Undo probe", _undo)
	_button("Redo probe", _redo)
	_button("Save input trace + evidence", _save_trace)
	_button("Nine-point calibration", _start_calibration)
	_button("Toggle 100% / 50% 3D scale", _toggle_scale)
	_button("Cancel active contacts", func() -> void: input.cancel_all("explicit"))
	_radius.min_value = 1.0
	_radius.max_value = 16.0
	_radius.value = probe.radius_m
	_radius.custom_minimum_size = Vector2(320, 48)
	_radius.drag_started.connect(_begin_slider)
	_radius.drag_ended.connect(_end_slider)
	_radius.value_changed.connect(func(value: float) -> void: probe.radius_m = value)
	_panel.add_child(_radius)
	layer.add_child(_diagnostics)
	_diagnostics.position = Vector2(360, 16)
	_diagnostics.size.x = maxf(240, get_viewport().get_visible_rect().size.x - 376)
	_diagnostics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diagnostics.add_theme_font_size_override("font_size", 14)
	_diagnostics.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(calibration)
	calibration.completed.connect(_calibrated)
	_set_controls_enabled(false)


func _set_controls_enabled(enabled: bool) -> void:
	for control in _panel.get_children():
		if control is BaseButton:
			control.disabled = not enabled
	_radius.editable = enabled


func _button(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 48)
	button.pressed.connect(action)
	button.pressed.connect(func() -> void: _last_button = text)
	button.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			_last_gui_event = {"button": text, "pressed": event.pressed,
				"position": [event.position.x, event.position.y], "hovered": button.is_hovered()})
	_panel.add_child(button)


func _tool_action(action: Dictionary) -> void:
	var kind: String = action.type
	_last_operation = kind + (": " + str(action.reason) if action.has("reason") else "")
	if kind == "tool_cancel":
		_mark(probe.cancel())
		return
	if not input.editing_enabled():
		return
	var sample: PointerSample = action.get("sample")
	if calibration.active or not _panel.visible:
		if kind == "tool_begin" and calibration.active:
			calibration.record(sample, input.mapper.viewport_units_per_point(), get_viewport().scaling_3d_scale)
		return
	if kind == "tool_pause":
		probe.pause(sample.timestamp_s)
		return
	if kind in ["tool_begin", "tool_move", "tool_resume", "tool_end"]:
		_apply_sample(kind, sample, bool(action.get("over_ui", false)))


func _apply_sample(kind: String, sample: PointerSample, over_ui: bool) -> void:
	var camera := rig.get_camera()
	var hit := TerrainPicker.raycast(document, camera.project_ray_origin(sample.position_viewport),
		camera.project_ray_normal(sample.position_viewport))
	if hit.ok and not over_ui:
		var point := Vector2(hit.position.x, hit.position.z)
		var result: Dictionary
		if kind == "tool_begin":
			result = probe.begin(point)
		elif probe.is_active():
			result = probe.sample(sample.timestamp_s, point)
		if not result.is_empty():
			_mark(result)
			if result.error != "":
				input.cancel_all("tool_error")
				return
	elif probe.is_active():
		probe.pause(sample.timestamp_s)
	if kind == "tool_end":
		var change := probe.finish(sample.timestamp_s)
		if change != null:
			document.bump_revision()
			history.push_already_applied(change)
			_checkpoint()


func _mark(result: Dictionary) -> void:
	for loc: Vector2i in result.get("dirty_controls", result.get("controls", [])):
		_mark_control(loc)


func _mark_control(loc: Vector2i) -> void:
	if _simulator_preview != null:
		_simulator_preview.mark_dirty(TerrainView.MAP_CONTROL, loc)
	else:
		adapter.mark_dirty(TerrainAdapter.MAP_CONTROL, loc)


func _checkpoint() -> void:
	if probe.is_active() or _slider_active:
		_message = "Finish or cancel the active operation before checkpointing."
		return
	var error := storage.request_checkpoint(document)
	if error == "":
		DirAccess.make_dir_recursive_absolute(ACTIVE_WORLD.get_base_dir())
		var file := FileAccess.open(ACTIVE_WORLD, FileAccess.WRITE)
		if file != null:
			file.store_string(document.world_id)
		else:
			error = "Cannot persist active probe ID."
	_message = "Checkpoint requested." if error == "" else error


func _reload() -> void:
	if probe.is_active() or storage.is_busy():
		_message = "Finish the operation and checkpoint before reload."
		return
	var previous := CanonicalEncoder.authored_hash(document)
	var recovered := storage.recover_latest_valid(document.world_id, catalog)
	if recovered.doc == null:
		_message = recovered.error
		return
	document = recovered.doc
	probe.document = document
	rig.height_sampler = document.sample_height
	if _simulator_preview != null:
		_simulator_preview.initialize(document)
	else:
		adapter.replace_document(document)
	history.clear()
	_show_object()
	_message = "Reopen authored hash: " + ("EXACT" if previous == CanonicalEncoder.authored_hash(document) else "different durable revision")


func _undo() -> void:
	if probe.is_active():
		return
	_refresh_change(history.undo(document))


func _redo() -> void:
	if probe.is_active():
		return
	_refresh_change(history.redo(document))


func _refresh_change(change: WorldChange) -> void:
	if change == null:
		return
	for loc: Vector2i in change.before_controls:
		_mark_control(loc)
	_checkpoint()


func _start_calibration() -> void:
	if probe.is_active():
		return
	_panel.hide()
	calibration.start()


func _calibrated(results: Array[Dictionary]) -> void:
	# Restore after END so the last calibration contact cannot become a probe stroke.
	_message = "Calibration recorded: %d points. Save trace for evidence." % results.size()


func _toggle_scale() -> void:
	get_viewport().scaling_3d_scale = 0.5 if get_viewport().scaling_3d_scale == 1.0 else 1.0


func _save_trace() -> void:
	var stamp := str(Time.get_unix_time_from_system()).replace(".", "-")
	var error := input.trace.save("input-lab-" + stamp + ".json")
	var file := FileAccess.open("user://traces/input-lab-" + stamp + "-evidence.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"device_gate": "NOT RUN", "build": WorldCodec.default_created_with(),
			"fingerprint": JSON.parse_string(FileAccess.get_file_as_string("res://config/build_fingerprint.json")),
			"object_ids": Array(document.sorted_object_ids()), "terrain_payloads": _payload_hashes(),
			"provider": input.active_provider().diagnostics(), "stats": input.stats(),
			"renderer": RenderingServer.get_current_rendering_method(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"camera_transform": str(rig.get_camera().transform),
			"timing": runtime.snapshot(),
			"calibration": calibration.results, "authored_hash": CanonicalEncoder.authored_hash(document),
			"revision": document.document_revision, "trace_dropped": input.trace.dropped}, "\t"))
	else:
		error = "Evidence file could not be written."
	_message = "Trace and evidence saved in user://traces/." if error == "" else error


func _payload_hashes() -> Dictionary:
	var hashes := {}
	for loc in document.sorted_region_locations():
		var region := document.get_region(loc)
		hashes[str(loc)] = {"height": CanonicalEncoder.sha256_hex(region.height_bytes()),
			"control": CanonicalEncoder.sha256_hex(region.control_bytes())}
	return hashes


func _observe_sample(sample: PointerSample) -> void:
	_last_sample = sample.to_dict()
	if sample.phase == PointerSample.Phase.BEGIN:
		_last_begin = _last_sample.duplicate(true)
	_coalesced += int(sample.is_coalesced)
	_predicted += int(sample.is_predicted)
	if not _panel.visible and not calibration.active and sample.is_terminal():
		_panel.show()


func _diagnostic(action: Dictionary) -> void:
	_message = str(action.message)


func _begin_slider() -> void:
	_radius_before = probe.radius_m
	_slider_active = true


func _end_slider(_changed: bool) -> void:
	_slider_active = false


func _cancel_slider(_reason: String) -> void:
	if _slider_active:
		_slider_active = false
		_radius.value = _radius_before
		probe.radius_m = _radius_before


func _process(_delta: float) -> void:
	if not _ready_for_input:
		return
	var now := Time.get_ticks_usec()
	var refresh_ui := runtime.record_frame(now)
	_frame_gap = runtime.last_interval_s
	if _frame_gap > 0.25 and probe.is_active():
		input.cancel_all("tool_error")
	if _simulator_preview != null:
		_simulator_preview.flush()
	else:
		adapter.flush()
	if not refresh_ui:
		return
	_refresh_diagnostics()
	_source.text = "%s\nPencil: buttons and paint\nFingers: buttons and camera\n%s %s" % [input.provider_label(),
		_last_sample.get("source", "no BEGIN yet"), _last_sample.get("phase", "")]
	_status.text = "%s\n%s\n%s\n%s\nRevision %d · %s\nFrame %.1f ms · tick %d" % [input.banner_text(),
		_message, _last_operation, input.router.state_name(), document.document_revision,
		storage.status_text(document.document_revision), _frame_gap * 1000.0, runtime.frame_count]
	if runtime.capture_enabled:
		runtime.write_if_due(now, _runtime_state)


func _runtime_state() -> Dictionary:
	return {"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"provider": input.active_provider().diagnostics(), "input": input.stats(),
		"last_begin": _last_begin, "last_sample": _last_sample,
		"last_ui_action": _last_ui_action, "last_gui_event": _last_gui_event, "last_button": _last_button,
		"revision": document.document_revision, "save": storage.get_save_state(),
		"render_scale": get_viewport().scaling_3d_scale,
		"terrain_uploads": adapter.stats() if adapter != null else {},
		"build": JSON.parse_string(FileAccess.get_file_as_string("res://config/build_fingerprint.json"))}


func _refresh_diagnostics() -> void:
	var provider := input.active_provider()
	var details := provider.diagnostics()
	var metrics := provider.view_metrics()
	_diagnostics.text = "%s / %s\nBEGIN %s id=%s · %s\nSource %s · raw %s · viewport %s\nScale %s · mapping %d · 3D %.0f%%\nContacts %d · swallowed %d · coalesced %d · predicted %d\nObserver %s · overflow %s\nPressure OFF · radius %.1f m" % [
		RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(),
		_last_begin.get("source", "none"), _last_begin.get("id", "none"), _last_operation,
		_last_sample.get("source", "none"), _last_sample.get("raw", []), _last_sample.get("vp", []),
		metrics.get("content_scale", 1.0), input.mapper.generation, get_viewport().scaling_3d_scale * 100,
		input.router.contacts().size(), input.stats().swallowed, _coalesced, _predicted,
		str(details.get("observed_view_class", "not observed")).left(48), details.get("overflow_count", 0),
		probe.radius_m]


func _input(event: InputEvent) -> void:
	if _simulator_preview != null and event is InputEventKey:
		if event.pressed and not event.echo:
			_simulator_key(event.keycode)


func _simulator_key(key: int) -> void:
	var provider := input.active_provider() as SimulatorInputProvider
	if provider == null:
		return
	if key == KEY_P:
		input.cancel_all("explicit")
		provider.pencil_mode = not provider.pencil_mode
	elif key in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN] and not calibration.active:
		input.cancel_all("explicit")
		var direction := Vector2.LEFT if key == KEY_LEFT else Vector2.RIGHT
		if key in [KEY_UP, KEY_DOWN]:
			direction = Vector2.UP if key == KEY_UP else Vector2.DOWN
		var center := get_viewport().get_visible_rect().size * 0.75
		provider.queue_camera_drag(input.mapper.unmap(center), input.mapper.unmap(center + direction * 120))


func _notification(what: int) -> void:
	if _ready_for_input and what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		input.cancel_all("app_deactivated")
		_checkpoint()
