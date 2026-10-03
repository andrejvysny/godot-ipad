class_name UpdateReviewDialog
extends Control
## Review Update (shared spec §7, IP-SPEC §4): moves selected objects of binding B to the exact newer version V2 in
## one history action. Opening stages V2 (resolve + prepare); the dialog lists the differences of the two frozen
## descriptors and any placed scale or height offset outside V2's limits, for which the user must pick an explicit
## alternative (never a silent clamp). Only the user opens it; declining records the target and never opens a
## modal later. It is a modal like ConfirmDialog, so no world input reaches the tools beneath it.

const SCOPE_SELECTED := "selected"
const SCOPE_ALL := "all"
const CHOICES := {"exclude": "Update only objects within limits", "limit": "Set the others to the nearest limit"}

var _session: EditorSession
var _remote: RemoteLibrary
var _title := UiKit.bold_label("Update available", 18)
var _body := UiKit.label("", 11)
var _status := UiKit.label("", 11)
var _scope_row := HBoxContainer.new()
var _scope_buttons: Dictionary = {}
var _choice_row := VBoxContainer.new()
var _choice_buttons: Dictionary = {}
var _apply := UiKit.variant_button("Update", "AccentButton", Callable(), false, 110)
var _decline := UiKit.variant_button("Decline", "SurfaceButton", Callable(), false, 110)
var _close := UiKit.variant_button("Not now", "SurfaceButton", Callable(), false, 110)
var _binding_id := ""
var _new_id := ""
var _scope := SCOPE_SELECTED
var _review: UpdateReview
var _generation := 0


func setup(session: EditorSession) -> void:
	_session = session
	_remote = session.assets().remote
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := UiKit.variant_panel("StrongPanel")
	panel.custom_minimum_size.x = 460
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	_build_body(column)
	_build_buttons(column)
	_remote.prep.prepared.connect(_on_prepared)
	visibility_changed.connect(func() -> void: _session.input.set_modal(is_visible_in_tree()))
	_session.input.ui_hits.register_modal(self)


func _build_body(column: VBoxContainer) -> void:
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size.x = 420
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 420
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(430, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(_body)
	_scope_row.add_theme_constant_override("separation", 6)
	_choice_row.add_theme_constant_override("separation", 4)
	for scope: String in [SCOPE_SELECTED, SCOPE_ALL]:
		var b := UiKit.variant_button("", "ChipButton", _set_scope.bind(scope), true)
		_scope_row.add_child(b)
		_scope_buttons[scope] = b
	for choice: String in CHOICES:
		var b := UiKit.variant_button(str(CHOICES[choice]), "ChipButton", _set_choice.bind(choice), true)
		_choice_row.add_child(b)
		_choice_buttons[choice] = b
	for c: Control in [_title, _scope_row, scroll, _choice_row, _status]:
		column.add_child(c)


func _build_buttons(column: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	for b: Button in [_decline, _close, _apply]:
		row.add_child(b)
	column.add_child(row)
	_apply.pressed.connect(apply)
	_decline.pressed.connect(decline)
	_close.pressed.connect(close)


# --- API -------------------------------------------------------------------------------------

func is_open() -> bool:
	return visible


func apply_button() -> Button:
	return _apply


func decline_button() -> Button:
	return _decline


func close_button() -> Button:
	return _close


func scope_button(scope: String) -> Button:
	return _scope_buttons[scope]


func choice_button(choice: String) -> Button:
	return _choice_buttons[choice]


func status_text() -> String:
	return _status.text


func body_text() -> String:
	return _body.text


func review() -> UpdateReview:
	return _review


func target_binding_id() -> String:
	return _new_id


## Coroutine: opens the review of the update offered for binding `binding_id`. `scope` "" picks the selected
## object when it uses the binding, else every object of the binding. Refused (with the reason posted) during an
## active operation.
func open_for(binding_id: String, scope: String = "") -> String:
	if _session.tools.has_active_operation():
		_session.post_message(ToolModel.BUSY, true)
		return ToolModel.BUSY
	var offer := _remote.updates.offer_for(binding_id)
	var old := _session.document.assets.get_binding(binding_id)
	if offer.is_empty() or old == null:
		_session.post_message("No update is offered for this asset.", true)
		return "No update is offered for this asset."
	_binding_id = binding_id
	_new_id = ""
	_review = null
	_generation += 1
	var gen := _generation
	var selected := _session.tools.selected_record()
	_scope = scope if scope != "" else (SCOPE_SELECTED if selected != null and selected.binding_id == binding_id else SCOPE_ALL)
	_title.text = "Update to %s" % offer.display_version
	_say("Preparing the new version…")
	_render()
	show()
	var ref: Dictionary = old.asset_ref.duplicate()
	ref.version_id = offer.target_version
	var id := await _remote.prep.prepare_ref(ref, _remote.prep.name_of(binding_id))
	if gen == _generation and visible:
		_new_id = id
		_rebuild_review()
	return ""


func _candidates() -> Array:
	var doc := _session.document
	if _scope == SCOPE_SELECTED:
		var rec := _session.tools.selected_record()
		return [rec.object_id] if rec != null and rec.binding_id == _binding_id else []
	var ids: Array = []
	for id: String in doc.sorted_object_ids():
		if doc.get_object(id).binding_id == _binding_id:
			ids.append(id)
	return ids


func _rebuild_review() -> void:
	if _new_id == "":
		_say(_job_error())
	else:
		_review = UpdateReview.build(_session.document, _binding_id, _new_id, _candidates())
	_render()


func _job_error() -> String:
	var old := _session.document.assets.get_binding(_binding_id)
	var offer := _remote.updates.offer_for(_binding_id)
	if old == null or offer.is_empty():
		return "The update is no longer available."
	var key := AssetBinding.Canonical.asset_key(old.asset_ref.server_id, old.asset_ref.library_id, old.asset_ref.asset_id, offer.target_version)
	var st := _remote.prep.state_of({"asset_key": key})
	return "The new version cannot be prepared: %s" % st.error if str(st.error) != "" else "The new version cannot be prepared."


func _on_prepared(binding_id: String, _ok: bool, _error: String) -> void:
	if visible and binding_id == _new_id:
		_render()


func _set_scope(scope: String) -> void:
	_scope = scope
	_rebuild_review()


func _set_choice(choice: String) -> void:
	if _review != null:
		_review.set_choice(choice)
	_render()


func _say(text: String) -> void:
	_status.text = text


## True once V2 is prepared and the review needs nothing more from the user.
func can_apply() -> bool:
	return _review != null and _review.is_valid() and not _review.needs_choice() \
			and _session.document.assets.is_prepared(_new_id) and not _session.tools.has_active_operation()


func _render() -> void:
	var doc := _session.document
	var count_all := 0
	for id: String in doc.sorted_object_ids():
		if doc.get_object(id).binding_id == _binding_id:
			count_all += 1
	(_scope_buttons[SCOPE_SELECTED] as Button).text = "Selected object"
	(_scope_buttons[SCOPE_ALL] as Button).text = "All %d of this version" % count_all
	for scope: String in _scope_buttons:
		(_scope_buttons[scope] as Button).set_pressed_no_signal(scope == _scope)
	_body.text = _review.summary() if _review != null and _review.is_valid() else ""
	_choice_row.visible = _review != null and not _review.conflicts.is_empty()
	for choice: String in _choice_buttons:
		(_choice_buttons[choice] as Button).set_pressed_no_signal(_review != null and _review.choice == choice)
	if _review != null:
		_say(_review_status())
	_apply.disabled = not can_apply()


func _review_status() -> String:
	if not _review.is_valid():
		return "Nothing to update in this scope."
	if not _session.document.assets.is_prepared(_new_id):
		return "Preparing the new version…"
	if _review.needs_choice():
		return "Some objects are outside the new limits: choose what happens to them."
	return "Ready. One undo restores the old version."


## One history action; refused while an operation is active. The other objects of the old version are untouched.
func apply() -> void:
	if not can_apply():
		return
	var plan := _review.plan()
	var err := _session.tools.rebind_objects(plan.ids, _new_id, plan.overrides)
	if err != "":
		_session.post_message(err, true)
		_render()
		return
	_session.post_message("Updated %d object(s)." % (plan.ids as Array).size())
	close()
	_remote.updates.check()


## Declines this exact version: the badge goes away, nothing else changes, nothing opens by itself later.
func decline() -> void:
	_remote.updates.dismiss(_binding_id)
	_session.post_message("Update declined for this version.")
	close()


func close() -> void:
	_generation += 1
	hide()
