class_name RenderProfileController
extends RefCounted
## Owner of the explicit Performance / Balanced / Detailed choice (spec §4.1). Profiles change only by
## user request; a request during an operation waits for operation_ended(). The controller takes no
## frame-time input, so slow frames can never switch a profile (PROFILE-02), and nothing persisted is
## read at startup (PREF-12).

signal profile_applied(name: String)
signal pending_changed(name: String)

const APPLIED := "applied"
const PENDING := "pending"
const UNCHANGED := "unchanged"
const UNKNOWN := "unknown"

var _config: RenderConfig
var _active := ""
var _pending := ""
var _generation := 0
var _apply_hook := Callable()


func _init(config: RenderConfig) -> void:
	_config = config


## Called with (name: String, profile: Dictionary) on every apply, startup included.
func set_apply_hook(hook: Callable) -> void:
	_apply_hook = hook


func apply_startup() -> void:
	_set_pending("")
	_apply(RenderConfig.STARTUP_PROFILE)


## Returns {"status": "applied" | "pending" | "unchanged" | "unknown", "name": name}.
func request_profile(name: String, busy: bool) -> Dictionary:
	if not RenderConfig.PROFILE_NAMES.has(name):
		return {"status": UNKNOWN, "name": name}
	if name == _active:
		_set_pending("")
		return {"status": UNCHANGED, "name": name}
	if busy:
		_set_pending(name)
		return {"status": PENDING, "name": name}
	_set_pending("")
	_apply(name)
	return {"status": APPLIED, "name": name}


## An operation finished or was cancelled: applies the waiting profile once.
func operation_ended() -> void:
	if _pending == "":
		return
	var name := _pending
	_set_pending("")
	if name != _active:
		_apply(name)


func active_name() -> String:
	return _active


func active_profile() -> Dictionary:
	return _config.profile(_active)


func pending_name() -> String:
	return _pending


func generation() -> int:
	return _generation


func _set_pending(name: String) -> void:
	if name == _pending:
		return
	_pending = name
	pending_changed.emit(name)


func _apply(name: String) -> void:
	_active = name
	_generation += 1
	if _apply_hook.is_valid():
		_apply_hook.call(name, _config.profile(name))
	profile_applied.emit(name)
