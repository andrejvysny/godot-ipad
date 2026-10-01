class_name RulesSection
extends VBoxContainer
## Auto-paint rules of the tool popover (docs/editor-v2.md §9): a switch, colour square and scrub per
## rule plus the view-only "Highlight rule areas" switch. A toggle or a scrub is one history action
## (RuleEdits); ui_cancelled rolls an open scrub back.

const ROW_HEIGHT := 32.0
const RULES := {
	"rock": {"caption": "Rock above", "key": "rock_slope_deg", "min": 10.0, "max": 60.0, "step": 1.0, "scale": 1.0, "color": 2},
	"sand": {"caption": "Sand below", "key": "sand_height_dm", "min": -3.0, "max": 3.0, "step": 0.1, "scale": 10.0, "color": 3},
}

var _session: EditorSession
var _switches: Dictionary = {}  # rule -> Button
var _fields: Dictionary = {}  # rule -> ScrubField
var _highlight: Button
var _open_rule := ""


func setup(session: EditorSession) -> void:
	_session = session
	add_theme_constant_override("separation", 6)
	add_child(UiKit.separator_h())
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(UiKit.texture_rect(UiKit.tool_icon("autoshader"), Vector2(14, 14)))
	head.add_child(UiKit.bold_label("Auto-paint rules", 11))
	head.add_child(UiKit.bold_label("live, under manual paint", 10, UiKit.TEXT_MUTED))
	add_child(head)
	for rule: String in RULES:
		_build_row(rule)
	_highlight = UiKit.switch_button("Highlight rule areas", _on_highlight, true)
	_highlight.custom_minimum_size.y = ROW_HEIGHT
	add_child(_highlight)


func _build_row(rule: String) -> void:
	var spec: Dictionary = RULES[rule]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var sw := UiKit.switch_button("", func(_on: bool) -> void: _on_toggle(rule))
	sw.custom_minimum_size = Vector2(46, ROW_HEIGHT)
	var square := ColorRect.new()
	square.color = ToolTexts.LAYER_COLORS[int(spec.color)]
	square.custom_minimum_size = Vector2(12, 12)
	square.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var field := ScrubField.new()
	field.custom_minimum_size.y = ROW_HEIGHT
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.fill_alpha = 0.16
	field.caption = str(spec.caption)
	field.min_value = float(spec.min)
	field.max_value = float(spec.max)
	field.step = float(spec.step)
	field.formatter = _format.bind(rule)
	field.drag_started.connect(_on_drag_started.bind(rule))
	field.value_changed.connect(_on_value.bind(rule))
	field.drag_ended.connect(func(_changed: bool) -> void: _end_scrub())
	for c: Control in [sw, square, field]:
		row.add_child(c)
	add_child(row)
	_switches[rule] = sw
	_fields[rule] = field


static func _format(value: float, rule: String) -> String:
	return "%d°" % roundi(value) if rule == "rock" else "%.1f m" % value


func _on_toggle(rule: String) -> void:
	var err := _session.tools.rule_edits().toggle(rule)
	if err != "":
		_session.post_message(err, true)
	refresh()


func _on_drag_started(rule: String) -> void:
	var err := _session.tools.rule_edits().begin_scrub()
	if err != "":
		_session.post_message(err, true)
		return
	_open_rule = rule


func _on_value(value: float, rule: String) -> void:
	if _open_rule != rule:
		return
	var spec: Dictionary = RULES[rule]
	_session.tools.rule_edits().update(str(spec.key), roundi(value * float(spec.scale)))


func _end_scrub() -> void:
	_open_rule = ""
	_session.tools.rule_edits().end_scrub()
	refresh()


func _on_highlight(on: bool) -> void:
	_session.terrain.set_rule_highlight(on)


## Rolls back an open scrub (ui_cancelled); the synthetic release that follows is a no-op.
func on_ui_cancelled() -> void:
	_open_rule = ""
	_session.tools.rule_edits().cancel_scrub()
	refresh()


func switch_button(rule: String) -> Button:
	return _switches[rule]


func scrub(rule: String) -> ScrubField:
	return _fields[rule]


func highlight_switch() -> Button:
	return _highlight


func refresh() -> void:
	var rules := _session.document.rules
	UiKit.set_switch(_switches.rock, rules.rock_enabled)
	UiKit.set_switch(_switches.sand, rules.sand_enabled)
	(_fields.rock as ScrubField).set_value_no_signal(float(rules.rock_slope_deg))
	(_fields.sand as ScrubField).set_value_no_signal(rules.sand_height_dm / 10.0)
	UiKit.set_switch(_highlight, _session.terrain.get_rule_highlight())
