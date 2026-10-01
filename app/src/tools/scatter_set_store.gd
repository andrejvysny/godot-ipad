class_name ScatterSetStore
extends RefCounted
## Scatter sets (docs/editor-v2.md §6), persisted as JSON at `path`. A missing or corrupt file
## yields the built-in defaults; nothing here logs errors. Sets are plain Dictionaries:
## {id, name, items: [{asset_id, weight}], density, spacing, slope_min, slope_max, align}.
## Items may name assets the current catalog lacks; the controller filters at resolution time.

const DEFAULT_PATH := "user://scatter_sets.json"
const FILE_VERSION := 1
const WEIGHT_MIN := 0.5
const WEIGHT_MAX := 10.0
const DENSITY_MIN := 0.1
const DENSITY_MAX := 5.0
const SPACING_MIN := 0.2
const SPACING_MAX := 4.0
const SLOPE_MAX := 90.0
const NO_ITEMS := "Add at least one asset."

## "" keeps the store in memory only.
var path: String

var _sets: Array[Dictionary] = []


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	load_sets()


static func default_sets() -> Array[Dictionary]:
	return [
		_default("forest", "Spruce forest", [["nature.tree.spruce_a", 6.0], ["nature.cover.fern_a", 3.0],
				["nature.rock.boulder_a", 1.0]], 0.6, 1.4, 0.0, 35.0, false),
		_default("meadow", "Meadow", [["nature.cover.grass_tuft_a", 7.0], ["nature.cover.wildflowers_a", 2.0],
				["nature.rock.pebbles_a", 1.0]], 3.0, 0.35, 0.0, 25.0, true),
		_default("scree", "Rocky scree", [["nature.rock.pebbles_a", 5.0], ["nature.rock.boulder_a", 2.0]],
				1.4, 0.5, 12.0, 70.0, true),
	]


## Reads `path`; missing, unreadable, corrupt or fully invalid files give the defaults.
func load_sets() -> void:
	_sets = default_sets()
	if path == "" or not FileAccess.file_exists(path):
		return
	var parsed := JSON.new()
	if parsed.parse(FileAccess.get_file_as_string(path)) != OK:
		return
	var root: Variant = parsed.data
	if typeof(root) != TYPE_DICTIONARY or typeof((root as Dictionary).get("sets")) != TYPE_ARRAY:
		return
	var raw: Array = (root as Dictionary).sets
	var loaded: Array[Dictionary] = []
	for entry: Variant in raw:
		var checked := normalize(entry)
		if checked.error == "" and not _has_id(loaded, checked.data.id):
			loaded.append(checked.data)
	if loaded.is_empty() and not raw.is_empty():
		return
	_sets = loaded


## Returns "" or an error string.
func save() -> String:
	if path == "":
		return ""
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot write %s." % path
	file.store_string(JSON.stringify({"version": FILE_VERSION, "sets": _sets}, "\t"))
	return ""


func sets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in _sets:
		out.append(s.duplicate(true))
	return out


## {} when the id is unknown.
func get_set(id: String) -> Dictionary:
	for s in _sets:
		if s.id == id:
			return s.duplicate(true)
	return {}


## Validates, clamps, then replaces the set with the same id or appends it, and saves.
func put_set(set_data: Dictionary) -> String:
	var checked := normalize(set_data)
	if checked.error != "":
		return checked.error
	var normalized: Dictionary = checked.data
	var replaced := false
	for i in _sets.size():
		if _sets[i].id == normalized.id:
			_sets[i] = normalized
			replaced = true
	if not replaced:
		_sets.append(normalized)
	return save()


func remove_set(id: String) -> String:
	for i in _sets.size():
		if _sets[i].id == id:
			_sets.remove_at(i)
			return save()
	return "Unknown set '%s'." % id


func new_set_id() -> String:
	while true:
		var id := "set_" + Crypto.new().generate_random_bytes(4).hex_encode()
		if not _has_id(_sets, id):
			return id
	return ""


## {error, data}: `data` is a clean copy with every field clamped. Fails on wrong types, an empty
## id or name, or no usable item.
static func normalize(raw: Variant) -> Dictionary:
	var bad := func(message: String) -> Dictionary: return {"error": message, "data": {}}
	if typeof(raw) != TYPE_DICTIONARY:
		return bad.call("A scatter set must be an object.")
	var d: Dictionary = raw
	var id: Variant = d.get("id")
	var set_name: Variant = d.get("name")
	if typeof(id) != TYPE_STRING or (id as String).strip_edges() == "" or (id as String).contains(":"):
		return bad.call("A scatter set needs an id.")
	if typeof(set_name) != TYPE_STRING or (set_name as String).strip_edges() == "":
		return bad.call("A scatter set needs a name.")
	var items := _normalize_items(d.get("items"))
	if items.is_empty():
		return bad.call(NO_ITEMS)
	for key in ["density", "spacing", "slope_min", "slope_max"]:
		if not _is_number(d.get(key)) or not is_finite(float(d[key])):
			return bad.call("Invalid scatter set field '%s'." % key)
	if typeof(d.get("align")) != TYPE_BOOL:
		return bad.call("Invalid scatter set field 'align'.")
	var slope_min := clampf(float(d.slope_min), 0.0, SLOPE_MAX)
	return {"error": "", "data": {"id": id, "name": (set_name as String).strip_edges(), "items": items,
			"density": clampf(float(d.density), DENSITY_MIN, DENSITY_MAX),
			"spacing": clampf(float(d.spacing), SPACING_MIN, SPACING_MAX),
			"slope_min": slope_min, "slope_max": clampf(float(d.slope_max), slope_min, SLOPE_MAX),
			"align": d.align}}


static func _normalize_items(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	var seen := {}
	for entry: Variant in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var asset_id: Variant = (entry as Dictionary).get("asset_id")
		var weight: Variant = (entry as Dictionary).get("weight")
		if typeof(asset_id) != TYPE_STRING or (asset_id as String) == "" or seen.has(asset_id) \
				or not _is_number(weight) or not is_finite(float(weight)):
			continue
		seen[asset_id] = true
		out.append({"asset_id": asset_id, "weight": clampf(float(weight), WEIGHT_MIN, WEIGHT_MAX)})
	return out


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


static func _has_id(list: Array[Dictionary], id: String) -> bool:
	for s in list:
		if s.id == id:
			return true
	return false


static func _default(id: String, set_name: String, pairs: Array, density: float, spacing: float,
		slope_min: float, slope_max: float, align: bool) -> Dictionary:
	var items: Array[Dictionary] = []
	for pair: Array in pairs:
		items.append({"asset_id": pair[0], "weight": pair[1]})
	return {"id": id, "name": set_name, "items": items, "density": density, "spacing": spacing,
			"slope_min": slope_min, "slope_max": slope_max, "align": align}
