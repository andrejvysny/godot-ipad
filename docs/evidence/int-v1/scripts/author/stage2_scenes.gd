extends SceneTree
func _save(root: Node3D, path: String) -> void:
	for c in root.get_children():
		_own(c, root)
	var ps := PackedScene.new()
	ps.pack(root)
	print(path, " -> ", ResourceSaver.save(ps, path))
func _own(n: Node, root: Node) -> void:
	n.owner = root
	for c in n.get_children():
		_own(c, root)
func _anchor(root: Node3D) -> void:
	var m := Marker3D.new(); m.name = "GroundAnchor"; root.add_child(m)
func _init() -> void:
	DirAccess.make_dir_recursive_absolute("res://scenes"); DirAccess.make_dir_recursive_absolute("res://materials"); DirAccess.make_dir_recursive_absolute("res://models")
	var prop := Node3D.new(); prop.name = "NeutralPbrCrate"
	var body := MeshInstance3D.new(); body.name = "Body"; var bm := BoxMesh.new(); bm.size = Vector3(1, 0.5, 2); body.mesh = bm; body.position = Vector3(0, 0.25, 0)
	var pm := StandardMaterial3D.new(); pm.albedo_color = Color(0.5, 0.5, 0.5); pm.metallic = 0.0; pm.roughness = 0.8
	ResourceSaver.save(pm, "res://materials/neutral.tres"); body.set_surface_override_material(0, load("res://materials/neutral.tres"))
	prop.add_child(body); _anchor(prop); _save(prop, "res://scenes/prop.tscn")
	var tree := Node3D.new(); tree.name = "TexturedTree"
	var trunk := MeshInstance3D.new(); trunk.name = "Trunk"; var cm := CylinderMesh.new(); cm.top_radius = 0.15; cm.bottom_radius = 0.25; cm.height = 2.0; trunk.mesh = cm; trunk.position = Vector3(0, 1, 0)
	var bark := StandardMaterial3D.new(); bark.albedo_texture = load("res://textures/bark.png"); bark.roughness = 0.9
	ResourceSaver.save(bark, "res://materials/bark.tres"); trunk.set_surface_override_material(0, load("res://materials/bark.tres"))
	var crown := MeshInstance3D.new(); crown.name = "Crown"; var sm := SphereMesh.new(); sm.radius = 1.0; sm.height = 2.0; crown.mesh = sm; crown.position = Vector3(0, 3, 0)
	var leaf := StandardMaterial3D.new(); leaf.albedo_texture = load("res://textures/leaf.png"); leaf.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR; leaf.alpha_scissor_threshold = 0.5; leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(leaf, "res://materials/leaf.tres"); crown.set_surface_override_material(0, load("res://materials/leaf.tres"))
	tree.add_child(trunk); tree.add_child(crown); _anchor(tree); _save(tree, "res://scenes/tree.tscn")
	# vertex-colour foliage: ArrayMesh -> GLB (a .tscn with an ArrayMesh is text format 4 in Godot 4.7.2, not accepted by publication)
	var fol := Node3D.new(); fol.name = "VertexColorFoliage"
	var verts := PackedVector3Array([Vector3(-0.5,0,0), Vector3(0.5,0,0), Vector3(0.5,1,0), Vector3(-0.5,1,0), Vector3(0,0,-0.5), Vector3(0,0,0.5), Vector3(0,1,0.5), Vector3(0,1,-0.5)])
	var norms := PackedVector3Array(); var uvs := PackedVector2Array(); var cols := PackedColorArray(); var idx := PackedInt32Array()
	for q in 2:
		for i in 4:
			norms.append(Vector3(0,0,1) if q == 0 else Vector3(1,0,0))
			uvs.append([Vector2(0,1), Vector2(1,1), Vector2(1,0), Vector2(0,0)][i])
			cols.append(Color(0.4, 0.9, 0.3, 1) if i < 2 else Color(1.0, 1.0, 0.5, 1))
		idx.append_array(PackedInt32Array([q*4, q*4+1, q*4+2, q*4, q*4+2, q*4+3]))
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts; arr[Mesh.ARRAY_NORMAL] = norms; arr[Mesh.ARRAY_TEX_UV] = uvs; arr[Mesh.ARRAY_COLOR] = cols; arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new(); am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var fm := StandardMaterial3D.new(); fm.vertex_color_use_as_albedo = true; fm.albedo_texture = load("res://textures/leaf.png"); fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR; fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.resource_name = "foliage_vc"; am.surface_set_material(0, fm)
	var fmi := MeshInstance3D.new(); fmi.name = "Cards"; fmi.mesh = am; fol.add_child(fmi)
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	print("append ", doc.append_from_scene(fol, st)); var gb: PackedByteArray = doc.generate_buffer(st); var gf := FileAccess.open("res://models/foliage.glb", FileAccess.WRITE); gf.store_buffer(gb); gf.close(); print("write ", gb.size())
	var vp := FileAccess.open("res://scenes/foliage_glb.tscn", FileAccess.WRITE)
	vp.store_string('[gd_scene load_steps=2 format=3]\n\n[ext_resource type="PackedScene" path="res://models/foliage.glb" id="1_glb"]\n\n[node name="VertexColorFoliage" type="Node3D"]\n\n[node name="Mesh" parent="." instance=ExtResource("1_glb")]\n\n[node name="GroundAnchor" type="Marker3D" parent="."]\n')
	vp.close(); quit()
