extends RefCounted
## `verify --offline` (ADR 0017 A7): every accepted world's receipt inputs and dependencies are present and unchanged.
## Prints one JSON line; exit code 0 when everything holds, 1 when a problem was found, 2 usage. Headless, no network.


static func run(args: PackedStringArray) -> int:
	var flags: Dictionary = ApplyCliArgs.parse(args).flags
	if not flags.has("offline"):
		print(JSON.stringify({"ok": false, "command": "verify", "error": "usage: verify --offline"}))
		return 2
	var recovered := ApplyTransaction.recover()
	var result := {"ok": false, "problems": ["recovery failed: " + str(recovered.error)]} if not recovered.ok \
			else ApplyVerify.new(ApplyContext.for_project()).verify_all()
	result["command"] = "verify"
	print(JSON.stringify(result))
	return 0 if result.ok else 1
