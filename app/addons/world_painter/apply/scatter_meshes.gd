class_name ScatterMeshes
extends RefCounted
## The Mesh a scatter binding is drawn with: a bundled asset's committed scatter mesh, or the meshes of the
## installed AssetStudio scene merged into one ArrayMesh (one surface per source surface, materials kept).

var _by_binding := {}  # binding_id -> Mesh


## [Mesh, ""] or [null, error].
func mesh_for(ctx: BakeContext, binding_id: String) -> Array:
	if _by_binding.has(binding_id):
		return [_by_binding[binding_id], ""]
	var binding := ctx.doc.assets.get_binding(binding_id)
	var def := ctx.doc.assets.definition(binding_id)
	if binding == null or def == null:
		return [null, "scatter binding %s is unknown" % binding_id]
	var mesh: Mesh = null
	if binding.is_bundled():
		mesh = load(def.scatter_mesh) as Mesh if def.scatter_mesh != "" else null
	else:
		var found := ctx.deliveries.scene_for(binding)
		if found[1] != "":
			return [null, found[1]]
		var inst := (found[0] as PackedScene).instantiate() as Node3D
		mesh = merged(inst) if inst != null else null
		if inst != null:
			inst.free()
	if mesh == null:
		return [null, "binding %s has no scatter mesh" % binding_id]
	if ctx.mapper != null:
		mesh = _mapped(ctx.mapper, binding, mesh)
	_by_binding[binding_id] = mesh
	return [mesh, ""]


## The mapped mesh; a shared catalog mesh is copied first and only kept when the mapper changed a surface.
static func _mapped(mapper: WPMaterialMapper, binding: AssetBinding, mesh: Mesh) -> Mesh:
	var shared := binding.is_bundled()
	var target: Mesh = mesh.duplicate() if shared else mesh
	return target if mapper.map_mesh(binding.binding_id, target, WPMaterialMapper.asset_id_of(binding)) > 0 or not shared else mesh


## One ArrayMesh of every MeshInstance3D below `root` (transforms relative to `root` baked into the vertices);
## null without meshes.
static func merged(root: Node3D) -> ArrayMesh:
	var out := ArrayMesh.new()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _relative(mi, root)
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			_transform(arrays, xf)
			out.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(s), arrays)
			var material := mi.get_active_material(s)
			out.surface_set_material(out.get_surface_count() - 1, material)
	return out if out.get_surface_count() > 0 else null


static func _relative(node: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


static func _transform(arrays: Array, xf: Transform3D) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	arrays[Mesh.ARRAY_VERTEX] = xf * vertices
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var basis := xf.basis.inverse().transposed()
		var out := PackedVector3Array()
		out.resize(normals.size())
		for i in normals.size():
			out[i] = (basis * normals[i]).normalized()
		arrays[Mesh.ARRAY_NORMAL] = out
