extends Node
## Loads the world named by `--world=<generation dir|.worldpoc>` through the addon's WorldLoader against the
## bundled catalog (res://assets) and prints one `MINIMAL_CONSUMER <json>` line. Exit 0 loaded, 1 rejected.
## Uses only addons/world_painter classes; nothing here references an application src/ tree.

const REPORT_PREFIX := "MINIMAL_CONSUMER "


func _ready() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--world="):
			path = arg.trim_prefix("--world=")
	get_tree().quit(_load(path))


func _load(path: String) -> int:
	var loaded := AssetCatalog.load_from()
	if loaded[1] != "":
		return _report({"ok": false, "error": loaded[1]}, 1)
	var catalog: AssetCatalog = loaded[0]
	var result := WorldLoader.load_world(path, catalog)
	if result[1] != "":
		return _report({"ok": false, "error": result[1]}, 1)
	var report := WorldLoader.report(result[0], catalog)
	report["ok"] = true
	return _report(report, 0)


func _report(data: Dictionary, code: int) -> int:
	print(REPORT_PREFIX + JSON.stringify(data, "", true))
	return code
