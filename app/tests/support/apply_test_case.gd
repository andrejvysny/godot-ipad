class_name ApplyTestCase
extends TestCase
## Base of the Apply tests that bring up Terrain3D: the pinned binaries log one known deprecation warning when the
## first node enters the tree, so the runner's own counter is replaced by a filter that tolerates exactly that.

const KNOWN_T3D_WARNING := "instance_reset_physics_interpolation() is deprecated"


class LogFilter extends Logger:
	var unexpected: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if rationale != "" else code
		if not text.contains(KNOWN_T3D_WARNING):
			unexpected.append("%s (%s:%d %s)" % [text, file, line, function])

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _filter: LogFilter


func before_each() -> void:
	allow_logged_errors()
	_filter = LogFilter.new()
	OS.add_logger(_filter)


func after_each() -> void:
	OS.remove_logger(_filter)
	assert_eq(_filter.unexpected.size(), 0, "unexpected engine log: %s" % "; ".join(_filter.unexpected))
