class_name PreviewSession
extends RefCounted
## Private files of one preview session (ADR 0016 P1/P2): `user://world_painter/sessions/<session_id>/` holds the
## child's one-shot config.json and its staging data. The editor writes the config (owner-only), the child reads and
## deletes it, and cleanup is confined to the session directory of a valid 32-hex id under the sessions root.

const SESSIONS_ROOT := "user://world_painter/sessions"
const CONFIG_FILE := "config.json"
const CONFIG_KEYS := ["session_id", "broker_port", "broker_credential", "listener_port", "listener_bind",
	"allow_insecure_lan", "profile_scene", "blob_root", "project_root"]


static func session_dir(session_id: String) -> String:
	return SESSIONS_ROOT.path_join(session_id)


static func config_path(session_id: String) -> String:
	return session_dir(session_id).path_join(CONFIG_FILE)


## "" or an error. The file is created owner-only before the secret is written (best effort off POSIX).
static func write_config(session_id: String, config: Dictionary) -> String:
	if not LiveIds.is_id(session_id):
		return "invalid session id"
	var dir_error := StorageFs.make_dir(session_dir(session_id))
	if dir_error != "":
		return dir_error
	var path := config_path(session_id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot create the preview config"
	f.close()
	FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write the preview config"
	f.store_string(JSON.stringify(config))
	f.close()
	return ""


## Child side: {ok, error, config}. `path` (absolute, from the command line) must be exactly
## <sessions root>/<32 hex>/config.json; the file is deleted as soon as it was read.
static func read_and_delete(path: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(SESSIONS_ROOT)
	var rel := path.trim_prefix(root + "/")
	var parts := rel.split("/")
	if not path.begins_with(root + "/") or parts.size() != 2 or parts[1] != CONFIG_FILE or not LiveIds.is_id(parts[0]):
		return _fail("the config path is not a session config file")
	if not FileAccess.file_exists(path):
		return _fail("the config file does not exist")
	var text := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	var parsed: Variant = JSON.parse_string(text)
	var error := _config_error(parsed, parts[0])
	if error != "":
		return _fail(error)
	return {"ok": true, "error": "", "config": parsed}


static func _config_error(parsed: Variant, session_id: String) -> String:
	if typeof(parsed) != TYPE_DICTIONARY:
		return "the config is not a JSON object"
	var d: Dictionary = parsed
	for k: String in CONFIG_KEYS:
		if not d.has(k):
			return "the config lacks '%s'" % k
	for k: Variant in d:
		if not CONFIG_KEYS.has(k):
			return "the config has an unknown key"
	if d.session_id != session_id or not LiveIds.is_hash(d.broker_credential):
		return "the config identity is invalid"
	var ports_ok := typeof(d.broker_port) in [TYPE_INT, TYPE_FLOAT] and typeof(d.listener_port) in [TYPE_INT, TYPE_FLOAT]
	if not ports_ok or int(d.broker_port) < 1 or int(d.broker_port) > 65535 or int(d.listener_port) < 0 \
			or int(d.listener_port) > 65535:
		return "the config ports are invalid"
	if typeof(d.listener_bind) != TYPE_STRING or typeof(d.allow_insecure_lan) != TYPE_BOOL \
			or typeof(d.profile_scene) != TYPE_STRING or typeof(d.blob_root) != TYPE_STRING \
			or typeof(d.project_root) != TYPE_STRING:
		return "the config has a value of the wrong type"
	return ""


## Removes the session directory (and nothing else). "" or an error.
static func remove_session(session_id: String) -> String:
	if not LiveIds.is_id(session_id):
		return "invalid session id"
	var dir := ProjectSettings.globalize_path(session_dir(session_id))
	var root := ProjectSettings.globalize_path(SESSIONS_ROOT)
	if not dir.begins_with(root + "/") or not DirAccess.dir_exists_absolute(dir):
		return ""
	_remove_tree(dir)
	return ""


static func _remove_tree(dir: String) -> void:
	var parent := DirAccess.open(dir.get_base_dir())
	if parent != null and parent.is_link(dir):
		DirAccess.remove_absolute(dir)  # a link is removed, never followed
		return
	for name in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(name))
	for name in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(name))
	DirAccess.remove_absolute(dir)


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "config": {}}
