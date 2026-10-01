class_name ConfirmDialog
extends Control
## Modal confirmation: a full-rect dim layer plus a centred panel. Registered as an input modal
## once; visibility alone decides whether world input is blocked (UiHitTester) and the router is
## told via set_modal so an active tool operation cannot continue underneath.

var _session: EditorSession
var _title := UiKit.label("", 20)
var _body := UiKit.label("")
var _confirm := UiKit.button("Open", Callable(), false, 120)
var _cancel := UiKit.button("Cancel", Callable(), false, 120)
var _on_confirm := Callable()


func setup(session: EditorSession) -> void:
	_session = session
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
	var panel := UiKit.panel()
	panel.custom_minimum_size.x = 420
	center.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size.x = 400
	column.add_child(_title)
	column.add_child(_body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(row)
	row.add_child(_cancel)
	row.add_child(_confirm)
	_cancel.pressed.connect(_close)
	_confirm.pressed.connect(_accept)
	visibility_changed.connect(func() -> void: _session.input.set_modal(is_visible_in_tree()))
	_session.input.ui_hits.register_modal(self)


func confirm_button() -> Button:
	return _confirm


func cancel_button() -> Button:
	return _cancel


func ask(title: String, body: String, confirm_text: String, on_confirm: Callable) -> void:
	_title.text = title
	_body.text = body
	_confirm.text = confirm_text
	_on_confirm = on_confirm
	show()


func _close() -> void:
	_on_confirm = Callable()
	hide()


func _accept() -> void:
	var action := _on_confirm
	_close()
	if action.is_valid():
		action.call()
