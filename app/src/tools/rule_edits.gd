class_name RuleEdits
extends RefCounted
## Auto-paint rule edits of the world (docs/editor-v2.md §9): a toggle is one history action, a scrub
## (begin/update/end) is one action however many values it passes through. Live values go straight
## to the document and the terrain; end_scrub() commits only when something changed, cancel_scrub()
## restores the captured rules.

const TOGGLE_LABEL := "Toggle rule"
const SCRUB_LABEL := "Edit auto-paint rule"
const KEYS := ["rock_slope_deg", "sand_height_dm"]

var _ctx: ToolContext
var _busy: Callable
var _tx: EditTransaction


func _init(ctx: ToolContext, busy: Callable) -> void:
	_ctx = ctx
	_busy = busy


func is_open() -> bool:
	return _tx != null


## key: "rock" | "sand". Flips the rule's enabled flag.
func toggle(key: String) -> String:
	if key != "rock" and key != "sand":
		return "Unknown rule '%s'." % key
	var err := _open(TOGGLE_LABEL)
	if err != "":
		return err
	var rules := _ctx.document.rules
	if key == "rock":
		rules.rock_enabled = not rules.rock_enabled
	else:
		rules.sand_enabled = not rules.sand_enabled
	_apply()
	end_scrub()
	return ""


func begin_scrub() -> String:
	return _open(SCRUB_LABEL)


## key_value: "rock_slope_deg" | "sand_height_dm"; the value clamps to the world-format range.
func update(key_value: String, value: int) -> String:
	if _tx == null:
		return "No rule edit in progress."
	var rules := _ctx.document.rules
	if key_value == "rock_slope_deg":
		rules.rock_slope_deg = clampi(value, WorldConstants.RULE_ROCK_SLOPE_MIN, WorldConstants.RULE_ROCK_SLOPE_MAX)
	elif key_value == "sand_height_dm":
		rules.sand_height_dm = clampi(value, WorldConstants.RULE_SAND_HEIGHT_DM_MIN, WorldConstants.RULE_SAND_HEIGHT_DM_MAX)
	else:
		return "Unknown rule value '%s'." % key_value
	_apply()
	return ""


func end_scrub() -> void:
	if _tx == null:
		return
	var tx := _tx
	_tx = null
	var change := tx.finish()
	if change != null:
		_ctx.commit.call(change)


func cancel_scrub() -> void:
	if _tx == null:
		return
	var tx := _tx
	_tx = null
	tx.rollback()
	_apply()


func _open(label: String) -> String:
	if _tx != null or (_busy.is_valid() and bool(_busy.call())):
		return ToolModel.BUSY
	var tx := EditTransaction.new()
	tx.begin(_ctx.document, "rules", label)
	if not tx.capture_rules():
		tx.rollback()
		return "Action memory budget exceeded."
	_tx = tx
	return ""


func _apply() -> void:
	if _ctx.terrain != null:
		_ctx.terrain.set_rules(_ctx.document.rules)
