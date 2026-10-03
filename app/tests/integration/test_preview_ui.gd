extends UiTestCase
## iPad side of the desktop preview (ADR 0016 P5): the world-menu entry, the settings panel, device-local settings
## without secrets, the cleartext warning and a real pairing of an EditorSession with a loopback listener.

var listener: LiveListener
var driver: LiveReceiverDriver


func before_each() -> void:
	super.before_each()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PreviewSettings.PATH))


func after_each() -> void:
	if listener != null:
		listener.stop()
		for n: Node in [driver, listener]:
			tree.root.remove_child(n)
			n.free()
		listener = null
	super.after_each()


func _panel(s: EditorSession) -> PreviewPanel:
	var host: SessionPreview = s.get("_preview")
	return host.panel if host != null else null


func _open(s: EditorSession) -> PreviewPanel:
	var ui := _ui(s)
	ui.world_menu().item("preview").pressed.emit()
	await _frames(2)
	return _panel(s)


func _field(panel: PreviewPanel, name: String) -> LineEdit:
	return panel.get(name) as LineEdit


func test_world_menu_entry_opens_and_closes_the_panel() -> void:
	var s := await _start()
	assert_true(_panel(s) == null, "nothing exists before the first use")
	var panel := await _open(s)
	assert_true(panel != null and panel.visible, "panel opens")
	assert_false(_ui(s).world_menu().visible, "the menu closes")
	_ui(s).world_menu().item("preview").pressed.emit()
	assert_false(panel.visible, "second press hides it")


func test_invalid_input_is_reported_and_no_secret_is_stored() -> void:
	var s := await _start()
	var panel := await _open(s)
	_field(panel, "_host").text = "192.168.1.20"
	_field(panel, "_token").text = "not-a-token"
	panel.get("_connect").pressed.emit()
	assert_error_contains(panel.status_text(), "64 lowercase hex", "token format")
	_field(panel, "_token").text = LiveIds.new_secret()
	panel.get("_connect").pressed.emit()
	assert_error_contains(panel.status_text(), "insecure", "cleartext to a LAN host needs the switch")
	var saved := FileAccess.get_file_as_string(PreviewSettings.PATH) if FileAccess.file_exists(PreviewSettings.PATH) else ""
	assert_false(saved.contains("token") or saved.contains("credential"), "no secret in the settings file")


func test_insecure_switch_persists_and_shows_the_warning() -> void:
	var s := await _start()
	var panel := await _open(s)
	_field(panel, "_host").text = "192.168.1.20"
	assert_false((panel.get("_warning") as Label).visible, "no warning while off")
	(panel.get("_insecure") as Button).button_pressed = true
	await _frames(1)
	assert_true((panel.get("_warning") as Label).visible, "persistent warning while on")
	var settings := PreviewSettings.load_from()
	assert_true(settings.allow_insecure_lan, "persisted device-locally")
	assert_eq(settings.port, LiveWsTransport.DEFAULT_PORT, "default port")


func test_settings_round_trip_and_reject_foreign_keys() -> void:
	var path := scratch_dir() + "/preview.json"
	var s := PreviewSettings.new()
	s.host = "10.0.0.5"
	s.port = 9000
	s.allow_insecure_lan = true
	assert_empty_string(s.save(path), "save")
	var loaded := PreviewSettings.load_from(path)
	assert_eq([loaded.host, loaded.port, loaded.allow_insecure_lan], ["10.0.0.5", 9000, true], "values")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"host": "x", "port": 1, "allow_insecure_lan": false, "pairing_token": "abc"}))
	f.close()
	assert_eq(PreviewSettings.load_from(path).host, "", "unknown keys fall back to defaults")


func test_session_pairs_with_a_loopback_listener_and_follows_commits() -> void:
	var s := await _start()
	var panel := await _open(s)
	listener = LiveListener.new()
	tree.root.add_child(listener)
	assert_empty_string(listener.listen(0), "listen")
	driver = LiveReceiverDriver.new()
	tree.root.add_child(driver)
	driver.setup(listener, s.catalog, scratch_dir() + "/receiver")
	_field(panel, "_host").text = "127.0.0.1"
	_field(panel, "_port").text = str(listener.port())
	_field(panel, "_token").text = str(listener.pairing_info().token)
	panel.get("_connect").pressed.emit()
	assert_eq(_field(panel, "_token").text, "", "the token leaves the field after Connect")
	var host: SessionPreview = s.get("_preview")
	var ok := false
	for i in 600:
		await tree.process_frame
		if host.link.sender.baseline_acked():
			ok = true
			break
	assert_true(ok, "the session's world reached the receiver: " + panel.status_text())
	assert_eq(driver.replica.authored_hash(), s.authored_hash(), "snapshot equals the editor's authored hash")
	assert_true(panel.status_text().begins_with("Connected"), panel.status_text())
