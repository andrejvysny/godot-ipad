class_name PathPreview
extends Node3D
## Live draped ribbon shown while the Path tool draws (docs/editor-v2.md §7). Purely visual:
## never pickable, never in history.

const ALPHA := 0.75

var _instance := MeshInstance3D.new()


func _init() -> void:
	_instance.material_override = PathRibbon.material(true)
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visible = false
	add_child(_instance)


func show_stroke(doc: WorldDocument, points: PackedVector2Array, width: float) -> void:
	var mesh := PathRibbon.build(doc, points, width, ALPHA)
	_instance.mesh = mesh
	_instance.visible = mesh != null


func hide_stroke() -> void:
	_instance.visible = false
	_instance.mesh = null


func is_stroke_visible() -> bool:
	return _instance.visible
