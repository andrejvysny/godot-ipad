class_name InputTrace
extends RefCounted
## Bounded input trace (spec §18.3): samples, routing decisions and router control calls, on
## explicit request only. Entries hold input data only — never filesystem paths or credentials.
## Entry kinds: "sample" (PointerSample.to_dict()), "action" (normalize_action()), and
## "event" ({op: "cancel_all", reason} | {op: "set_modal", on}) so replays are deterministic.
## Files are JSON under user://traces/; all numbers come back as float (see from_dict()).
## Loaded data is untrusted: load_file() validates every entry and replay() skips (and reports)
## entries that do not validate, so a malformed file never becomes a BEGIN or a script error.

const FORMAT := "worldpoc-input-trace"
const VERSION := 1
const TRACE_DIR := "user://traces/"
const DEFAULT_CAPACITY := 10000
const COMPARE_TOLERANCE := 1e-4
const EVENT_OPS := ["cancel_all", "set_modal"]

var capacity: int = DEFAULT_CAPACITY
var dropped: int = 0  ## oldest entries overwritten since the last clear()

var _recording := false
var _buf: Array[Dictionary] = []
var _head: int = 0  # index of the oldest entry once the ring is full


func _init(cap: int = DEFAULT_CAPACITY) -> void:
	capacity = maxi(1, cap)


func start() -> void:
	_recording = true


func stop() -> void:
	_recording = false


func is_recording() -> bool:
	return _recording


func clear() -> void:
	_buf.clear()
	_head = 0
	dropped = 0


func size() -> int:
	return _buf.size()


func record_sample(s: PointerSample) -> void:
	if _recording:
		_append({"kind": "sample", "data": s.to_dict()})


func record_action(action: Dictionary) -> void:
	if _recording:
		_append({"kind": "action", "data": normalize_action(action)})


func record_event(op: String, args: Dictionary = {}) -> void:
	if _recording:
		var data := args.duplicate()
		data["op"] = op
		_append({"kind": "event", "data": data})


## Entries oldest first (deep copies).
func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in _buf.size():
		out.append(_buf[(_head + i) % _buf.size()].duplicate(true))
	return out


func to_dict() -> Dictionary:
	return {"format": FORMAT, "version": VERSION, "dropped": dropped, "entries": entries()}


func to_json() -> String:
	return JSON.stringify(to_dict(), "\t")


## Saves under user://traces/. Returns "" on success or an error message.
func save(file_name: String) -> String:
	if file_name == "" or file_name.contains("/") or file_name.contains("\\") or file_name.contains(".."):
		return "trace file name must be a plain name, got '%s'" % file_name
	DirAccess.make_dir_recursive_absolute(TRACE_DIR)
	var f := FileAccess.open(TRACE_DIR + file_name, FileAccess.WRITE)
	if f == null:
		return "cannot write trace: %s" % error_string(FileAccess.get_open_error())
	f.store_string(to_json())
	f.close()
	return ""


## Loads a trace or fixture file. Returns {entries: Array[Dictionary], data: Dictionary, error: String}.
static func load_file(path: String) -> Dictionary:
	var result := {"entries": [] as Array[Dictionary], "data": {}, "error": ""}
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		result.error = "cannot read trace '%s'" % path.get_file()
		return result
	var json := JSON.new()  # instance parse reports errors without logging them
	var parsed: Variant = json.data if json.parse(text) == OK else null
	if not parsed is Dictionary or not (parsed as Dictionary).get("entries") is Array:
		result.error = "not a trace: '%s'" % path.get_file()
		return result
	var data: Dictionary = parsed
	var format: Variant = data.get("format", "")
	if not format is String or format != FORMAT:
		result.error = "unexpected trace format '%s'" % str(format)
		return result
	var typed: Array[Dictionary] = []
	var raw_entries: Array = data.entries
	for i in raw_entries.size():
		var err := entry_error(raw_entries[i])
		if err != "":
			result.error = "entry %d: %s" % [i, err]
			return result
		typed.append(raw_entries[i])
	result.entries = typed
	result.data = data
	return result


## "" when `e` is a well-formed trace entry, otherwise the reason.
static func entry_error(e: Variant) -> String:
	if not e is Dictionary:
		return "entry is not an object"
	var kind: Variant = (e as Dictionary).get("kind")
	var data: Variant = (e as Dictionary).get("data")
	if not data is Dictionary:
		return "entry data is not an object"
	var d: Dictionary = data
	match kind:
		"sample":
			return sample_error(d)
		"action":
			return "" if d.get("type") is String else "action without a type"
		"event":
			if not _is_one_of(d.get("op"), EVENT_OPS):
				return "unknown event op '%s'" % str(d.get("op"))
			if d.op == "cancel_all" and not d.get("reason", "") is String:
				return "cancel_all reason is not a string"
			if d.op == "set_modal" and not d.get("on") is bool:
				return "set_modal without a boolean 'on'"
			return ""
	return "unknown entry kind '%s'" % str(kind)


## "" when `d` is a valid PointerSample.to_dict() record, otherwise the reason. Source, id,
## phase and raw are required; the other fields are optional but must have the right type.
static func sample_error(d: Dictionary) -> String:
	if not _is_one_of(d.get("source"), PointerSample.Source.keys()):
		return "unknown source '%s'" % str(d.get("source"))
	if not _is_one_of(d.get("phase"), PointerSample.Phase.keys()):
		return "unknown phase '%s'" % str(d.get("phase"))
	if not _is_integral(d.get("id")):
		return "id is not an integer"
	if not _is_vec(d.get("raw")):
		return "raw is not [x, y]"
	for key: String in ["vp", "tilt"]:
		if d.get(key) != null and not _is_vec(d[key]):
			return "%s is not [x, y]" % key
	for key: String in ["t", "pressure"]:
		if d.get(key) != null and not _is_number(d[key]):
			return "%s is not a number" % key
	for key: String in ["seq", "gen"]:
		if d.has(key) and not _is_integral(d[key]):
			return "%s is not an integer" % key
	for key: String in ["predicted", "coalesced"]:
		if d.has(key) and not d[key] is bool:
			return "%s is not a boolean" % key
	if d.has("cancel_reason") and not d.cancel_reason is String:
		return "cancel_reason is not a string"
	return ""


## Rebuilds a PointerSample from to_dict() output (JSON floats converted back to ints).
## Returns null when sample_error(d) is not "".
static func sample_from_dict(d: Dictionary) -> PointerSample:
	if sample_error(d) != "":
		return null
	var s := PointerSample.new()
	s.source = PointerSample.Source.keys().find(d.source)
	s.pointer_id = int(d.id)
	s.phase = PointerSample.Phase.keys().find(d.phase)
	s.timestamp_s = float(d.get("t", 0.0))
	s.position_raw = _vec(d.get("raw", null))
	s.position_viewport = _vec(d.get("vp", d.get("raw", null)))
	s.pressure_valid = d.get("pressure", null) != null
	s.pressure = float(d.pressure) if s.pressure_valid else 0.0
	s.tilt_valid = d.get("tilt", null) != null
	s.tilt = _vec(d.tilt) if s.tilt_valid else Vector2.ZERO
	s.is_predicted = bool(d.get("predicted", false))
	s.is_coalesced = bool(d.get("coalesced", false))
	s.sample_sequence = int(d.get("seq", 0))
	s.mapping_generation = int(d.get("gen", -1))
	s.cancel_reason = str(d.get("cancel_reason", ""))
	return s


## JSON-safe view of a router action: Vector2 -> [x, y]; samples -> {id, phase, vp}.
static func normalize_action(action: Dictionary) -> Dictionary:
	var out := {}
	for key: String in action:
		var v: Variant = action[key]
		if v is Vector2:
			out[key] = [v.x, v.y]
		elif v is PointerSample:
			var s: PointerSample = v
			out[key] = {"id": s.pointer_id, "phase": PointerSample.phase_name(s.phase),
					"vp": [s.position_viewport.x, s.position_viewport.y]}
		else:
			out[key] = v
	return out


## Feeds "sample" and "event" entries to `router` in order; returns the produced actions.
## Malformed entries are skipped with a diagnostic action (code "invalid_trace_entry").
static func replay(router: InputRouter, trace_entries: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in trace_entries.size():
		var err := entry_error(trace_entries[i])
		if err != "":
			out.append({"type": "diagnostic", "code": "invalid_trace_entry",
					"message": "entry %d: %s" % [i, err], "pointer_id": -1})
			continue
		var entry: Dictionary = trace_entries[i]
		var data: Dictionary = entry.data
		match str(entry.kind):
			"sample":
				out.append_array(router.process(sample_from_dict(data)))
			"event":
				if data.get("op") == "cancel_all":
					out.append_array(router.cancel_all(str(data.get("reason", "explicit"))))
				elif data.get("op") == "set_modal":
					out.append_array(router.set_modal(bool(data.get("on", false))))
	return out


## Compares actions against expected specs. Each expected dictionary lists only the fields
## that must match (numbers within COMPARE_TOLERANCE). Returns "" or the first mismatch.
static func match_actions(actual: Array[Dictionary], expected: Array) -> String:
	if actual.size() != expected.size():
		return "expected %d actions, got %d: %s" % [expected.size(), actual.size(), _types(actual)]
	for i in actual.size():
		var got := normalize_action(actual[i])
		var want: Dictionary = expected[i]
		for key: String in want:
			if not got.has(key) or not _same(got[key], want[key]):
				return "action %d field '%s': expected %s got %s (%s)" % [
					i, key, JSON.stringify(want[key]), JSON.stringify(got.get(key)), JSON.stringify(got)]
	return ""


static func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) <= COMPARE_TOLERANCE
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		for k: Variant in b:
			if not a.has(k) or not _same(a[k], b[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


static func _types(actions: Array[Dictionary]) -> String:
	var names := PackedStringArray()
	for a in actions:
		names.append(str(a.get("type", "?")))
	return ", ".join(names)


## Type-checked first: comparing mismatched Variant types is a script error.
static func _is_one_of(v: Variant, names: Array) -> bool:
	return v is String and names.has(v)


static func _is_number(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))


static func _is_integral(v: Variant) -> bool:
	return _is_number(v) and float(v) == floorf(float(v)) and absf(float(v)) <= 9007199254740991.0


static func _is_vec(v: Variant) -> bool:
	return v is Array and (v as Array).size() == 2 and _is_number(v[0]) and _is_number(v[1])


static func _vec(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() == 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


func _append(entry: Dictionary) -> void:
	if _buf.size() < capacity:
		_buf.append(entry)
		return
	_buf[_head] = entry
	_head = (_head + 1) % capacity
	dropped += 1
