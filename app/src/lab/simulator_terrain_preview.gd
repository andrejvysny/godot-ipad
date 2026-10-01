class_name SimulatorTerrainPreview
extends Node3D
## Canonical-data preview for the pinned Simulator's GLES-only engine. Not Terrain3D evidence.

const STRIDE := 4
const GRASS := Color(0.32, 0.48, 0.18)
const DIRT := Color(0.48, 0.29, 0.13)
var document: WorldDocument
var _meshes: Dictionary = {}
var _dirty: Dictionary = {}


func initialize(doc: WorldDocument) -> String:
	document = doc
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_meshes.clear()
	for loc in document.sorted_region_locations():
		var instance := MeshInstance3D.new()
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		instance.material_override = material
		add_child(instance)
		_meshes[loc] = instance
		_dirty[loc] = true
	flush()
	return ""


func mark_dirty(loc: Vector2i) -> void:
	_dirty[loc] = true


func flush() -> void:
	for loc: Vector2i in _dirty:
		_meshes[loc].mesh = _region_mesh(loc)
	_dirty.clear()


func _region_mesh(loc: Vector2i) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := WorldConstants.REGION_SAMPLES
	for z in range(0, size, STRIDE):
		for x in range(0, size, STRIDE):
			var origin := loc * size + Vector2i(x, z)
			if document.get_control_at_sample(origin.x, origin.y) & ControlCodec.HOLE_BIT:
				continue
			for offset in [Vector2i.ZERO, Vector2i(STRIDE, 0), Vector2i(0, STRIDE),
					Vector2i(STRIDE, 0), Vector2i(STRIDE, STRIDE), Vector2i(0, STRIDE)]:
				var point: Vector2i = origin + offset
				var control := document.get_control_at_sample(point.x, point.y)
				var height := document.get_height_at_sample(point.x, point.y)
				if not is_finite(height):
					height = document.get_height_at_sample(loc.x * size + mini(x + offset.x, size - 1),
						loc.y * size + mini(z + offset.y, size - 1))
				surface.set_color(GRASS.lerp(DIRT, ControlCodec.get_blend(control) / 255.0))
				surface.set_normal(Vector3.UP)
				surface.add_vertex(Vector3(point.x, height, point.y))
	return surface.commit()
