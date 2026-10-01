class_name DiagnosticsOverlay
extends PanelContainer
## Diagnostics and debug controls (spec §18.3, §18.4). Hidden by default; the text is rebuilt at
## most four times per second while visible. Fault buttons are testing aids, captioned as such.

const REFRESH_MSEC := 250

var _session: EditorSession
var _text := Label.new()
var _toggles: Dictionary = {}  # caption -> Button
var _last_sample: PointerSample = null
var _last_refresh_msec := -REFRESH_MSEC
var _region_grid := false
var _fingerprint := ""


func setup(session: EditorSession) -> void:
	_session = session
	visible = false
	var column := VBoxContainer.new()
	add_child(column)
	_text.add_theme_font_override("font", UiKit.mono_font())
	_text.add_theme_font_size_override("font_size", 13)
	_text.custom_minimum_size.x = 356
	_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	column.add_child(_text)
	# A third entry marks a toggle button.
	column.add_child(_grid([
		["Blend view", _toggle_view.bind("control_blend"), true],
		["Height view", _toggle_view.bind("heightmap"), true],
		["Region grid", _toggle_grid, true], ["Anchors", _toggle_anchors, true],
		["Object IDs", _toggle_ids, true], ["3D 50%", _toggle_scale, true],
		["Save trace", func() -> void: _session.save_trace()]]))
	column.add_child(UiKit.label("Fault injection (testing)", 14))
	column.add_child(_grid([
		["Fail next save", func() -> void: _session.inject_save_failure()],
		["Sim. overflow", func() -> void: _session.simulate_cancel("queue_overflow")],
		["Sim. remap", func() -> void: _session.simulate_cancel("mapping_changed")]]))
	_session.input.sample_received.connect(func(sample: PointerSample) -> void: _last_sample = sample.clone())
	_fingerprint = _read_fingerprint()


func _grid(entries: Array) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	for entry: Array in entries:
		var b := UiKit.button(entry[0], entry[1], entry.size() > 2)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.theme_type_variation = "SurfaceButton"
		grid.add_child(b)
		_toggles[entry[0]] = b
	return grid


static func _read_fingerprint() -> String:
	var path := "res://config/build_fingerprint.json"
	if not FileAccess.file_exists(path):
		return "n/a"
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return "unreadable"
	return str((parsed as Dictionary).get("source_sha256", "n/a")).left(12)


func _toggle_view(mode: String) -> void:
	var on := _session.terrain.get_debug_view() != mode
	var error := _session.terrain.set_debug_view(mode if on else "normal")
	if error != "":
		_session.post_message(error, true)
	refresh(true)


func _toggle_grid() -> void:
	_region_grid = not _region_grid
	_session.terrain.set_region_grid(_region_grid)


func _toggle_anchors() -> void:
	_session.presenter.set_show_anchors((_toggles["Anchors"] as Button).button_pressed)


func _toggle_ids() -> void:
	_session.presenter.set_show_ids((_toggles["Object IDs"] as Button).button_pressed)


func _toggle_scale() -> void:
	_session.set_render_scale(0.5 if (_toggles["3D 50%"] as Button).button_pressed else 1.0)


func text() -> String:
	return _text.text


func refresh(force := false) -> void:
	if _session == null or not visible:
		return
	var now := Time.get_ticks_msec()
	if not force and now - _last_refresh_msec < REFRESH_MSEC:
		return
	_last_refresh_msec = now
	var view := _session.terrain.get_debug_view()
	(_toggles["Blend view"] as Button).set_pressed_no_signal(view == "control_blend")
	(_toggles["Height view"] as Button).set_pressed_no_signal(view == "heightmap")
	_text.text = _build_text()
	reset_size()


func _build_text() -> String:
	var s := _session.status()
	var provider := _session.input.active_provider()
	var lines: Array[String] = [
		"Build %s · fp %s" % [_build_text_short(), _fingerprint],
		"Device %s · %s / %s" % [OS.get_model_name(), s.renderer, s.driver],
		"Input %s · last %s" % [s.provider_label, _sample_source()],
		"Router %s · contacts %s" % [s.router_state, str(_session.input.router.contacts().keys())],
		_coordinates(),
		"Pressure %s · %s" % ["available" if s.pressure_available else "unavailable", _pressure()],
		"Hit %s" % s.last_hit,
		"Tool %s · op %s" % [s.tool, s.operation_id if s.operation_id != "" else "none"],
		"Revision %d · %s" % [s.revision, s.save_text],
		"History %d actions · %d bytes · evicted %d" % [s.history_size, s.history_bytes, s.evicted],
		"Objects %d · scatter: PoC+ (not built)" % s.object_count,
		"Frame p50 %.1f ms · p95 %.1f ms · brush p95 %.1f ms" % [s.frame_p50_ms, s.frame_p95_ms, s.brush_p95_ms],
		"Input diag %s" % _input_diagnostics(provider.diagnostics()),
		"Save queue %s" % ("busy" if _session.storage.is_busy() else "idle"),
	]
	return "\n".join(lines)


static func _build_text_short() -> String:
	var built := WorldCodec.default_created_with()
	return "godot %s · t3d %s · wp %s" % [built.godot, built.terrain3d, built.world_painter]


func _input_diagnostics(diag: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in diag:
		if key.contains("overflow") or key.contains("queue"):
			parts.append("%s=%s" % [key, str(diag[key])])
	return " ".join(parts) if not parts.is_empty() else "n/a"


func _sample_source() -> String:
	if _last_sample == null:
		return "no sample"
	return "%s %s" % [PointerSample.source_name(_last_sample.source), PointerSample.phase_name(_last_sample.phase)]


func _coordinates() -> String:
	if _last_sample == null:
		return "Raw n/a · Viewport n/a"
	var r := _last_sample.position_raw
	var v := _last_sample.position_viewport
	return "Raw (%.1f, %.1f) · Viewport (%.1f, %.1f)" % [r.x, r.y, v.x, v.y]


func _pressure() -> String:
	if _last_sample == null or not _last_sample.pressure_valid:
		return "n/a"
	return "%.2f" % _last_sample.pressure
