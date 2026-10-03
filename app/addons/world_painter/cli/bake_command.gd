extends RefCounted
## `bake --locked --world <world_id> [--generation <id>]` (ADR 0017 A7): rebuilds the generated directory of an
## accepted world from its tracked source and the installed locked deliveries; refuses on any hash mismatch. Prints
## one JSON line; exit code 0 ok, 1 refused or failed, 2 usage. Headless, no network.


static func run(args: PackedStringArray) -> int:
	var parsed := ApplyCliArgs.parse(args)
	var flags: Dictionary = parsed.flags
	if not flags.has("locked") or typeof(flags.get("world")) != TYPE_STRING or not ApplyLayout.is_world_id(flags.world):
		return _print({"ok": false, "command": "bake", "error": "usage: bake --locked --world <world_id> [--generation <id>]"}, 2)
	var generation := str(flags.get("generation", ""))
	if generation != "" and not ApplyLayout.is_generation_dir_name(generation.left(32)):
		return _print({"ok": false, "command": "bake", "error": "--generation must be a generation id (32 or 64 hex digits)"}, 2)
	var recovered := ApplyTransaction.recover()
	if not recovered.ok:
		return _print({"ok": false, "command": "bake", "error": "recovery failed: " + str(recovered.error)}, 1)
	var result := LockedBake.new(ApplyContext.for_project()).bake(flags.world, generation.left(32))
	result["command"] = "bake"
	result["world_id"] = flags.world
	return _print(result, 0 if result.ok else 1)


static func _print(result: Dictionary, code: int) -> int:
	print(JSON.stringify(result))
	return code
