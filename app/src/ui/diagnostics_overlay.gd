class_name DiagnosticsOverlay
extends PanelContainer
## Diagnostics and debug controls (spec §18.3, §18.4). Hidden by default; the text is rebuilt at
## most four times per second while visible. Fault buttons are testing aids, captioned as such.

const REFRESH_MSEC := 250
const MAX_HEIGHT := 1000.0

var _session: EditorSession
var _text := Label.new()
var _scroll := ScrollContainer.new()
var _max_height := MAX_HEIGHT
var _toggles: Dictionary = {}  # caption -> Button
var _last_sample: PointerSample = null
var _last_refresh_msec := -REFRESH_MSEC
var _region_grid := false
var _fingerprint := ""


func setup(session: EditorSession) -> void:
	_session = session
	visible = false
	var column := VBoxContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.add_child(column)
	add_child(_scroll)
	_text.add_theme_font_override("font", UiKit.mono_font())
	_text.add_theme_font_size_override("font_size", 13)
	_text.custom_minimum_size.x = 356
	_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	column.add_child(_text)
	# A third entry marks a toggle button.
	column.add_child(_grid([
		["Blend view", _toggle_view.bind("control_blend"), true],
		["Height view", _toggle_view.bind("heightmap"), true],
		["Normals view", _toggle_view.bind("normals"), true],
		["Region grid", _toggle_grid, true], ["Anchors", _toggle_anchors, true],
		["Object IDs", _toggle_ids, true],
		["Save trace", func() -> void: _session.save_trace()],
		["Verify GPU", func() -> void: _session.verify_gpu_terrain()]]))
	column.add_child(UiKit.label("Development", 14))
	column.add_child(_grid([["Render bench", _start_render_bench]]))
	column.add_child(UiKit.label("Fault injection (testing)", 14))
	column.add_child(_grid([
		["Fail next save", func() -> void: _session.inject_save_failure()],
		["Sim. overflow", func() -> void: _session.simulate_cancel("queue_overflow")],
		["Sim. remap", func() -> void: _session.simulate_cancel("mapping_changed")]]))
	_session.input.sample_received.connect(func(sample: PointerSample) -> void: _last_sample = sample.clone())
	_fingerprint = _read_fingerprint()


## The overlay never grows taller than `h`; the content scrolls inside it.
func set_max_height(h: float) -> void:
	_max_height = minf(h, MAX_HEIGHT)
	_fit_height()


func _fit_height() -> void:
	var column := _scroll.get_child(0) as Control
	var pad := get_theme_stylebox("panel").get_minimum_size().y
	_scroll.custom_minimum_size.y = maxf(minf(column.get_combined_minimum_size().y, _max_height - pad), 80.0)
	reset_size()


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


func _start_render_bench() -> void:
	_session.start_render_bench()  # posts its own error


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
	(_toggles["Normals view"] as Button).set_pressed_no_signal(view == "normals")
	_text.text = _build_text()
	_fit_height()


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
		"Mode %s · tool %s · invert %s · op %s" % [s.mode, s.tool, "on" if s.inverted else "off",
				s.operation_id if s.operation_id != "" else "none"],
		"Revision %d · %s" % [s.revision, s.save_text],
		"History %d actions · %d bytes · evicted %d" % [s.history_size, s.history_bytes, s.evicted],
		_content_line(s.object_count),
		_rules_line(),
		"Frame p50 %.1f ms · p95 %.1f ms · brush p95 %.1f ms" % [s.frame_p50_ms, s.frame_p95_ms, s.brush_p95_ms],
		_stroke_line(s.last_stroke),
		"Last cancel: %s" % (s.last_cancel if s.last_cancel != "" else "none"),
		_terrain_line(s.terrain_stats),
		_render_line(s.render),
		"Input diag %s" % _input_diagnostics(provider.diagnostics()),
		"Save queue %s" % ("busy" if _session.storage.is_busy() else "idle"),
	]
	return "\n".join(lines)


func _content_line(object_count: int) -> String:
	var layer := _session.layers.stats()
	return "Objects %d · scatter %d inst · %d cells / %d multimeshes · paths %d" % [object_count,
			_session.document.scatter.count(), int(layer.cells), int(layer.multimeshes), _session.document.paths.size()]


func _rules_line() -> String:
	var r := _session.document.rules
	return "Rules rock %s %d° · sand %s %.1f m · highlight %s" % ["on" if r.rock_enabled else "off", r.rock_slope_deg,
			"on" if r.sand_enabled else "off", r.sand_height_dm / 10.0,
			"on" if _session.terrain.get_rule_highlight() else "off"]


static func _stroke_line(st: Dictionary) -> String:
	if st.is_empty():
		return "Stroke: none"
	var p := "p n/a" if is_nan(st.pressure_min) else "p %.2f–%.2f (pf %.2f)" % [st.pressure_min, st.pressure_max, st.pf_avg]
	return "Stroke %s %s · %.2f s · %d samples · %s · steps %d · Δh %.3f m · ctrl %d · gap %.0f ms" % [
		st.tool, st.result, st.duration_s, st.samples, p, st.steps, st.peak_dh_m, st.controls_changed, st.max_gap_ms]


static func _terrain_line(ts: Dictionary) -> String:
	return "Terrain uploads h %d · c %d · flush %.1f ms" % [int(ts.get("uploads_height", 0)),
			int(ts.get("uploads_control", 0)), float(ts.get("last_flush_ms", 0.0))]


static func _render_line(r: Dictionary) -> String:
	return "Draws V %d / S %d · prims %d · GPU %.1f ms · CPU %.1f ms · VRAM %.0f MiB · scale %.2f" % [
		int(r.visible_draws), int(r.shadow_draws), int(r.visible_prims), float(r.gpu_ms), float(r.cpu_ms),
		float(r.video_mem_mib), float(r.scale_3d)]


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
