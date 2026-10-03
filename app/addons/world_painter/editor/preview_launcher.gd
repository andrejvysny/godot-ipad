@tool
class_name PreviewLauncher
extends Node
## Starts, monitors and stops the dedicated preview process (ADR 0016 P1/P2). The child is the same Godot executable
## on the same project; only the path of its private config file is on the command line (the config holds the broker
## credential). Stopping kills the child and removes its session directory, and nothing else.

signal state_changed()

const SCENE := "res://addons/world_painter/preview/preview_main.tscn"
const SETTING_PROFILE := "world_painter/preview/profile_scene"
const STATES := ["stopped", "starting", "running", "exited"]

var broker := PreviewBroker.new()
var resolver: PreviewAssetResolver
var state := "stopped"
var pid := -1
var session_id := ""
var last_error := ""
## Extra engine arguments before the scene (tests pass --headless).
var extra_args := PackedStringArray()
var executable := ""
## The arguments of the last launch (tests assert that no secret is among them).
var last_args := PackedStringArray()

var _config_path := ""


func _ready() -> void:
	add_child(broker)
	resolver = PreviewAssetResolver.new()
	add_child(resolver)
	broker.asset_resolver = resolver
	broker.child_changed.connect(_on_child_changed)


func is_active() -> bool:
	return state == "starting" or state == "running"


## "" or an error. `port` 0 lets the OS pick; `allow_insecure_lan` binds every interface (cleartext, warned in the dock).
func start(port: int, allow_insecure_lan: bool) -> String:
	if is_active():
		return "the preview is already running"
	var profile := str(ProjectSettings.get_setting(SETTING_PROFILE, ""))
	var error := broker.start()
	if error != "":
		return _fail(error)
	session_id = LiveIds.new_id()
	var config := {"session_id": session_id, "broker_port": broker.port(), "broker_credential": broker.credential(),
		"listener_port": port, "listener_bind": "0.0.0.0" if allow_insecure_lan else "127.0.0.1",
		"allow_insecure_lan": allow_insecure_lan, "profile_scene": profile, "blob_root": resolver.blob_root(),
		"project_root": ProjectSettings.globalize_path("res://")}
	error = PreviewSession.write_config(session_id, config)
	if error != "":
		broker.stop()
		return _fail(error)
	_config_path = ProjectSettings.globalize_path(PreviewSession.config_path(session_id))
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(extra_args)
	args.append_array([SCENE, "--", "--wp-config", _config_path])
	last_args = args
	pid = OS.create_process(executable if executable != "" else OS.get_executable_path(), args)
	if pid < 0:
		PreviewSession.remove_session(session_id)
		broker.stop()
		return _fail("the preview process could not be started")
	last_error = ""
	_set_state("starting")
	return ""


func stop() -> void:
	if state == "stopped":
		return
	broker.stop()
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	pid = -1
	if session_id != "":
		PreviewSession.remove_session(session_id)
	_set_state("stopped")


func _process(_delta: float) -> void:
	if not is_active():
		return
	if pid > 0 and not OS.is_process_running(pid):
		last_error = "the preview process ended"
		broker.stop()
		pid = -1
		PreviewSession.remove_session(session_id)
		_set_state("exited")


func _on_child_changed(connected: bool) -> void:
	if connected and state == "starting":
		_set_state("running")


func _set_state(s: String) -> void:
	state = s
	state_changed.emit()


func _fail(message: String) -> String:
	last_error = message
	state_changed.emit()
	return message


func _exit_tree() -> void:
	stop()
