class_name MacConsumer
extends Node3D
## Independent read-only consumer of an exported world (spec §17.6, WP05). It reuses the editor's
## trusted catalog, validation, TerrainAdapter and ObjectPresenter, but has no editing, input
## system or iOS plugin. Objects are shown exactly as stored; nothing is re-snapped.
## User args: --world=PATH (required) [--verify-only] [--report=PATH] [--quit-after-load].

const NEXT_ACTION := "Re-export the world, then validate with dev.py validate-world."
const ORBIT_BUTTON := MOUSE_BUTTON_RIGHT
const PAN_BUTTON := MOUSE_BUTTON_MIDDLE
const WHEEL_STEP := 1.1
const REF_SPAN := 100.0

## Tests set this false and call run() themselves.
var auto_run := true
var document: WorldDocument
var catalog: AssetCatalog
var rig: OrbitCameraRig
var adapter: TerrainAdapter
var presenter: ObjectPresenter
var layers: WorldLayers
var info_label: Label
var _drag := ""


func _ready() -> void:
	if not auto_run:
		return
	var args := OS.get_cmdline_user_args()
	var code := run(args)
	if args.has("--verify-only") or args.has("--quit-after-load"):
		settle_now()
		get_tree().quit(code)


func _process(_delta: float) -> void:
	if presenter != null:
		presenter.service_frame()


## Applies the presenter's scheduled render work (bounded to about 2 s); true when nothing is pending.
func settle_now() -> bool:
	return presenter == null or presenter.settle_now()


## Returns the process exit code: 0 loaded and (in visual mode) displayed, 1 failure.
func run(args: PackedStringArray) -> int:
	var world := _arg_value(args, "--world=")
	var verify_only := args.has("--verify-only")
	var result := _load(world)
	if verify_only:
		return _emit_report(result, _arg_value(args, "--report="))
	if result.error != "":
		_show_error(result.error)
		return 1
	_present(result.report)
	return 0


func _load(world: String) -> Dictionary:
	if world == "":
		return {"error": "missing required --world=PATH"}
	var loaded := AssetCatalog.load_from()
	if loaded[1] != "":
		return {"error": "trusted catalog: " + loaded[1]}
	catalog = loaded[0]
	var result := WorldLoader.load_world(world, catalog)
	if result[1] != "":
		return {"error": result[1]}
	document = result[0]
	return {"error": "", "report": WorldLoader.report(document, catalog)}


func _emit_report(result: Dictionary, report_path: String) -> int:
	var payload := {"ok": result.error == "", "error": result.error}
	if result.error == "":
		payload.merge(result.report)
	var json := JSON.stringify(payload)
	print("WORLDPOC_REPORT " + json)
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			print("warning: cannot write report to " + report_path)
		else:
			file.store_string(json)
	return 0 if result.error == "" else 1


func _present(report: Dictionary) -> void:
	rig = OrbitCameraRig.new()
	rig.height_sampler = document.sample_height
	add_child(rig)
	rig.set_world_rect(document.layout.world_rect())
	rig.reset_to(rig.controller.fixture_pose(document.sample_height(0.0, 0.0)))
	adapter = TerrainAdapter.new()
	adapter.set_camera(rig.get_camera())
	add_child(adapter)
	var error := adapter.initialize(document)
	if error != "":
		_show_error(error)
		return
	_build_light()
	presenter = ObjectPresenter.new()
	add_child(presenter)
	presenter.setup(catalog)
	presenter.rebuild(document)
	layers = WorldLayers.new()
	add_child(layers)
	layers.setup(catalog)
	layers.rebuild(document)
	_show_info("MAC CONSUMER — read-only\nworld %s\nrevision %d\nauthored hash %s\nobjects %d\nscatter %d\npaths %d\ngrounding mismatches %d" % [
		report.world_id, report.document_revision, report.authored_hash, report.object_count,
		layers.stats().instances, report.path_count, report.grounding_mismatches])


func _show_error(error: String) -> void:
	_show_info("MAC CONSUMER — world rejected\n%s\n%s" % [error, NEXT_ACTION], 28)


func _show_info(text: String, size := 16) -> void:
	if info_label == null:
		var layer := CanvasLayer.new()
		add_child(layer)
		info_label = Label.new()
		info_label.position = Vector2(16, 16)
		info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_label.custom_minimum_size.x = 900
		layer.add_child(info_label)
	info_label.add_theme_font_size_override("font_size", size)
	info_label.text = text


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


func _unhandled_input(event: InputEvent) -> void:
	if rig == null:
		return
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _drag != "":
		_mouse_motion(event as InputEventMouseMotion)


func _mouse_button(event: InputEventMouseButton) -> void:
	var pos := event.position
	if event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		var span := REF_SPAN / WHEEL_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else REF_SPAN * WHEEL_STEP
		_camera_action("camera_pan_zoom_begin", pos, REF_SPAN)
		_camera_action("camera_pan_zoom", pos, span)
		rig.handle_camera_action({"type": "camera_end"})
		return
	if event.button_index != ORBIT_BUTTON and event.button_index != PAN_BUTTON:
		return
	if not event.pressed:
		_drag = ""
		rig.handle_camera_action({"type": "camera_end"})
	elif event.button_index == PAN_BUTTON or event.shift_pressed:
		_drag = "pan"
		_camera_action("camera_pan_zoom_begin", pos, REF_SPAN)
	else:
		_drag = "orbit"
		rig.handle_camera_action({"type": "camera_orbit_begin"})


func _mouse_motion(event: InputEventMouseMotion) -> void:
	if _drag == "pan":
		_camera_action("camera_pan_zoom", event.position, REF_SPAN)
	else:
		rig.handle_camera_action({"type": "camera_orbit", "delta": event.relative})


func _camera_action(type: String, centroid: Vector2, span: float) -> void:
	rig.handle_camera_action({"type": type, "centroid": centroid, "span": span})


static func _arg_value(args: PackedStringArray, prefix: String) -> String:
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""
