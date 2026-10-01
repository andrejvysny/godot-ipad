class_name OverviewGroup
extends RefCounted
## State of one overview group (128 m / 256 m, aligned to the world origin): its rect, build generation,
## proxy meshes and activation. `current` means the proxy meshes match the instances as of the last
## invalidation; an invalidated group is never active (spec §9.3). Coordinates: world XZ; proxy vertices are
## local to the rect corner (y absolute).

var level: int = 0  # index into the renderer's levels
var level_m: float = 128.0
var key := Vector2i.ZERO
var rect := Rect2()
var gen: int = 0  # bumped by every invalidation; older worker results are discarded
var current := false
var building := false
var invalidated := false  # a change since the last applied build (never true for a group that was never built)
var active := false
var complete := true  # false when a member has no overview descriptor: the group must not hide its cells
var role := ""
var dirty_ms: int = 0
var result: Dictionary = {}  # worker result waiting for the main-thread mesh creation
var members: int = 0
var triangles: int = 0
var lobes: int = 0
var worker_usec: int = 0
var mesh_usec: int = 0
var y_lo: float = 0.0
var y_hi: float = 0.0
var canopy: MeshInstance3D
var solid: MeshInstance3D
var canopy_boxes := PackedVector3Array()  # (min, size) per lobe, local
var solid_boxes := PackedVector3Array()


func _init(level_: int, level_m_: float, key_: Vector2i) -> void:
	level = level_
	level_m = level_m_
	key = key_
	rect = Rect2(Vector2(key_) * level_m_, Vector2(level_m_, level_m_))


func world_aabb() -> AABB:
	return AABB(Vector3(rect.position.x, y_lo, rect.position.y), Vector3(level_m, y_hi - y_lo, level_m))


## Drops proxy meshes and hides them (the stale geometry is gone, not merely hidden).
func drop_meshes() -> void:
	for node: MeshInstance3D in [canopy, solid]:
		if node != null:
			node.visible = false
			node.mesh = null
	canopy_boxes = PackedVector3Array()
	solid_boxes = PackedVector3Array()
	triangles = 0
	lobes = 0


func free_nodes() -> void:
	for node: MeshInstance3D in [canopy, solid]:
		if node != null:
			node.free()
	canopy = null
	solid = null


## Creates the ArrayMeshes of the waiting worker result (main thread). One call per group.
func apply_result(parent: Node3D, material: Material) -> void:
	var t0 := Time.get_ticks_usec()
	var res := result
	result = {}
	drop_meshes()
	canopy = _surface_node(parent, canopy, res.canopy, material, "canopy")
	solid = _surface_node(parent, solid, res.solid, material, "solid")
	canopy_boxes = (res.canopy as Dictionary).boxes
	solid_boxes = (res.solid as Dictionary).boxes
	triangles = int(res.triangles)
	lobes = int(res.lobes)
	y_lo = float(res.min_y)
	y_hi = float(res.max_y)
	current = true
	invalidated = false
	mesh_usec = Time.get_ticks_usec() - t0


func _surface_node(parent: Node3D, node: MeshInstance3D, surface: Dictionary, material: Material, label: String) -> MeshInstance3D:
	if int(surface.lobes) == 0:
		return node
	if node == null:
		node = MeshInstance3D.new()
		node.name = "ov%d_%d_%d_%s" % [int(level_m), key.x, key.y, label]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.position = Vector3(rect.position.x, 0.0, rect.position.y)
		node.visible = false
		parent.add_child(node)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = surface.vertices
	arrays[Mesh.ARRAY_NORMAL] = surface.normals
	arrays[Mesh.ARRAY_COLOR] = surface.colors
	arrays[Mesh.ARRAY_INDEX] = surface.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	node.mesh = mesh
	return node
