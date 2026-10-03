class_name RemoteTile
extends LibraryTile
## One AssetStudio asset of the Library (docs/editor-v2.md §9, IP-SPEC §4): the exact version the server lists as
## current, with its readiness. Only a prepared (downloaded and verified) tile can be dragged or armed; a tap or the
## action button on an unready tile prepares it, and finishing a download never places anything or changes the
## tool. The drag and tap contact rules (Pencil only, root-viewport positions) are LibraryTile's.

signal update_requested(binding_id: String)

const ACTIONS := {"remote": "Download", "downloading": "Cancel", "failed": "Retry"}
const REASON_CHARS := 56

var item: Dictionary

var _remote: RemoteLibrary
var _state: Dictionary = {}
var _thumb: TextureRect
var _note := UiKit.label("", 9)
var _action: Button
var _update: Button


func setup_remote(session: EditorSession, p_item: Dictionary) -> void:
	_session = session
	item = p_item
	asset_id = str(item.asset_key)
	_remote = session.assets().remote
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cell := LibraryTile.build_thumb(_remote.thumbs.texture(asset_id))
	_thumb = cell.get_child(1).get_child(0) as TextureRect
	column.add_child(cell)
	var title := UiKit.bold_label(str(item.name), 11)
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(title)
	for l: Label in [_meta, _note]:
		l.add_theme_color_override("font_color", UiKit.TEXT_MUTED)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(l)
	_note.add_theme_color_override("font_color", UiKit.WARN_TEXT)
	_action = _button("", _on_action)
	_update = _button("Review update", func() -> void: update_requested.emit(update_binding()))
	column.add_child(_action)
	column.add_child(_update)
	add_child(column)
	refresh_state()
	_apply_style()


func _button(text: String, handler: Callable) -> Button:
	var b := UiKit.variant_button(text, "SurfaceButton", handler)
	b.custom_minimum_size.y = 32
	b.add_theme_font_size_override("font_size", 10)
	return b


func readiness() -> Dictionary:
	return _state.duplicate()


## Binding id of the world binding of this asset that the server has a newer version for ("" when none).
func update_binding() -> String:
	var ids := _remote.updates.bindings_for_asset(str(item.server_id), str(item.library_id), str(item.asset_id))
	return ids[0] if not ids.is_empty() else ""


func action_button() -> Button:
	return _action


func update_button() -> Button:
	return _update


func note_text() -> String:
	return _note.text


## Re-reads the readiness, thumbnail and update offer; called whenever the remote model changed.
func refresh_state() -> void:
	_state = _remote.prep.state_of(item)
	var st := str(_state.state)
	_prepared = st == RemotePrep.READY
	var texture := _remote.thumbs.texture(asset_id)
	if texture != null:
		_thumb.texture = texture
	_meta.text = _status_text(st)
	var notes := PackedStringArray(_state.disclosures)
	_note.text = "; ".join(notes)
	_note.visible = not notes.is_empty()
	tooltip_text = str(_state.error) if str(_state.error) != "" else _note.text
	_action.visible = ACTIONS.has(st)
	_action.text = str(ACTIONS.get(st, ""))
	_update.visible = update_binding() != ""
	set_enabled(_enabled)


func _status_text(st: String) -> String:
	match st:
		RemotePrep.DOWNLOADING:
			return "Downloading %d%%" % roundi(float(_state.progress) * 100.0)
		RemotePrep.READY:
			return "Ready"
		RemotePrep.OVER_BUDGET:
			return "Over budget: %s" % _short(str(_state.error))
		RemotePrep.FAILED:
			return "Failed: %s" % _short(str(_state.error))
	return "Remote"


static func _short(text: String) -> String:
	return text if text.length() <= REASON_CHARS else text.left(REASON_CHARS - 1) + "…"


func set_enabled(on: bool) -> void:
	_enabled = on
	modulate.a = 1.0 if on and _prepared else 0.7


func _can_press() -> bool:
	return true  # an unready tile can still be tapped (downloads it)


func _can_drag() -> bool:
	return _prepared


func _selection() -> Variant:
	return LibrarySelection.remote(str(_state.binding_id))


func _on_action() -> void:
	match str(_state.state):
		RemotePrep.DOWNLOADING:
			_remote.prep.cancel_item(item)
		RemotePrep.REMOTE, RemotePrep.FAILED:
			_remote.prep.prepare_item(item)


## Ready: arms (a second tap disarms). Not ready: starts the download. Neither changes the tool.
func _tap() -> void:
	var st := str(_state.state)
	if st == RemotePrep.READY:
		var id := str(_state.binding_id)
		if _session.tools.armed_asset() == id:
			_session.tools.disarm()
			return
		var error := _session.tools.arm_asset(_selection())
		_session.post_message(error if error != "" else "Tap the terrain to place %s" % item.name, error != "")
	elif st == RemotePrep.REMOTE or st == RemotePrep.FAILED:
		_session.post_message("Downloading %s" % item.name)
		_remote.prep.prepare_item(item)
	elif st == RemotePrep.OVER_BUDGET:
		_session.post_message(str(_state.error), true)
