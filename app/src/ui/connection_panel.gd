class_name ConnectionPanel
extends VBoxContainer
## The AssetStudio connection of this device (IP-SPEC §2, §4): server URL, the expected server id (checked against
## the server's own answer), the access token and the cleartext-LAN switch with its persistent warning. Everything
## is stored through AssetStudioConnection (credentials in their own file, never shown again, never logged); the
## panel never reads a token back.

var _session: EditorSession
var _url := LineEdit.new()
var _server_id := LineEdit.new()
var _token := LineEdit.new()
var _insecure: Button
var _warning := UiKit.label("", 10)
var _result := UiKit.label("", 10)
var _connect := UiKit.variant_button("Connect and check", "AccentButton", Callable())
var _remove := UiKit.variant_button("Remove", "SurfaceButton", Callable())


func setup(session: EditorSession, width: float) -> void:
	_session = session
	add_theme_constant_override("separation", 6)
	var hint := UiKit.label("Connect to an AssetStudio server to browse its libraries.", 10)
	_fit_text(hint, width, UiKit.TEXT_MUTED)
	add_child(hint)
	_field(_url, "https://host:8192", width)
	_field(_server_id, "Server id (UUID of the server)", width)
	_field(_token, "Access token", width)
	_token.secret = true
	_insecure = UiKit.switch_button("Allow cleartext on a trusted LAN", func(_on: bool) -> void: _refresh_warning())
	_insecure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_insecure)
	_fit_text(_warning, width, UiKit.WARN_TEXT)
	_fit_text(_result, width, UiKit.TEXT_SECONDARY)
	add_child(_warning)
	add_child(_result)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for b: Button in [_connect, _remove]:
		b.custom_minimum_size.y = 36
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 11)
		row.add_child(b)
	_connect.pressed.connect(connect_server)
	_remove.pressed.connect(remove_server)
	add_child(row)
	_url.text_changed.connect(func(_t: String) -> void: _refresh_warning())
	load_stored()


func _field(edit: LineEdit, placeholder: String, width: float) -> void:
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(width - 24.0, 34)
	edit.add_theme_font_size_override("font_size", 11)
	add_child(edit)


static func _fit_text(l: Label, width: float, color: Color) -> void:
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = width - 24.0
	l.add_theme_color_override("font_color", color)


## Shows the stored endpoint (never the token) so it can be changed or removed.
func load_stored() -> void:
	var conn := _session.assets().connection
	var ids := conn.server_ids()
	if ids.is_empty():
		_refresh_warning()
		return
	var info: RefCounted = conn.registry.call("get_connection", ids[0])
	if info.get("ok"):
		_url.text = str((info.get("value") as Dictionary).base_url)
		UiKit.set_switch(_insecure, bool((info.get("value") as Dictionary).allow_insecure_lan))
	_server_id.text = ids[0]
	_token.placeholder_text = "Token saved on this device" if conn.registry.call("has_credential", ids[0]) else "Access token"
	_refresh_warning()


## The visible cleartext warning: for the stored server, or for what is being typed.
func warning_text() -> String:
	return _warning.text


func _refresh_warning() -> void:
	var lines := _session.assets().connection.warnings()
	var typed := _url.text.strip_edges().to_lower()
	if lines.is_empty() and typed.begins_with("http://") and _insecure.button_pressed:
		var host := typed.trim_prefix("http://").get_slice("/", 0).get_slice(":", 0)
		if not AssetStudioConnection.Registry.is_loopback_host(host):
			lines.append(AssetStudioConnection.INSECURE_WARNING % host)
	_warning.text = "\n".join(lines)
	_warning.visible = not lines.is_empty()


func result_text() -> String:
	return _result.text


func url_edit() -> LineEdit:
	return _url


func server_id_edit() -> LineEdit:
	return _server_id


func token_edit() -> LineEdit:
	return _token


func insecure_switch() -> Button:
	return _insecure


func connect_button() -> Button:
	return _connect


func remove_button() -> Button:
	return _remove


func _say(text: String, is_error: bool = false) -> void:
	_result.text = text
	_result.add_theme_color_override("font_color", UiKit.DANGER_TEXT if is_error else UiKit.TEXT_SECONDARY)


## Coroutine: stores the endpoint and token, rebuilds the clients and checks the server's identity.
func connect_server() -> void:
	var sid := _server_id.text.strip_edges().to_lower()
	var err := _session.assets().connection.configure(sid, _url.text.strip_edges(), _token.text.strip_edges(),
			_insecure.button_pressed)
	if err != "":
		_say(err, true)
		return
	_token.text = ""
	_say("Checking the server…")
	await _session.assets().reconnect()
	var client := _session.assets().connection.client_for(sid)
	var r: RefCounted = await client.call("capabilities")
	if r.get("ok"):
		_say("Connected. %d granted library(ies)." % _session.assets().remote.libraries().size())
	elif str(r.get("code")) == "server_identity_mismatch":
		_say("This address belongs to a different server than the id you entered.", true)
	else:
		_say(str(r.call("describe")), true)
	load_stored()


func remove_server() -> void:
	var conn := _session.assets().connection
	for id in conn.server_ids():
		conn.remove(id)
	_url.text = ""
	_server_id.text = ""
	_say("Connection removed.")
	await _session.assets().reconnect()
	load_stored()
