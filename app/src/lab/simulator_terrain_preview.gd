class_name SimulatorTerrainPreview
extends TerrainView
## Canonical-data preview for the pinned Simulator's GLES-only engine. Not Terrain3D evidence.

const STRIDE := 4
const GRASS := Color(0.32, 0.48, 0.18)
const DIRT := Color(0.48, 0.29, 0.13)
var document: WorldDocument
var _meshes: Dictionary = {}
var _dirty: Dictionary = {}
var _debug_view := "normal"
var _material := StandardMaterial3D.new()


func initialize(doc: WorldDocument) -> String:
	document = doc
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_meshes.clear()
	_material.vertex_color_use_as_albedo = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_apply_shading()
	for loc in document.sorted_region_locations():
		var instance := MeshInstance3D.new()
		instance.material_override = _material
		add_child(instance)
		_meshes[loc] = instance
		_dirty[loc] = true
	flush()
	return ""


## Rebuilds the whole region mesh, so the map kind only selects nothing here.
func mark_dirty(_kind: int, loc: Vector2i) -> String:
	if not _meshes.has(loc):
		return "region %s is not loaded" % loc
	_dirty[loc] = true
	return ""


func has_pending_uploads() -> bool:
	return not _dirty.is_empty()


func flush() -> void:
	for loc: Vector2i in _dirty:
		_meshes[loc].mesh = _region_mesh(loc)
	_dirty.clear()


func set_debug_view(mode: String) -> String:
	if not TerrainAdapter.DEBUG_VIEWS.has(mode):
		return "unknown debug view '%s'" % mode
	_debug_view = mode
	_apply_shading()
	for loc in _meshes:
		_dirty[loc] = true
	return ""


func get_debug_view() -> String:
	return _debug_view


func _apply_shading() -> void:
	var lit := _debug_view == "normal"
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if lit else BaseMaterial3D.SHADING_MODE_UNSHADED


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
				var height := _height(loc, x + offset.x, z + offset.y)
				surface.set_color(_color(control, height))
				surface.set_normal(_normal(loc, x + offset.x, z + offset.y))
				surface.add_vertex(Vector3(point.x * WorldConstants.SAMPLE_SPACING, height,
					point.y * WorldConstants.SAMPLE_SPACING))
	return surface.commit()


## Local sample coordinates may step one stride past the region; the neighbor region (or, at the
## outer world edge, the clamped last sample) supplies the seam height.
func _height(loc: Vector2i, lx: int, lz: int) -> float:
	var size := WorldConstants.REGION_SAMPLES
	var height := document.get_height_at_sample(loc.x * size + lx, loc.y * size + lz)
	if not is_finite(height):
		height = document.get_height_at_sample(loc.x * size + mini(lx, size - 1), loc.y * size + mini(lz, size - 1))
	return height


func _normal(loc: Vector2i, lx: int, lz: int) -> Vector3:
	var span := 2.0 * STRIDE * WorldConstants.SAMPLE_SPACING
	var dx := _height(loc, mini(lx + STRIDE, WorldConstants.REGION_SAMPLES), lz) - _height(loc, maxi(lx - STRIDE, 0), lz)
	var dz := _height(loc, lx, mini(lz + STRIDE, WorldConstants.REGION_SAMPLES)) - _height(loc, lx, maxi(lz - STRIDE, 0))
	return Vector3(-dx, span, -dz).normalized()


func _color(control: int, height: float) -> Color:
	if _debug_view == "heightmap":
		var t := inverse_lerp(WorldConstants.HEIGHT_MIN, WorldConstants.HEIGHT_MAX, height)
		return Color(t, t, t)
	return GRASS.lerp(DIRT, ControlCodec.get_blend(control) / 255.0)
