class_name ScatterBake
extends RefCounted
## Scatter of an accepted world (ADR 0017 A4): one MultiMeshInstance3D per (32 m cell, binding), transforms from the
## same ScatterBuild the editor draws (instances without a terrain sample are skipped and counted). No collision
## unless the consumer profile opts the binding in; then each instance gets a convex shape of the binding's mesh.

const CELL_M := 32.0


static func build(ctx: BakeContext, root: Node3D) -> String:
	var started := Time.get_ticks_usec()
	var group := Node3D.new()
	group.name = "Scatter"
	root.add_child(group)
	group.owner = root
	var meshes := ScatterMeshes.new()
	var cells := _group(ctx.doc.scatter)
	for binding_id: String in _sorted(cells.keys()):
		var found := meshes.mesh_for(ctx, binding_id)
		if found[1] != "":
			return found[1]
		var mesh: Mesh = found[0]
		var reach := ScatterBuild.reach_of(mesh.get_aabb())
		var by_cell: Dictionary = cells[binding_id]
		for key: Vector2i in _sorted_cells(by_cell.keys()):
			_add_cell(ctx, group, root, binding_id, mesh, reach, key, by_cell[key])
	ctx.time("scatter", started)
	return ""


## binding id -> {Vector2i cell -> ScatterCell}. Instance order inside a cell is the layer order.
static func _group(layer: ScatterLayer) -> Dictionary:
	var out := {}
	for i in layer.count():
		var binding_id := layer.binding_of(i)
		var key := Vector2i(floori(layer.x[i] / CELL_M), floori(layer.z[i] / CELL_M))
		var by_cell: Dictionary = out.get(binding_id, {})
		var cell: ScatterCell = by_cell.get(key)
		if cell == null:
			cell = ScatterCell.new(key, ScatterCell.MEANINGFUL)
			by_cell[key] = cell
		cell.add(binding_id, layer.x[i], layer.z[i], layer.yaw[i], layer.scale[i], layer.flags[i])
		out[binding_id] = by_cell
	return out


static func _add_cell(ctx: BakeContext, group: Node3D, root: Node3D, binding_id: String, mesh: Mesh, reach: float,
		key: Vector2i, cell: ScatterCell) -> void:
	var origin := Vector3(key.x * CELL_M, 0.0, key.y * CELL_M)
	var built := ScatterBuild.build(ctx.doc, cell, binding_id, origin, reach, false, Transform3D.IDENTITY, 1.0, 0)
	var total := cell.count()
	ctx.stats.scatter_skipped += total - int(built.count)
	if int(built.count) == 0:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = int(built.count)
	mm.buffer = built.buffer
	mm.custom_aabb = built.aabb
	var node := MultiMeshInstance3D.new()
	node.name = "s_%d_%d_%s" % [key.x, key.y, binding_id]
	node.multimesh = mm
	node.position = origin
	node.set_meta("wp_binding_id", binding_id)
	group.add_child(node)
	node.owner = root
	if ctx.collision_bindings.has(binding_id):
		_add_collision(node, root, mesh, built.buffer, int(built.count))
	ctx.stats.scatter_nodes += 1
	ctx.stats.scatter_instances[binding_id] = int(ctx.stats.scatter_instances.get(binding_id, 0)) + int(built.count)


static func _add_collision(node: Node3D, root: Node3D, mesh: Mesh, buffer: PackedFloat32Array, count: int) -> void:
	var body := StaticBody3D.new()
	body.name = "Collision"
	node.add_child(body)
	body.owner = root
	var shape := mesh.create_convex_shape()
	for i in count:
		var o := i * ScatterBuild.FLOATS
		var xf := Transform3D(Basis(Vector3(buffer[o], buffer[o + 4], buffer[o + 8]),
				Vector3(buffer[o + 1], buffer[o + 5], buffer[o + 9]), Vector3(buffer[o + 2], buffer[o + 6], buffer[o + 10])),
				Vector3(buffer[o + 3], buffer[o + 7], buffer[o + 11]))
		var cs := CollisionShape3D.new()
		cs.name = "c%d" % i
		cs.shape = shape
		cs.transform = xf
		body.add_child(cs)
		cs.owner = root


static func _sorted(keys: Array) -> PackedStringArray:
	var out := PackedStringArray(keys)
	out.sort()
	return out


static func _sorted_cells(keys: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k: Vector2i in keys:
		out.append(k)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out
