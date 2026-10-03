extends Node
## Entry of the dedicated preview process (ADR 0016 P1/P2/P4). Reads and deletes its private config, connects to the
## editor's broker, starts the LAN listener and renders the replica under an isolated root, using the host project's
## profile scene when `world_painter/preview/profile_scene` names one. It never writes under res://, exits when the
## broker connection ends, and removes only its own session directory.
## Command line (after `--`): --wp-config <absolute path of the session's config.json>

const MOUNT_GROUP := "world_painter_mount"
const STATUS_INTERVAL_MSEC := 500
const EXIT_BROKER_LOST := 3
const EXIT_BAD_CONFIG := 2

var config: Dictionary = {}
var broker := PreviewBrokerClient.new()
var listener := LiveListener.new()
var driver := LiveReceiverDriver.new()
var root := WorldPreviewRoot.new()
var assets: PreviewAssets
var error := ""

var _status_msec := 0
var _quitting := false


func _ready() -> void:
	var loaded := PreviewSession.read_and_delete(_arg_value(OS.get_cmdline_user_args(), "--wp-config"))
	if not loaded.ok:
		print("preview: ", loaded.error)
		_quit(EXIT_BAD_CONFIG)
		return
	config = loaded.config
	var catalog_result := AssetCatalog.load_from()
	if catalog_result[1] != "":
		print("preview: trusted catalog: ", catalog_result[1])
		_quit(EXIT_BAD_CONFIG)
		return
	var catalog: AssetCatalog = catalog_result[0]
	add_child(broker)
	broker.lost.connect(func(reason: String) -> void:
		print("preview: ", reason)
		_quit(EXIT_BROKER_LOST))
	broker.new_pairing_requested.connect(listener.refresh_pairing)
	broker.freeze_requested.connect(_on_freeze_requested)
	var broker_error := broker.connect_to(int(config.broker_port), str(config.broker_credential))
	if broker_error != "":
		print("preview: ", broker_error)
		_quit(EXIT_BROKER_LOST)
		return
	_start_listener(catalog)
	assets = PreviewAssets.new(catalog, broker, str(config.blob_root))
	_build_scene(catalog)


func _start_listener(catalog: AssetCatalog) -> void:
	add_child(listener)
	error = listener.listen(int(config.listener_port), str(config.listener_bind), bool(config.allow_insecure_lan))
	add_child(driver)
	driver.setup(listener, catalog, PreviewSession.session_dir(str(config.session_id)))


func _build_scene(catalog: AssetCatalog) -> void:
	var profile := _load_profile()
	var mount: Node = self
	var camera: Camera3D = null
	if profile != null:
		add_child(profile)
		var mounts := get_tree().get_nodes_in_group(MOUNT_GROUP)
		if mounts.is_empty():
			error = "the profile scene has no node in group '%s'; the default environment is used" % MOUNT_GROUP
			profile.queue_free()
			profile = null
		else:
			mount = mounts[0]
			var cameras := profile.find_children("*", "Camera3D", true, false)
			camera = cameras[0] if not cameras.is_empty() else null
	if profile != null and WPMaterialMapper.supports(profile):
		assets.set_material_mapper(WPMaterialMapper.new(profile))
	listener.profile_name = "host-profile" if profile != null else "default"
	mount.add_child(root)
	root.setup(catalog, assets, profile == null, camera)
	driver.replica_created.connect(root.bind_replica)
	var camera_input := PreviewCameraInput.new()
	camera_input.rig = root.rig
	add_child(camera_input)


func _load_profile() -> Node:
	var path := str(config.profile_scene)
	if path == "":
		return null
	if not path.begins_with("res://") or path.contains("..") or not ResourceLoader.exists(path):
		error = "the profile scene '%s' cannot be loaded; the default environment is used" % path.left(120)
		return null
	var scene := load(path) as PackedScene
	return scene.instantiate() if scene != null else null


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _quitting or not broker.is_ready() or now - _status_msec < STATUS_INTERVAL_MSEC:
		return
	_status_msec = now
	broker.send_status(PreviewStatus.build(listener, driver.replica, _extra()))


func _on_freeze_requested(request_id: int) -> void:
	broker.send_message(FrozenSnapshot.write(driver.replica, PreviewSession.session_dir(str(config.session_id)), request_id))


func _extra() -> Dictionary:
	var extra := {"error": error}
	if driver.replica != null and root.display.doc != null:
		extra["missing"] = assets.missing(root.display.doc)
		extra["visual_ready"] = (extra.missing as Dictionary).is_empty()
		extra["overlay"] = not driver.replica.overlay.is_empty()
	return extra


func _quit(code: int) -> void:
	if _quitting:
		return
	_quitting = true
	if listener.is_listening():
		listener.stop()
	if config.has("session_id"):
		PreviewSession.remove_session(str(config.session_id))
	if assets != null:
		assets.shutdown()
	get_tree().quit(code)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit(0)


static func _arg_value(args: PackedStringArray, name: String) -> String:
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""
