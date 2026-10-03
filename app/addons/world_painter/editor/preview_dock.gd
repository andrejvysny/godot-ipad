@tool
class_name PreviewDock
extends VBoxContainer
## The "World Painter" editor dock (ADR 0016 P1): Start/Stop preview, pairing details (LAN addresses, port, token),
## connection and revision/hash/visual-ready status, missing assets, the cleartext warning and "Apply world snapshot"
## (ADR 0017: review, confirm, progress, result, rollback). It talks to the PreviewLauncher, its broker and the
## ApplyController.

const WARNING := "Cleartext LAN mode: anyone on this network can read the pairing token and the world while it is " + \
	"connected. Use it on a trusted network only. TLS is not available in live protocol v1."
const APPLY_HINT := "Freezes the preview's committed revision, shows a review and bakes it into the project. The preview itself never writes project files."
const TOKEN_HINT := "Enter this token in the iPad app (World menu > Desktop preview). It works once and expires in 5 minutes."

var launcher: PreviewLauncher
var controller: ApplyController

var _toggle := Button.new()
var _insecure := CheckBox.new()
var _port := SpinBox.new()
var _state := Label.new()
var _addresses := Label.new()
var _token := LineEdit.new()
var _copy := Button.new()
var _refresh := Button.new()
var _revision := Label.new()
var _visual := Label.new()
var _missing := Label.new()
var _warning := Label.new()
var _apply := Button.new()
var _status: Dictionary = {}
var _review_box := VBoxContainer.new()
var _review_text := Label.new()
var _discard := CheckBox.new()
var _confirm := Button.new()
var _cancel := Button.new()
var _progress := Label.new()
var _result := Label.new()
var _generations := OptionButton.new()
var _rollback := Button.new()


func setup(p_launcher: PreviewLauncher) -> void:
	launcher = p_launcher
	name = "World Painter"
	controller = ApplyController.new()
	controller.name = "ApplyController"
	add_child(controller)
	controller.setup(launcher)
	controller.review_ready.connect(_on_review)
	controller.progress.connect(func(label: String) -> void: _progress.text = label)
	controller.finished.connect(_on_finished)
	controller.failed.connect(_on_failed)
	_build()
	launcher.state_changed.connect(refresh)
	launcher.broker.status_received.connect(func(status: Dictionary) -> void:
		_status = status
		refresh())
	launcher.broker.child_changed.connect(func(_connected: bool) -> void: refresh())
	refresh()


func _build() -> void:
	_toggle.pressed.connect(_on_toggle)
	add_child(_toggle)
	_insecure.text = "Allow insecure LAN (cleartext)"
	add_child(_insecure)
	var port_row := HBoxContainer.new()
	var port_label := Label.new()
	port_label.text = "Port"
	port_row.add_child(port_label)
	_port.min_value = 0
	_port.max_value = 65535
	_port.value = LiveWsTransport.DEFAULT_PORT
	port_row.add_child(_port)
	add_child(port_row)
	for label: Label in [_state, _addresses, _revision, _visual, _missing, _warning]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(label)
	_token.editable = false
	_token.secret = false
	_token.tooltip_text = TOKEN_HINT
	add_child(_token)
	var row := HBoxContainer.new()
	_copy.text = "Copy token"
	_copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(_token.text))
	_refresh.text = "New token"
	_refresh.pressed.connect(func() -> void: launcher.broker.send_to_child({"type": "new_pairing"}))
	row.add_child(_copy)
	row.add_child(_refresh)
	add_child(row)
	_apply.text = "Apply world snapshot"
	_apply.disabled = true
	_apply.tooltip_text = APPLY_HINT
	_apply.pressed.connect(_on_apply)
	add_child(_apply)
	_build_apply_panel()
	_warning.add_theme_color_override("font_color", Color(1.0, 0.55, 0.35))


func _build_apply_panel() -> void:
	_review_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_review_box.add_child(_review_text)
	_discard.text = "Discard modified generated content"
	_discard.toggled.connect(func(_on: bool) -> void: _update_confirm())
	_review_box.add_child(_discard)
	var row := HBoxContainer.new()
	_confirm.text = "Apply"
	_confirm.pressed.connect(_on_confirm)
	_cancel.text = "Cancel"
	_cancel.pressed.connect(_on_cancel)
	row.add_child(_confirm)
	row.add_child(_cancel)
	_review_box.add_child(row)
	_review_box.visible = false
	add_child(_review_box)
	for label: Label in [_progress, _result]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(label)
	var rollback_row := HBoxContainer.new()
	_generations.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_generations.item_selected.connect(func(_i: int) -> void: _update_rollback())
	_rollback.text = "Rollback"
	_rollback.pressed.connect(_on_rollback)
	rollback_row.add_child(_generations)
	rollback_row.add_child(_rollback)
	add_child(rollback_row)
	_populate_generations()


## Why "Apply world snapshot" is unavailable; "" when it is available (replica live and visually ready).
func apply_blocker() -> String:
	var session: Dictionary = _status.get("session", {})
	if not launcher.is_active() or not launcher.broker.child_connected():
		return "Start the preview first."
	if not bool(session.get("writer", false)):
		return "Waiting for the iPad to connect."
	if int(_status.get("revision", -1)) < 0:
		return "No committed world has been received yet."
	if not bool(_status.get("visual_ready", false)):
		return "Assets of the world are still being prepared (visual readiness incomplete)."
	if controller.busy:
		return "An Apply is in progress."
	return ""


func _on_apply() -> void:
	_result.text = ""
	var error := controller.request_freeze()
	if error != "":
		_result.text = error
	refresh()


func _on_review(review: ApplyReview) -> void:
	_review_text.text = "\n".join(review.summary_lines())
	_discard.button_pressed = false
	_discard.visible = not review.soft_blockers.is_empty()
	_review_box.visible = true
	_progress.text = ""
	_update_confirm()
	refresh()


func _update_confirm() -> void:
	_confirm.disabled = controller.review == null or controller.busy or not controller.review.can_apply(_discard.button_pressed)


func _on_confirm() -> void:
	_confirm.disabled = true
	_cancel.disabled = true
	await controller.confirm(_discard.button_pressed)
	_cancel.disabled = false


func _on_cancel() -> void:
	controller.cancel_review()
	_review_box.visible = false
	refresh()


func _on_finished(result: Dictionary) -> void:
	_review_box.visible = false
	_progress.text = ""
	if result.ok:
		var verified := str(result.get("post_verify", ""))
		_result.text = "The accepted world is unchanged." if result.get("unchanged", false) else \
				"Applied generation %s%s" % [str(result.get("dir_name", "")).left(12), "" if verified == "" else " - verification: " + verified]
	else:
		_result.text = "Not applied: " + str(result.error)
	_populate_generations()
	refresh()


func _on_failed(message: String) -> void:
	_review_box.visible = false
	_progress.text = ""
	_result.text = message
	refresh()


## Lists the generations of every accepted world; the active one is marked and cannot be rolled back to.
func _populate_generations() -> void:
	_generations.clear()
	var root := ApplyLayout.abs_of(ApplyLayout.accepted_root())
	var worlds := DirAccess.get_directories_at(root) if DirAccess.dir_exists_absolute(root) else PackedStringArray()
	for world_id in worlds:
		if not ApplyLayout.is_world_id(world_id):
			continue
		for g in controller.generations(world_id):
			_generations.add_item("%s  rev %d  %s%s" % [world_id.left(8), g.revision, str(g.dir_name).left(8), "  (active)" if g.active else ""])
			_generations.set_item_metadata(_generations.item_count - 1, {"world_id": world_id, "dir_name": g.dir_name, "active": g.active})
	_update_rollback()


func _update_rollback() -> void:
	var meta: Variant = _generations.get_selected_metadata() if _generations.item_count > 0 else null
	_rollback.disabled = controller.busy or typeof(meta) != TYPE_DICTIONARY or bool((meta as Dictionary).active)
	_generations.disabled = _generations.item_count == 0


func _on_rollback() -> void:
	var meta: Variant = _generations.get_selected_metadata()
	if typeof(meta) == TYPE_DICTIONARY:
		_result.text = ""
		controller.rollback(str(meta.world_id), str(meta.dir_name), _discard.button_pressed)


func _on_toggle() -> void:
	if launcher.is_active():
		launcher.stop()
	else:
		var error := launcher.start(int(_port.value), _insecure.button_pressed)
		if error != "":
			_state.text = error


## Local IPv4 addresses worth typing into the iPad (no loopback, no link-local).
static func lan_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
			out.append(address)
	return out


func refresh() -> void:
	var active := launcher.is_active()
	_toggle.text = "Stop preview" if active else "Start preview"
	_insecure.disabled = active
	_port.editable = not active
	_state.text = _state_text()
	var listener: Dictionary = _status.get("listener", {})
	var pairing: Dictionary = _status.get("pairing", {})
	var port := int(listener.get("port", 0))
	_addresses.visible = port > 0
	_addresses.text = "Host: %s   Port: %d" % [", ".join(lan_addresses()) if listener.get("allow_insecure_lan", false) \
			else "127.0.0.1 (this machine only; enable insecure LAN for an iPad)", port]
	var token := str(pairing.get("token", ""))
	_token.text = token if token != "" else "(%s)" % str(pairing.get("state", "no token")) if port > 0 else ""
	_token.visible = port > 0
	_copy.disabled = token == ""
	_refresh.disabled = not launcher.broker.child_connected()
	_warning.visible = bool(listener.get("allow_insecure_lan", false)) or (not active and _insecure.button_pressed)
	_warning.text = WARNING
	var blocker := apply_blocker()
	_apply.disabled = blocker != ""
	_apply.tooltip_text = APPLY_HINT if blocker == "" else blocker
	_update_rollback()
	_status_lines()


func _state_text() -> String:
	if launcher.last_error != "" and not launcher.is_active():
		return "Preview: %s" % launcher.last_error
	if not launcher.is_active():
		return "Preview: stopped"
	var session: Dictionary = _status.get("session", {})
	var error := str(session.get("error", ""))
	if launcher.state == "starting":
		return "Preview: starting…"
	if bool(session.get("writer", false)):
		return "Preview: iPad connected" + (" — " + error if error != "" else "")
	return "Preview: waiting for the iPad" + (" — " + error if error != "" else "")


func _status_lines() -> void:
	var revision := int(_status.get("revision", -1))
	var durable := int(_status.get("durable_revision", -1))
	_revision.text = "Committed revision: %s   hash: %s\nDurable revision: %s" % [
		str(revision) if revision >= 0 else "-", str(_status.get("authored_hash", "")).left(16) if revision >= 0 else "-",
		str(durable) if durable >= 0 else "not reported by live protocol v1"]
	var ready := bool(_status.get("visual_ready", false))
	_visual.text = "Visual readiness: %s" % ("ready" if ready and revision >= 0 else "incomplete" if revision >= 0 else "-")
	var rows: Array = _status.get("missing", [])
	var lines := PackedStringArray()
	for row: Dictionary in rows:
		lines.append("%s — %s" % [str(row.binding_id).left(12), str(row.reason)])
	_missing.text = "Missing assets (%d):\n%s" % [rows.size(), "\n".join(lines)] if not rows.is_empty() else ""
	_missing.visible = not rows.is_empty()
