class_name ToolSettings
extends RefCounted
## Tool settings namespaces of docs/editor-v2.md §2 with their defaults, ranges and validation.
## Numeric ranges clamp; wrong types, unknown keys and out-of-set values return error strings.

const STRENGTH_MIN := 0.05
const STRENGTH_MAX := 1.0
const PLACE_RADIUS_MIN := 1.0
const PLACE_RADIUS_MAX := 20.0
const PLACE_RADIUS_DEFAULT := 7.0
const PLACE_FLOW_DEFAULT := 0.7
const PATH_WIDTH_DEFAULT := 2.4  # fallback when the config has no path_width_default_m
const LAYER_MAX := 3
const TINT_MAX := 2
const BRUSH_SHAPES: Array[String] = ["soft", "hard", "cloud", "ring", "splat", "streak"]
const ALPHA_MODES: Array[String] = ["circle", "stamp", "pattern"]
const DEFAULT_SOURCE := "set:forest"

var _values: Dictionary = {}
var _radius_limits: Dictionary = {}  # namespace -> Vector2(min, max)
var _width_limits := Vector2(WorldConstants.PATH_WIDTH_MIN, WorldConstants.PATH_WIDTH_MAX)


func _init(ctx: ToolContext) -> void:
	var strength := float(ctx.default("brush", "strength_default", 0.8))
	for ns in ["sculpt", "paint"]:
		_radius_limits[ns] = Vector2(float(ctx.default("brush", ns + "_radius_min_m", 1.0)),
				float(ctx.default("brush", ns + "_radius_max_m", 16.0)))
	_radius_limits["place"] = Vector2(PLACE_RADIUS_MIN, PLACE_RADIUS_MAX)
	_width_limits = width_limits(ctx.defaults.get("brush", {}) as Dictionary)
	_values = {
		"sculpt": {"radius": _default_radius(ctx, "sculpt", 6.0),
				"strength": clampf(float(ctx.default("brush", "sculpt_strength_default", 1.0)), STRENGTH_MIN, STRENGTH_MAX)},
		"paint": {"radius": _default_radius(ctx, "paint", 4.0), "strength": strength, "layer": 1, "tint": 0},
		"place": {"radius": PLACE_RADIUS_DEFAULT, "strength": PLACE_FLOW_DEFAULT},
		"brush": {"shape": "soft", "alpha_mode": "circle", "pressure_enabled": true},
		"flatten": {"target": NAN},
		"path": {"width": clampf(float(ctx.default("brush", "path_width_default_m", PATH_WIDTH_DEFAULT)),
				_width_limits.x, _width_limits.y)},
		"scatter": {"source": DEFAULT_SOURCE, "avoid_objects": true},
		"select": {},
	}


func values(ns: String) -> Dictionary:
	return (_values.get(ns, {}) as Dictionary).duplicate(true)


func has_key(ns: String, key: String) -> bool:
	return _values.has(ns) and (_values[ns] as Dictionary).has(key)


## Returns "" and stores the clamped value, or an error string.
func set_value(ns: String, key: String, value: Variant) -> String:
	if not has_key(ns, key):
		return "Unknown setting '%s.%s'." % [ns, key]
	var checked := _validate(ns, key, value)
	if checked.error != "":
		return checked.error
	(_values[ns] as Dictionary)[key] = checked.value
	return ""


func _validate(ns: String, key: String, value: Variant) -> Dictionary:
	var bad := {"error": "Invalid value for %s.%s." % [ns, key], "value": null}
	var good := func(v: Variant) -> Dictionary: return {"error": "", "value": v}
	match key:
		"radius", "width", "strength":
			if not _is_number(value) or not is_finite(float(value)):
				return bad
			return good.call(_clamp(ns, key, float(value)))
		"target":
			if not _is_number(value) or is_inf(float(value)):
				return bad
			var t := float(value)
			return good.call(t if is_nan(t) else clampf(t, WorldConstants.HEIGHT_MIN, WorldConstants.HEIGHT_MAX))
		"layer", "tint":
			var top := LAYER_MAX if key == "layer" else TINT_MAX
			var n := _as_int(value)
			return good.call(n) if n >= 0 and n <= top else bad
		"shape":
			return good.call(value) if value is String and value in BRUSH_SHAPES else bad
		"alpha_mode":
			return good.call(value) if value is String and value in ALPHA_MODES else bad
		"pressure_enabled", "avoid_objects":
			return good.call(value) if typeof(value) == TYPE_BOOL else bad
		"source":
			return good.call(value) if is_valid_source(value) else bad
	return bad


## "mix" or "set:<id>" with a non-empty id.
static func is_valid_source(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var s: String = value
	return s == "mix" or (s.begins_with("set:") and s.length() > 4)


func _clamp(ns: String, key: String, v: float) -> float:
	if key == "strength":
		return clampf(v, STRENGTH_MIN, STRENGTH_MAX)
	if key == "width":
		return clampf(v, _width_limits.x, _width_limits.y)
	var limits: Vector2 = _radius_limits[ns]
	return clampf(v, limits.x, limits.y)


## Config limits ("brush" section), kept inside the format's [PATH_WIDTH_MIN, PATH_WIDTH_MAX].
static func width_limits(brush: Dictionary) -> Vector2:
	var lo := clampf(float(brush.get("path_width_min_m", WorldConstants.PATH_WIDTH_MIN)),
			WorldConstants.PATH_WIDTH_MIN, WorldConstants.PATH_WIDTH_MAX)
	var hi := clampf(float(brush.get("path_width_max_m", WorldConstants.PATH_WIDTH_MAX)),
			lo, WorldConstants.PATH_WIDTH_MAX)
	return Vector2(lo, hi)


func _default_radius(ctx: ToolContext, ns: String, fallback: float) -> float:
	var limits: Vector2 = _radius_limits[ns]
	return clampf(float(ctx.default("brush", ns + "_radius_default_m", fallback)), limits.x, limits.y)


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


## -1 for anything that is not a whole number.
static func _as_int(v: Variant) -> int:
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT and is_finite(v) and v == floorf(v):
		return int(v)
	return -1
