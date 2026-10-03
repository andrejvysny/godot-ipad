extends TestCase
## Editor dock (ADR 0016 P1): pairing details, status lines, the cleartext warning and the disabled Apply button,
## driven by synthetic broker status; and the plugin script itself loads.

var launcher: PreviewLauncher
var dock: PreviewDock


func before_each() -> void:
	launcher = PreviewLauncher.new()
	tree.root.add_child(launcher)
	dock = PreviewDock.new()
	dock.setup(launcher)
	tree.root.add_child(dock)


func after_each() -> void:
	for n: Node in [dock, launcher]:
		tree.root.remove_child(n)
		n.free()


func _status(token: String, insecure: bool, rows: Array) -> Dictionary:
	return PreviewStatus.sanitize({"type": "status", "listener": {"port": 8666, "bind": "0.0.0.0" if insecure else "127.0.0.1",
		"allow_insecure_lan": insecure}, "pairing": {"state": "valid", "token": token, "expires_in_ms": 1000},
		"session": {"writer": true, "paired": true, "overlay": false, "error": ""}, "revision": 12,
		"authored_hash": "ab".repeat(32), "durable_revision": -1, "visual_ready": rows.is_empty(), "missing": rows})


func test_apply_is_disabled_and_stopped_state_is_shown() -> void:
	assert_true((dock.get("_apply") as Button).disabled, "Apply world snapshot is disabled until IP-07")
	assert_eq((dock.get("_toggle") as Button).text, "Start preview")
	assert_true((dock.get("_state") as Label).text.contains("stopped"))


func test_status_shows_pairing_revision_hash_and_missing_assets() -> void:
	var token := LiveIds.new_secret()
	dock.set("_status", _status(token, true, [{"binding_id": "b0123456789abcdef", "reason": "not prepared"}]))
	dock.refresh()
	assert_eq((dock.get("_token") as LineEdit).text, token, "token shown")
	assert_true((dock.get("_addresses") as Label).text.contains("8666"), "port shown")
	assert_true((dock.get("_revision") as Label).text.contains("Committed revision: 12"), "revision")
	assert_true((dock.get("_revision") as Label).text.contains("abababababababab"), "hash prefix")
	assert_true((dock.get("_revision") as Label).text.contains("not reported"), "durable revision is honest about the protocol gap")
	assert_true((dock.get("_visual") as Label).text.contains("incomplete"), "visual readiness")
	assert_true((dock.get("_missing") as Label).text.contains("not prepared"), "missing assets listed")
	assert_true((dock.get("_warning") as Label).visible, "cleartext warning while the listener is on the LAN")


func test_loopback_listener_has_no_cleartext_warning() -> void:
	dock.set("_status", _status("", false, []))
	dock.refresh()
	assert_false((dock.get("_warning") as Label).visible, "no warning on loopback")
	assert_true((dock.get("_visual") as Label).text.contains("ready"), "ready")


func test_lan_addresses_exclude_loopback() -> void:
	for a in PreviewDock.lan_addresses():
		assert_false(a.begins_with("127.") or a.begins_with("169.254."), a)


func test_plugin_script_loads() -> void:
	var script := load("res://addons/world_painter/plugin.gd") as GDScript
	assert_true(script != null and script.can_instantiate(), "plugin.gd compiles")


func test_plugin_registers_the_apply_settings_and_recovery_is_safe_on_a_clean_project() -> void:
	(load("res://addons/world_painter/plugin.gd") as GDScript).call("_register_apply_settings")
	for name: String in [ApplyLayout.SETTING_ROOT, ApplyLayout.SETTING_COLLISION, ApplyLayout.SETTING_MAPPING,
			ApplyLayout.SETTING_TERRAIN_COLLISION]:
		assert_true(ProjectSettings.has_setting(name), name)
	assert_eq(ApplyLayout.accepted_root(), ApplyLayout.DEFAULT_ROOT, "default accepted_world_root")
	assert_true(ApplyTransaction.recover().ok, "recovery with nothing pending succeeds")
	assert_empty_string(ApplyLayout.root_error(ApplyLayout.DEFAULT_ROOT))
	for bad in ["worlds", "res://", "res://../x", "res://.hidden/w", "res://assets/library/w", "res://addons/w", "user://w"]:
		assert_true(ApplyLayout.root_error(bad) != "", "refused: " + bad)
