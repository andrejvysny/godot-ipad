extends SceneTree
## Headless test runner: godot --headless --path app --script res://tests/run_tests.gd -- [--suite=unit|integration] [--filter=text]
## Discovers tests/<suite>/test_*.gd, runs every `test_*` method (awaiting coroutines), and exits
## nonzero on any failure. scripts/dev.py wraps this with a hard timeout because a script error
## outside a test would otherwise leave Godot running forever.

const SUITES := ["unit", "integration"]


class ErrorCounter extends Logger:
	var count := 0
	var last := ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		count += 1
		last = "%s (%s:%d %s)" % [rationale if rationale != "" else code, file, line, function]

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Test user directory: " + OS.get_user_data_dir())
	var args := _parse_args()
	var counter := ErrorCounter.new()
	OS.add_logger(counter)
	var suites: Array = SUITES if args.suite == "" else [args.suite]
	var total := 0
	var failed: PackedStringArray = []
	var started := Time.get_ticks_msec()
	for suite in suites:
		for path in _discover("res://tests/%s" % suite):
			var script: GDScript = load(path)
			if script == null or not script.can_instantiate():
				failed.append("%s: failed to load (parse error?)" % path)
				continue
			for method in _test_methods(script):
				var full := "%s::%s" % [path.get_file().get_basename(), method]
				if args.filter != "" and not full.contains(args.filter):
					continue
				total += 1
				var tc: TestCase = script.new()
				tc.tree = self
				tc.current_test = full
				var errors_before := counter.count
				var t0 := Time.get_ticks_usec()
				tc.before_each()
				await tc.call(method)
				tc.after_each()
				var ms := (Time.get_ticks_usec() - t0) / 1000.0
				if counter.count > errors_before and not tc.allow_errors:
					tc.failures.append("%s: engine/script error logged: %s" % [full, counter.last])
				if tc.failures.is_empty():
					print("  PASS %s (%.1f ms)" % [full, ms])
				else:
					print("  FAIL %s" % full)
					for f in tc.failures:
						print("       " + f)
					failed.append_array(tc.failures)
				_remove_tree("user://test_scratch")
	var secs := (Time.get_ticks_msec() - started) / 1000.0
	print("\n%d tests, %d failures (%.1f s)" % [total, failed.size(), secs])
	if total == 0:
		print("ERROR: no tests matched")
		quit(2)
		return
	quit(1 if failed.size() > 0 else 0)


func _parse_args() -> Dictionary:
	var out := {"suite": "", "filter": ""}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--suite="):
			out.suite = a.substr(8)
		elif a.begins_with("--filter="):
			out.filter = a.substr(9)
	return out


func _discover(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	out.sort()
	return out


func _test_methods(script: GDScript) -> PackedStringArray:
	var out := PackedStringArray()
	for m in script.get_script_method_list():
		if String(m.name).begins_with("test_") and not out.has(m.name):
			out.append(m.name)
	out.sort()
	return out


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
