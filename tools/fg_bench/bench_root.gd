extends Node3D
## Terrain-only iPad bench for the fantasy-game valley (godot-ipad build/fg_ipad copy only).
## No character or game logic: the scene keeps terrain, water, forest, props, grass, ground cover
## and the lighting/atmosphere; a scripted BenchCamera replaces the player and its camera rig.
## User args (after the engine's `--`):
##   --bench                 run the camera phases and write user://bench/<scene>-<method>-<unix>.json
##   --bench-phase-s=<sec>   seconds per measured phase (default 15)
##   --bench-quit            quit after the report instead of handing over to touch control
##   --bench-scale=<0.25..1> 3D render scale (default 1.0 = native)
##   --bench-far=<m>         camera far plane (default 1500; the game's camera rig uses 250)
##   --bench-shadows=off     disable the sun's shadows (ablation)
## Touch (after the bench, or without --bench): one finger orbits, two fingers pan, pinch zooms.

const WARMUP_S := 10.0
const OVERLAY_INTERVAL_S := 0.25
const STYLE := preload("res://materials/world_style.tres")
const SPAWN := Vector2(-22, -145)  # the valley's authored spawn point (x, z)
const EYE_M := 1.8
const WALK_SPEED := 5.0

var _bench := false
var _quit_after := false
var _phase_s := 15.0
var _phases: Array[Dictionary] = []
var _phase_index := -1
var _phase_t := 0.0
var _records: Dictionary = {}  # phase name -> {frame_ms, cpu_ms, gpu_ms, draws, prims} (Arrays)
var _last_usec := 0
var _label: Label
var _overlay_t := 0.0
var _report_path := ""
# Touch orbit state (target on the ground, yaw/pitch in radians, distance in metres).
var _target := Vector3.ZERO
var _yaw := 0.6
var _pitch := 0.8
var _dist := 140.0
var _touches: Dictionary = {}
var _pinch_span := 0.0
var _no_shadows := false

@onready var _cam: Camera3D = $BenchCamera
@onready var _terrain: Node = $Terrain


func _ready() -> void:
	STYLE.apply()
	_build_overlay()
	var args := OS.get_cmdline_user_args()
	_bench = "--bench" in args
	_quit_after = "--bench-quit" in args
	for a in args:
		if a.begins_with("--bench-phase-s="):
			_phase_s = maxf(2.0, float(a.trim_prefix("--bench-phase-s=")))
		elif a.begins_with("--bench-scale="):
			get_viewport().scaling_3d_scale = clampf(float(a.trim_prefix("--bench-scale=")), 0.25, 1.0)
		elif a == "--bench-shadows=off":
			_no_shadows = true
		elif a.begins_with("--bench-far="):
			_cam.far = clampf(float(a.trim_prefix("--bench-far=")), 10.0, 5000.0)
	_phases = [
		{"name": "warmup", "seconds": WARMUP_S, "camera": "ground_walk"},
		{"name": "ground_walk", "seconds": _phase_s, "camera": "ground_walk"},
		{"name": "low_orbit_30m", "seconds": _phase_s, "camera": "low_orbit"},
		{"name": "editor_view_140m", "seconds": _phase_s, "camera": "editor_view"},
		{"name": "overview_whole_valley", "seconds": _phase_s, "camera": "overview"},
	]
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_target = _ground(SPAWN.x, SPAWN.y)
	if _bench:
		_next_phase()
	else:
		_apply_orbit()


func _process(delta: float) -> void:
	if _no_shadows:
		($Sun as DirectionalLight3D).shadow_enabled = false  # every frame: lighting presets may re-enable it
	var now := Time.get_ticks_usec()
	var frame_ms := 0.0 if _last_usec == 0 else float(now - _last_usec) / 1000.0
	_last_usec = now
	var rid := get_viewport().get_viewport_rid()
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	if _bench and _phase_index >= 0 and _phase_index < _phases.size():
		var p: Dictionary = _phases[_phase_index]
		_place_camera(str(p.camera), _phase_t)
		_record(str(p.name), frame_ms, cpu, gpu)
		_phase_t += delta
		if _phase_t >= float(p.seconds):
			_next_phase()
	_overlay_t += delta
	if _overlay_t >= OVERLAY_INTERVAL_S:
		_overlay_t = 0.0
		_update_overlay(frame_ms, cpu, gpu)


# --- camera paths ------------------------------------------------------------------------------

func _ground(x: float, z: float) -> Vector3:
	return Vector3(x, float(_terrain.call("get_height", x, z)), z)


func _place_camera(kind: String, t: float) -> void:
	match kind:
		"ground_walk":
			var x := SPAWN.x + WALK_SPEED * t
			var z := SPAWN.y + WALK_SPEED * t * 0.5
			var pos := _ground(x, z) + Vector3(0, EYE_M, 0)
			_cam.global_position = pos
			_cam.look_at(_ground(x + 20.0, z + 10.0) + Vector3(0, EYE_M * 0.6, 0))
		"low_orbit":
			_orbit_around(_ground(SPAWN.x, SPAWN.y), 50.0, 30.0, t * 0.15)
		"editor_view":
			_orbit_around(_ground(SPAWN.x, SPAWN.y), 100.0, 100.0, t * 0.08)
		"overview":
			_orbit_around(_ground(0, 0), 450.0, 550.0, t * 0.04)


func _orbit_around(target: Vector3, radius: float, height: float, angle: float) -> void:
	_cam.global_position = target + Vector3(cos(angle) * radius, height, sin(angle) * radius)
	_cam.look_at(target)


func _apply_orbit() -> void:
	var offset := Vector3(cos(_yaw) * cos(_pitch), sin(_pitch), sin(_yaw) * cos(_pitch)) * _dist
	_cam.global_position = _target + offset
	_cam.look_at(_target)


# --- bench --------------------------------------------------------------------------------------

func _record(phase: String, frame_ms: float, cpu: float, gpu: float) -> void:
	if not _records.has(phase):
		_records[phase] = {"frame_ms": [], "cpu_ms": [], "gpu_ms": [], "draws": [], "prims": []}
	var r: Dictionary = _records[phase]
	if frame_ms > 0.0:
		(r.frame_ms as Array).append(frame_ms)
	(r.cpu_ms as Array).append(cpu)
	(r.gpu_ms as Array).append(gpu)
	(r.draws as Array).append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	(r.prims as Array).append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))


func _next_phase() -> void:
	_phase_index += 1
	_phase_t = 0.0
	if _phase_index >= _phases.size():
		_finish()


func _finish() -> void:
	_bench = false
	var vp := get_viewport()
	var report := {
		"harness": "godot-ipad build/fg_ipad bench_root.gd (terrain + objects only, no character/game logic)",
		"source_project": "fantasy-game", "source_commit": "ce478c4",
		"scene": "res://bench/valley_bench.tscn (from scenes/valley.tscn)",
		"renderer_method": RenderingServer.get_current_rendering_method(),
		"user_args": OS.get_cmdline_user_args(), "sun_shadows": ($Sun as DirectionalLight3D).shadow_enabled, "engine_args": OS.get_cmdline_args(),
		"renderer_driver": RenderingServer.get_current_rendering_driver_name(),
		"device_model": OS.get_model_name(), "os": "%s %s" % [OS.get_name(), OS.get_version()],
		"engine": Engine.get_version_info().string, "debug_build": OS.is_debug_build(),
		"viewport_size": [vp.get_visible_rect().size.x, vp.get_visible_rect().size.y],
		"scaling_3d_scale": vp.scaling_3d_scale, "camera_far_m": _cam.far, "camera_fov_deg": _cam.fov,
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"unix_time": Time.get_unix_time_from_system(), "phase_seconds": _phase_s, "phases": {},
	}
	for p in _phases:
		if _records.has(p.name):
			report.phases[p.name] = _summarize(_records[p.name])
	DirAccess.make_dir_recursive_absolute("user://bench")
	_report_path = "user://bench/valley-%s-s%.2f-far%d%s-%d.json" % [report.renderer_method, vp.scaling_3d_scale, int(_cam.far), "-noshadow" if _no_shadows else "", int(report.unix_time)]
	var f := FileAccess.open(_report_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "\t"))
		f.close()
	print("BENCH report %s" % _report_path)
	for name: String in report.phases:
		var s: Dictionary = report.phases[name]
		print("BENCH %s frame p50 %.1f p95 %.1f p99 %.1f fps %.1f gpu p50 %.1f cpu p50 %.1f draws %d prims %d" % [
			name, s.frame_ms.p50, s.frame_ms.p95, s.frame_ms.p99, s.fps_avg, s.gpu_ms.p50, s.cpu_ms.p50,
			int(s.draws_p50), int(s.prims_p50)])
	if _quit_after:
		get_tree().quit()
	else:
		_target = _ground(SPAWN.x, SPAWN.y)
		_apply_orbit()


func _summarize(r: Dictionary) -> Dictionary:
	var frame := PackedFloat32Array(r.frame_ms)
	var over_33 := 0
	var over_100 := 0
	var total := 0.0
	for v in frame:
		total += v
		over_33 += 1 if v > 33.4 else 0
		over_100 += 1 if v > 100.0 else 0
	return {
		"frames": frame.size(),
		"fps_avg": 0.0 if total <= 0.0 else 1000.0 * frame.size() / total,
		"frame_ms": _stats(frame), "cpu_ms": _stats(PackedFloat32Array(r.cpu_ms)),
		"gpu_ms": _stats(PackedFloat32Array(r.gpu_ms)),
		"frames_over_33ms": over_33, "frames_over_100ms": over_100,
		"draws_p50": _stats(PackedFloat32Array(r.draws)).p50, "prims_p50": _stats(PackedFloat32Array(r.prims)).p50,
	}


static func _stats(data: PackedFloat32Array) -> Dictionary:
	if data.is_empty():
		return {"avg": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := data.duplicate()
	sorted.sort()
	var n := sorted.size()
	var sum := 0.0
	for v in data:
		sum += v
	var pct := func(p: float) -> float: return sorted[clampi(int(ceil(p * n)) - 1, 0, n - 1)]
	return {"avg": sum / n, "p50": pct.call(0.5), "p95": pct.call(0.95), "p99": pct.call(0.99), "max": sorted[n - 1]}


# --- overlay ------------------------------------------------------------------------------------

func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(24, 24)
	_label.add_theme_font_size_override("font_size", 28)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_label)


func _update_overlay(frame_ms: float, cpu: float, gpu: float) -> void:
	var phase := "touch: 1 finger orbit · 2 fingers pan · pinch zoom"
	if _bench and _phase_index >= 0 and _phase_index < _phases.size():
		phase = "bench: %s %.0f/%.0f s" % [_phases[_phase_index].name, _phase_t, float(_phases[_phase_index].seconds)]
	elif _report_path != "":
		phase = "bench done: %s\n%s" % [_report_path.get_file(), phase]
	var size := get_viewport().get_visible_rect().size
	_label.text = "%s / %s  %dx%d\nFPS %.0f  frame %.1f ms  cpu %.1f  gpu %.1f\ndraws %d  prims %dk\n%s" % [
		RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(),
		size.x, size.y, Engine.get_frames_per_second(), frame_ms, cpu, gpu,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0), phase]


# --- touch orbit --------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _bench:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touches[t.index] = t.position
		else:
			_touches.erase(t.index)
		_pinch_span = _span()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_touches[d.index] = d.position
		if _touches.size() == 1:
			_yaw += d.relative.x * 0.005
			_pitch = clampf(_pitch + d.relative.y * 0.004, 0.08, 1.5)
		elif _touches.size() >= 2:
			var span := _span()
			if _pinch_span > 0.0 and span > 0.0:
				_dist = clampf(_dist * _pinch_span / span, 3.0, 1200.0)
			_pinch_span = span
			# Two-finger drag pans the target on the ground, scaled by distance.
			var right := Vector3(-sin(_yaw), 0, cos(_yaw))
			var forward := Vector3(-cos(_yaw), 0, -sin(_yaw))
			var k := _dist * 0.0015 / float(_touches.size())
			var moved := _target - right * d.relative.x * k + forward * d.relative.y * k
			_target = _ground(moved.x, moved.z)
		_apply_orbit()


func _span() -> float:
	if _touches.size() < 2:
		return 0.0
	var pts: Array = _touches.values()
	return (pts[0] as Vector2).distance_to(pts[1])
