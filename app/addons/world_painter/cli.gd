extends SceneTree
## Headless command dispatcher for consumer projects (ADR 0017, IP spec §10):
##   godot --headless --path P --script res://addons/world_painter/cli.gd -- <command> [args]
## Commands: validate, migrate, bake, verify. Each cli/<name>_command.gd is `extends RefCounted` with
## `static func run(args: PackedStringArray) -> int` and prints one JSON line. Exit: 0 ok, 1 failed check, 2 usage/IO.

const COMMANDS := {
	"validate": "res://addons/world_painter/cli/validate_command.gd",
	"migrate": "res://addons/world_painter/cli/migrate_command.gd",
	"bake": "res://addons/world_painter/cli/bake_command.gd",
	"verify": "res://addons/world_painter/cli/verify_command.gd",
}


func _initialize() -> void:
	quit(_dispatch(OS.get_cmdline_user_args()))


static func _dispatch(argv: PackedStringArray) -> int:
	if argv.is_empty() or not COMMANDS.has(argv[0]):
		return _fail("usage: cli.gd -- <%s> [args]" % "|".join(COMMANDS.keys()))
	var path: String = COMMANDS[argv[0]]
	if not ResourceLoader.exists(path):
		return _fail("command '%s' is not installed in this addon version" % argv[0])
	var script := load(path) as GDScript
	if script == null or not script.has_method("run"):
		return _fail("command '%s' has no run()" % argv[0])
	return int(script.call("run", argv.slice(1)))


static func _fail(message: String) -> int:
	print(JSON.stringify({"ok": false, "errors": [message]}, "", true))
	return 2
