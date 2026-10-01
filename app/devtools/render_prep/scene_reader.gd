extends RefCounted
## Reads a PackedScene through SceneState only: nothing is instantiated and no script runs.
## Returns {"parts": [...], "stripped": [...], "errors": PackedStringArray}. Each part is
## {"node", "xform" (asset_from_part), "mesh", "materials" (effective Material per surface)}.
## The scene root's own transform is ignored: the root is the asset frame.

const ALLOWED_TYPES: Array[String] = ["Node3D", "MeshInstance3D"]


static func read(scene: PackedScene, label: String) -> Dictionary:
	var out := {"parts": [], "stripped": [], "errors": PackedStringArray()}
	var errors: PackedStringArray = out.errors
	var st := scene.get_state()
	var count := st.get_node_count()
	if count == 0:
		errors.append("%s: scene has no nodes" % label)
		return out
	var world: Array[Transform3D] = []
	var dropped: Array[bool] = []
	var index_of := {"": 0}
	for i in count:
		var path := _norm(str(st.get_node_path(i)))
		var parent := -1
		if i > 0:
			var up := "" if not path.contains("/") else path.rsplit("/", true, 1)[0]
			if not index_of.has(up):
				errors.append("%s: node %s has no parent in the scene state" % [label, path])
				world.append(Transform3D.IDENTITY)
				dropped.append(true)
				continue
			parent = index_of[up]
		index_of[path] = i
		var node_name := "." if i == 0 else path
		var type_name := str(st.get_node_type(i))
		var inst: Variant = st.get_node_instance(i)
		var reason := ""
		if parent >= 0 and dropped[parent]:
			reason = "descendant of a stripped node"
		elif inst != null:
			reason = "instanced scene is not allowed"
		elif not ALLOWED_TYPES.has(type_name):
			reason = "node type %s is not allowed" % type_name
		dropped.append(reason != "")
		if reason != "":
			world.append(Transform3D.IDENTITY)
			(out.stripped as Array).append({"node": node_name, "type": type_name, "reason": reason})
			continue
		var props := _props(st, i)
		if props.has("script") and props.script != null:
			(out.stripped as Array).append({"node": node_name, "type": "script", "reason": "script removed from %s" % type_name})
		var local := Transform3D.IDENTITY if i == 0 else _local_transform(props)
		world.append(local if parent < 0 else world[parent] * local)
		if type_name == "MeshInstance3D":
			_add_part(out, node_name, world[i], props, label)
	return out


static func _props(st: SceneState, i: int) -> Dictionary:
	var d := {}
	for p in st.get_node_property_count(i):
		d[str(st.get_node_property_name(i, p))] = st.get_node_property_value(i, p)
	return d


static func _norm(p: String) -> String:
	if p == ".":
		return ""
	return p.trim_prefix("./")


static func _local_transform(props: Dictionary) -> Transform3D:
	if props.has("transform"):
		return props.transform
	var basis := Basis.IDENTITY
	if props.has("basis"):
		basis = props.basis
	elif props.has("quaternion"):
		basis = Basis(props.quaternion as Quaternion)
	elif props.has("rotation"):
		basis = Basis.from_euler(props.rotation as Vector3)
	if props.has("scale"):
		basis = basis * Basis.from_scale(props.scale as Vector3)
	var origin: Vector3 = props.get("position", Vector3.ZERO)
	return Transform3D(basis, origin)


static func _add_part(out: Dictionary, node_name: String, xform: Transform3D, props: Dictionary, label: String) -> void:
	var errors: PackedStringArray = out.errors
	if props.get("skin") != null:
		errors.append("%s: node %s: skinned meshes are not supported" % [label, node_name])
		return
	if props.has("skeleton") and str(props.skeleton) not in ["", ".."]:
		errors.append("%s: node %s: skeleton binding is not supported" % [label, node_name])
		return
	var mesh := props.get("mesh") as Mesh
	if mesh == null:
		return
	var materials: Array = []
	var override_all := props.get("material_override") as Material
	for s in mesh.get_surface_count():
		var mat: Material = override_all
		if mat == null:
			mat = props.get("surface_material_override/%d" % s) as Material
		if mat == null:
			mat = mesh.surface_get_material(s)
		materials.append(mat)
	(out.parts as Array).append({"node": node_name, "xform": xform, "mesh": mesh, "materials": materials})
