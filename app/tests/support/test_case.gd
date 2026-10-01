class_name TestCase
extends RefCounted
## Minimal assertion base used by tests/run_tests.gd. Failures are collected, not thrown.
## Any engine/script error logged while a test runs also fails it, unless the test calls
## allow_logged_errors() first (for tests that deliberately trigger engine errors).

var tree: SceneTree
var current_test := ""
var failures: PackedStringArray = []
var allow_errors := false


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func allow_logged_errors() -> void:
	allow_errors = true


func fail(msg: String) -> void:
	failures.append("%s: %s" % [current_test, msg])


func assert_true(cond: bool, msg: String = "expected true") -> bool:
	if not cond:
		fail(msg)
	return cond


func assert_false(cond: bool, msg: String = "expected false") -> bool:
	return assert_true(not cond, msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> bool:
	var same: bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		fail("%s expected <%s> got <%s>" % [msg, _short(expected), _short(actual)])
	return same


func assert_ne(actual: Variant, unexpected: Variant, msg: String = "") -> bool:
	if typeof(actual) == typeof(unexpected) and actual == unexpected:
		fail("%s did not expect <%s>" % [msg, _short(actual)])
		return false
	return true


func assert_near(actual: float, expected: float, tolerance: float, msg: String = "") -> bool:
	var ok := is_finite(actual) and absf(actual - expected) <= tolerance
	if not ok:
		fail("%s expected %.9f ± %s got %.9f" % [msg, expected, tolerance, actual])
	return ok


func assert_vec_near(actual: Vector3, expected: Vector3, tolerance: float, msg: String = "") -> bool:
	var ok := actual.is_finite() and actual.distance_to(expected) <= tolerance
	if not ok:
		fail("%s expected %s ± %s got %s" % [msg, expected, tolerance, actual])
	return ok


func assert_empty_string(s: String, msg: String = "expected no error") -> bool:
	if s != "":
		fail("%s: %s" % [msg, s])
		return false
	return true


func assert_error_contains(err: String, needle: String, msg: String = "") -> bool:
	var ok := err != "" and err.to_lower().contains(needle.to_lower())
	if not ok:
		fail("%s expected error containing '%s' got '%s'" % [msg, needle, err])
	return ok


## Scratch directory under user:// unique to the current test; removed by the runner.
func scratch_dir() -> String:
	var dir := "user://test_scratch/%s" % current_test.replace("::", "_")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _short(v: Variant) -> String:
	var s := str(v)
	return s if s.length() <= 200 else s.substr(0, 200) + "..."
