class_name PreviewPanel
extends PanelContainer
## Settings, pairing and status of the desktop preview link (ADR 0016 P5). Host, port and the insecure-LAN switch
## persist device-locally; the pairing token is typed per pairing, kept only in the field until Connect and cleared
## afterwards. A persistent warning shows while cleartext LAN mode is on or connected to a non-loopback host.

const WIDTH := 380.0
const WARNING := "Cleartext LAN: the pairing token and the world cross this network unencrypted. Use a network you trust."
const STATE_NAMES := {LivePeerSocket.State.IDLE: "Not connected", LivePeerSocket.State.CONNECTING: "Connecting",
	LivePeerSocket.State.AUTHENTICATING: "Pairing", LivePeerSocket.State.READY: "Connected",
	LivePeerSocket.State.BACKOFF: "Reconnecting", LivePeerSocket.State.REJECTED: "Pairing refused"}

var _link: PreviewLink
var _settings: PreviewSettings
var _settings_path := PreviewSettings.PATH
var _host := LineEdit.new()
var _port := LineEdit.new()
var _token := LineEdit.new()
var _insecure := UiKit.switch_button("Allow insecure LAN", Callable())
var _warning := UiKit.label(WARNING, 12)
var _status := UiKit.label("", 13)
var _detail := UiKit.label("", 11)
var _connect := UiKit.variant_button("Connect", "AccentButton", Callable())
var _disconnect := UiKit.button("Disconnect", Callable())
var _forget := UiKit.button("Forget pairing", Callable())
var _error := ""


func setup(link: PreviewLink, settings: PreviewSettings, settings_path: String = PreviewSettings.PATH) -> void:
	_link = link
	_settings = settings
	_settings_path = settings_path
	add_theme_stylebox_override("panel", UiKit.pill_box(Color(UiKit.PANEL_BG, 0.96), 12, 12))
	custom_minimum_size.x = WIDTH
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	column.add_child(UiKit.bold_label("Desktop preview", 15))
	_field(column, "Host", _host, "192.168.1.20", settings.host)
	_field(column, "Port", _port, str(LiveWsTransport.DEFAULT_PORT), str(settings.port))
	_field(column, "Pairing token", _token, "64 hex characters from the editor dock", "")
	_token.secret = true
	column.add_child(_insecure)
	UiKit.set_switch(_insecure, settings.allow_insecure_lan)
	_insecure.toggled.connect(_on_insecure)
	_warning.add_theme_color_override("font_color", UiKit.WARN_TEXT)
	_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_warning)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for b: Button in [_connect, _disconnect, _forget]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	column.add_child(row)
	_connect.pressed.connect(_on_connect)
	_disconnect.pressed.connect(func() -> void: _link.disconnect_link(false))
	_forget.pressed.connect(func() -> void: _link.disconnect_link(true))
	for l: Label in [_status, _detail]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(l)
	_detail.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
	visible = false
	refresh()


func _field(parent: Control, caption: String, edit: LineEdit, placeholder: String, value: String) -> void:
	var box := VBoxContainer.new()
	box.add_child(UiKit.label(caption, 11))
	edit.placeholder_text = placeholder
	edit.text = value
	edit.custom_minimum_size.y = UiKit.MIN_HEIGHT
	box.add_child(edit)
	parent.add_child(box)


func _on_insecure(on: bool) -> void:
	_settings.allow_insecure_lan = on
	_settings.save(_settings_path)
	refresh()


func _on_connect() -> void:
	_settings.host = _host.text.strip_edges()
	_settings.port = int(_port.text) if _port.text.is_valid_int() else 0
	_error = _link.connect_to(_settings.host, _settings.port, _settings.allow_insecure_lan, _token.text)
	if _error == "":
		_token.text = ""
		_settings.save(_settings_path)
	refresh()


## Local connect status for tests and the periodic refresh: the text shown in the status line.
func status_text() -> String:
	if _error != "":
		return _error
	var s := _link.status()
	return "%s: %s" % [STATE_NAMES.get(s.state, "?"), s.text] if str(s.text) != "" else str(STATE_NAMES.get(s.state, "?"))


func refresh() -> void:
	if _link == null:
		return
	var s := _link.status()
	_status.text = status_text()
	var detail := PackedStringArray()
	if bool(s.ready):
		detail.append("revision %d, desktop confirmed %d" % [int(s.revision), int(s.acked_revision)])
		detail.append("visual %s" % ("ready" if bool(s.visual_ready) else "incomplete (assets missing on the desktop)"))
		if float(s.rtt_msec) >= 0.0:
			detail.append("round trip %.0f ms" % float(s.rtt_msec))
		if bool(s.unresponsive):
			detail.append("desktop not answering")
	if str(s.last_error) != "":
		detail.append(str(s.last_error))
	_detail.text = "\n".join(detail)
	var cleartext := _settings.allow_insecure_lan and not LiveWsTransport.is_loopback(_host.text.strip_edges())
	_warning.visible = cleartext
	_connect.disabled = bool(s.ready)
	_disconnect.disabled = int(s.state) == LivePeerSocket.State.IDLE
	_forget.disabled = not _link.socket.has_credential()


func _process(_delta: float) -> void:
	if visible and Engine.get_process_frames() % 15 == 0:
		refresh()
