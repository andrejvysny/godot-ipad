class_name UiScreenshot
extends RefCounted
## Visual verification aid. `--ui-screenshot=<abs.png>` saves the window after 2 s and quits;
## `--ui-screenshot-state=<mode>:<tool>[:closed][:select][:ticked][:sets][:editor]` first sets that tool,
## opens its popover (unless `closed`) and, with `select`, selects the first object of the world;
## `ticked` ticks two Library assets, `sets` shows the Sets tab, `editor` opens the "forest" set editor.


static func arm(ui: EditorUI, session: EditorSession) -> void:
	var path := ""
	var state := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-screenshot="):
			path = arg.trim_prefix("--ui-screenshot=")
		elif arg.begins_with("--ui-screenshot-state="):
			state = arg.trim_prefix("--ui-screenshot-state=")
	if path == "":
		return
	if state != "":
		apply_state(ui, session, state)
	ui.get_tree().create_timer(2.0).timeout.connect(func() -> void:
		ui.get_viewport().get_texture().get_image().save_png(path)
		ui.get_tree().quit())


## Returns "" or an error text. The mode part must match the tool's mode.
static func apply_state(ui: EditorUI, session: EditorSession, state: String) -> String:
	var parts := state.split(":")
	if parts.size() < 2:
		return "Expected <mode>:<tool>."
	var err := session.tools.set_tool(parts[1])
	if err == "" and session.tools.mode() != parts[0]:
		err = "Tool '%s' is not in mode '%s'." % [parts[1], parts[0]]
	if err != "":
		session.post_message(err, true)
		return err
	ui.popover().set_open(not parts.has("closed"))
	var ids := session.document.sorted_object_ids()
	if parts.has("select") and not ids.is_empty():
		session.tools.select(ids[0])
	if parts.has("ticked"):
		for id in ["nature.tree.spruce_a", "nature.cover.fern_a"]:
			ui.library().tile(id).tick_button().button_pressed = true
	if parts.has("sets"):
		ui.library().show_tab("sets")
	if parts.has("editor"):
		ui.library().edit_set_requested.emit("forest")
	return ""
