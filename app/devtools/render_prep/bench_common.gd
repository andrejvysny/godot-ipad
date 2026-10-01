extends RefCounted
## Shared helpers of the bench asset generator: materials, node assembly, byte-stable scene saving.


static func material(mat_name: String, color: Color, tex: Texture2D = null, cutout: bool = false,
		two_sided: bool = false, vertex_color: bool = false, rough: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = mat_name
	m.albedo_color = color
	m.roughness = rough
	m.vertex_color_use_as_albedo = vertex_color
	if tex != null:
		m.albedo_texture = tex
	if cutout:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
	if two_sided or cutout:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func add(parent: Node3D, node_name: String, mesh: Mesh, mat: Material, xf: Transform3D = Transform3D.IDENTITY) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	if mat != null:
		for s in mesh.get_surface_count():
			if mesh is ArrayMesh:
				(mesh as ArrayMesh).surface_set_material(s, mat)
			else:
				(mesh as PrimitiveMesh).material = mat
	mi.transform = xf
	parent.add_child(mi)
	return mi


static func group(parent: Node3D, node_name: String, xf: Transform3D) -> Node3D:
	var n := Node3D.new()
	n.name = node_name
	n.transform = xf
	parent.add_child(n)
	return n


static func embed_texture(img: Image) -> PortableCompressedTexture2D:
	var t := PortableCompressedTexture2D.new()
	t.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	return t


static func save_scene(root: Node3D, path: String) -> String:
	_own(root, root)
	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err == OK:
		err = ResourceSaver.save(scene, path)
	if err != OK:
		return "cannot save %s (error %d)" % [path, err]
	stabilize_ids(path)
	return ""


static func save_resource(res: Resource, path: String) -> String:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return "cannot save %s (error %d)" % [path, err]
	stabilize_ids(path)
	return ""


static func _own(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_own(c, root)


## Godot writes random sub_resource ids and node unique ids; rewrite them so output is byte-stable.
static func stabilize_ids(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var re := RegEx.new()
	re.compile("\\[sub_resource type=\"(\\w+)\" id=\"([^\"]+)\"\\]")
	var n := 0
	for m in re.search_all(text):
		n += 1
		var fresh := "%s_%d" % [m.get_string(1), n]
		text = text.replace("\"%s\"" % m.get_string(2), "\"%s\"" % fresh)
	re.compile(" unique_id=\\d+")
	text = re.sub(text, "", true)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


static func to_transform(origin: Vector3, yaw: float = 0.0, tilt: float = 0.0, scale: Vector3 = Vector3.ONE) -> Transform3D:
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt) * Basis.from_scale(scale)
	return Transform3D(b, origin)
