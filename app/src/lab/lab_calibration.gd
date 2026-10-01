class_name LabCalibration
extends Control
## Targets occupy viewport coordinates; errors are recorded in logical UIKit points.

signal completed(results: Array[Dictionary])
var results: Array[Dictionary] = []
var active := false
var _index := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func start() -> void:
	results.clear()
	_index = 0
	active = true
	queue_redraw()


func target() -> Vector2:
	var column := _index % 3
	var row := floorf(float(_index) / 3.0)
	return Vector2(64.0 + column * (size.x - 128.0) / 2.0,
		64.0 + floorf(row) * (size.y - 128.0) / 2.0)


func record(sample: PointerSample, units_per_point: float, scale: float) -> void:
	if not active or not is_finite(units_per_point) or units_per_point <= 0.0:
		return
	var expected := target()
	var error := sample.position_viewport.distance_to(expected) / units_per_point
	results.append({"point": _index + 1, "target": [expected.x, expected.y],
		"actual": [sample.position_viewport.x, sample.position_viewport.y],
		"error_pt": error, "render_scale": scale, "mapping_generation": sample.mapping_generation,
		"source": PointerSample.source_name(sample.source), "pass": error <= 2.0})
	_index += 1
	active = _index < 9
	queue_redraw()
	if not active:
		completed.emit(results.duplicate(true))


func _draw() -> void:
	if not active:
		return
	var point := target()
	draw_circle(point, 16.0, Color(0.1, 0.15, 0.2, 0.9))
	draw_arc(point, 12.0, 0.0, TAU, 32, Color.WHITE, 2.0)
	draw_line(point - Vector2(22, 0), point + Vector2(22, 0), Color.YELLOW, 2.0)
	draw_line(point - Vector2(0, 22), point + Vector2(0, 22), Color.YELLOW, 2.0)
