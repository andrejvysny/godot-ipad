class_name ApplyCliArgs
extends RefCounted
## Arguments of the headless `bake` and `verify` commands: `--flag`, `--name value` or `--name=value`. Anything
## else (such as the command word itself) is positional and ignored by the commands.

const VALUE_FLAGS := ["world", "generation"]


## {flags: {name: String or true}, positional: PackedStringArray}.
static func parse(args: PackedStringArray) -> Dictionary:
	var flags := {}
	var positional := PackedStringArray()
	var i := 0
	while i < args.size():
		var arg := args[i]
		if not arg.begins_with("--"):
			positional.append(arg)
		elif arg.contains("="):
			flags[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
		elif VALUE_FLAGS.has(arg.trim_prefix("--")) and i + 1 < args.size():
			flags[arg.trim_prefix("--")] = args[i + 1]
			i += 1
		else:
			flags[arg.trim_prefix("--")] = true
		i += 1
	return {"flags": flags, "positional": positional}
