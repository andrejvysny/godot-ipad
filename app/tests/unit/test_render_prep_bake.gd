extends TestCase
## Render-asset preparation (docs/render-assets.md §6): multipart bake correctness (ASSET-03),
## rejection of singular/non-finite transforms (ASSET-04, prep side), stripping of non-geometry nodes
## (ASSET-06, prep side) and byte determinism of the whole preparation run.

const SceneReader := preload("res://devtools/render_prep/scene_reader.gd")
const MeshBaker := preload("res://devtools/render_prep/mesh_baker.gd")
const Baker := preload("res://devtools/render_prep/baker.gd")

const WING_LOCAL_ORIGIN := Vector3(2.0, 0.5, -0.5)


func _material(mat_name: String, color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = mat_name
	m.albedo_color = color
	return m


func _key_of(m: Material) -> String:
	return m.resource_name


## Body (non-uniform scale, rotated) -> Wing (mirrored, child of Body); Extra shares Body's material.
func _build_scene(path: String) -> Dictionary:
	var a := _material("a", Color.RED)
	var b := _material("b", Color.BLUE)
	var body_xf := Transform3D(Basis(Quaternion(Vector3(0.3, 0.9, 0.1).normalized(), 0.7)) * Basis.from_scale(Vector3(1.0, 2.0, 0.5)), Vector3(1.0, 2.0, 3.0))
	var wing_xf := Transform3D(Basis(Vector3.UP, 0.4) * Basis.from_scale(Vector3(-1.0, 1.0, 1.5)), WING_LOCAL_ORIGIN)
	var extra_xf := Transform3D(Basis(Vector3.RIGHT, 0.3), Vector3(-1.0, 0.0, 0.5))
	var root := Node3D.new()
	root.name = "Root"
	var body := MeshInstance3D.new()
	body.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 2.0, 1.0)
	box.material = a
	body.mesh = box
	body.transform = body_xf
	root.add_child(body)
	var wing := MeshInstance3D.new()
	wing.name = "Wing"
	var prism := PrismMesh.new()
	prism.material = b
	wing.mesh = prism
	wing.transform = wing_xf
	body.add_child(wing)
	var extra := MeshInstance3D.new()
	extra.name = "Extra"
	var box2 := BoxMesh.new()
	box2.material = a
	extra.mesh = box2
	extra.transform = extra_xf
	root.add_child(extra)
	body.owner = root
	wing.owner = root
	extra.owner = root
	var scene := PackedScene.new()
	assert_eq(scene.pack(root), OK, "pack scene")
	root.free()
	assert_eq(ResourceSaver.save(scene, path), OK, "save scene")
	return {"body": body_xf, "wing": body_xf * wing_xf, "extra": extra_xf, "box": box, "prism": prism, "box2": box2}


func _load_scene(path: String) -> PackedScene:
	return ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene


func test_multipart_bake_matches_node_transforms() -> void:
	var path := scratch_dir().path_join("multipart.tscn")
	var xf := _build_scene(path)
	var read := SceneReader.read(_load_scene(path), "multipart")
	assert_eq(read.errors.size(), 0, "no read errors")
	assert_eq(read.parts.size(), 3, "three mesh parts")
	var baked := MeshBaker.bake(read.parts, _key_of)
	assert_eq(baked.errors.size(), 0, "bake errors: %s" % str(baked.errors))
	assert_eq(baked.surfaces.size(), 2, "one surface per material")
	assert_eq(baked.surfaces[0].key, "a")
	assert_eq(baked.surfaces[1].key, "b")
	var arrays_a: Array = baked.surfaces[0].arrays
	var pos_a: PackedVector3Array = arrays_a[Mesh.ARRAY_VERTEX]
	var box_pos: PackedVector3Array = (xf.box as BoxMesh).get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	var box2_pos: PackedVector3Array = (xf.box2 as BoxMesh).get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	assert_eq(pos_a.size(), box_pos.size() + box2_pos.size(), "merged vertex count of the shared material")
	for i in box_pos.size():
		assert_vec_near(pos_a[i], (xf.body as Transform3D) * box_pos[i], 1e-5, "body vertex %d" % i)
	for i in box2_pos.size():
		assert_vec_near(pos_a[box_pos.size() + i], (xf.extra as Transform3D) * box2_pos[i], 1e-5, "extra vertex %d" % i)
	var arrays_b: Array = baked.surfaces[1].arrays
	var pos_b: PackedVector3Array = arrays_b[Mesh.ARRAY_VERTEX]
	var prism_pos: PackedVector3Array = (xf.prism as PrismMesh).get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	assert_eq(pos_b.size(), prism_pos.size(), "wing vertex count")
	for i in prism_pos.size():
		assert_vec_near(pos_b[i], (xf.wing as Transform3D) * prism_pos[i], 1e-5, "wing vertex %d (nested + mirrored)" % i)


func test_normals_use_inverse_transpose_and_mirrored_winding_is_flipped() -> void:
	var path := scratch_dir().path_join("normals.tscn")
	var xf := _build_scene(path)
	var read := SceneReader.read(_load_scene(path), "normals")
	var baked := MeshBaker.bake(read.parts, _key_of)
	var body_arrays: Array = (xf.box as BoxMesh).get_mesh_arrays()
	var body_basis: Basis = (xf.body as Transform3D).basis
	var nrm_a: PackedVector3Array = baked.surfaces[0].arrays[Mesh.ARRAY_NORMAL]
	var src_n: PackedVector3Array = body_arrays[Mesh.ARRAY_NORMAL]
	var it := body_basis.inverse().transposed()
	for i in src_n.size():
		assert_vec_near(nrm_a[i], (it * src_n[i]).normalized(), 1e-5, "normal %d" % i)
	# Flat-shaded faces: the clockwise (front-face) geometric normal must agree with vertex normals,
	# including the mirrored wing, whose determinant is negative.
	assert_true((xf.wing as Transform3D).basis.determinant() < 0.0, "wing is mirrored")
	for s in baked.surfaces.size():
		var arrays: Array = baked.surfaces[s].arrays
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var bad := 0
		for t in idx.size() / 3:
			var i0 := idx[t * 3]
			var i1 := idx[t * 3 + 1]
			var i2 := idx[t * 3 + 2]
			var g := (pos[i2] - pos[i0]).cross(pos[i1] - pos[i0]).normalized()
			if g.dot((nrm[i0] + nrm[i1] + nrm[i2]).normalized()) < 0.99:
				bad += 1
		assert_eq(bad, 0, "surface %d: triangles whose winding disagrees with the vertex normals" % s)


func test_mirrored_tangent_handedness_flips() -> void:
	var path := scratch_dir().path_join("tangents.tscn")
	var xf := _build_scene(path)
	var read := SceneReader.read(_load_scene(path), "tangents")
	var baked := MeshBaker.bake(read.parts, _key_of)
	var src: PackedFloat32Array = (xf.prism as PrismMesh).get_mesh_arrays()[Mesh.ARRAY_TANGENT]
	var out: PackedFloat32Array = baked.surfaces[1].arrays[Mesh.ARRAY_TANGENT]
	assert_eq(out.size(), src.size(), "tangent array size")
	for i in src.size() / 4:
		assert_near(out[i * 4 + 3], -src[i * 4 + 3], 1e-6, "mirrored tangent w %d" % i)
	var body_src: PackedFloat32Array = (xf.box as BoxMesh).get_mesh_arrays()[Mesh.ARRAY_TANGENT]
	var body_out: PackedFloat32Array = baked.surfaces[0].arrays[Mesh.ARRAY_TANGENT]
	for i in body_src.size() / 4:
		assert_near(body_out[i * 4 + 3], body_src[i * 4 + 3], 1e-6, "non-mirrored tangent w %d" % i)


func _write_text_scene(name: String, nodes: String) -> String:
	var path := scratch_dir().path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[gd_scene format=3]\n\n[sub_resource type=\"BoxMesh\" id=\"box\"]\n\n"
		+ "[sub_resource type=\"GDScript\" id=\"script\"]\nscript/source = \"extends MeshInstance3D\\n\"\n\n"
		+ "[node name=\"Root\" type=\"Node3D\"]\n\n" + nodes)
	f.close()
	return path


func _mesh_node(node_name: String, transform: String) -> String:
	return "[node name=\"%s\" type=\"MeshInstance3D\" parent=\".\"]\ntransform = %s\nmesh = SubResource(\"box\")\n\n" % [node_name, transform]


func test_singular_and_non_finite_transforms_are_rejected() -> void:
	var flat := _write_text_scene("flat.tscn", _mesh_node("FlatPart", "Transform3D(0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)"))
	var baked := MeshBaker.bake(SceneReader.read(_load_scene(flat), "flat").parts, _key_of_default)
	assert_true(baked.errors.size() > 0, "zero scale rejected")
	assert_error_contains(baked.errors[0] if baked.errors.size() > 0 else "", "FlatPart", "error names the node")
	assert_error_contains(baked.errors[0] if baked.errors.size() > 0 else "", "singular")
	assert_eq(baked.surfaces.size(), 0, "no geometry from a rejected part")
	var nan_scene := _write_text_scene("nan.tscn", _mesh_node("NanPart", "Transform3D(nan, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)"))
	var nan_baked := MeshBaker.bake(SceneReader.read(_load_scene(nan_scene), "nan").parts, _key_of_default)
	assert_true(nan_baked.errors.size() > 0, "NaN transform rejected")
	assert_error_contains(nan_baked.errors[0] if nan_baked.errors.size() > 0 else "", "NanPart", "error names the node")
	var inf_scene := _write_text_scene("inf.tscn", _mesh_node("InfPart", "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, inf, 0, 0)"))
	var inf_baked := MeshBaker.bake(SceneReader.read(_load_scene(inf_scene), "inf").parts, _key_of_default)
	assert_error_contains(inf_baked.errors[0] if inf_baked.errors.size() > 0 else "", "InfPart", "infinite translation rejected")


func _key_of_default(_m: Material) -> String:
	return "k"


const NON_GEOMETRY_NODES := """[node name="Sun" type="DirectionalLight3D" parent="."]

[node name="Cam" type="Camera3D" parent="."]

[node name="Body" type="StaticBody3D" parent="."]

[node name="Shape" type="CollisionShape3D" parent="Body"]

[node name="Anim" type="AnimationPlayer" parent="."]

[node name="Sparks" type="GPUParticles3D" parent="."]

"""


func _non_geometry_scene() -> String:
	var nodes := "[node name=\"Scripted\" type=\"MeshInstance3D\" parent=\".\"]\nmesh = SubResource(\"box\")\nscript = SubResource(\"script\")\n\n"
	nodes += NON_GEOMETRY_NODES + _mesh_node("Plain", "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0)")
	return _write_text_scene("mixed.tscn", nodes)


func test_non_geometry_nodes_and_scripts_are_stripped_and_reported() -> void:
	var read := SceneReader.read(_load_scene(_non_geometry_scene()), "mixed")
	assert_eq(read.errors.size(), 0, "no errors")
	assert_eq(read.parts.size(), 2, "only the two mesh parts survive")
	var by_node := {}
	for s: Dictionary in read.stripped:
		by_node[s.node] = s
	for n in ["Sun", "Cam", "Body", "Anim", "Sparks"]:
		assert_true(by_node.has(n), "%s stripped" % n)
	assert_true(by_node.has("Body/Shape"), "child of a stripped node is stripped")
	assert_eq(by_node["Body/Shape"].reason, "descendant of a stripped node")
	var script_entries: Array = read.stripped.filter(func(s: Dictionary) -> bool: return s.type == "script")
	assert_eq(script_entries.size(), 1, "script on a mesh node removed and listed")
	assert_eq(script_entries[0].node, "Scripted")


func _mini_manifest(scene_path: String, out_dir: String) -> Dictionary:
	return {
		"catalog_dir": "res://assets", "output_dir": out_dir, "report": out_dir + "/report.json",
		"assets": [{
			"asset_id": "nature.tree.spruce_a", "category": "tree", "vegetation": true, "decorative": false,
			"tiers": {"selected": {"scene": scene_path}, "near": {"alias": "selected"}, "mid": {"alias": "selected"},
				"far": {"alias": "selected"}, "ghost": {"alias": "far"}},
			"textures": {},
			"overview": {"kind": "canopy", "shape": "cone", "base_y_m": 1.4, "height_m": 5.6, "radius_m": 1.4, "color": [0.13, 0.34, 0.18]},
		}],
	}


func _snapshot(dir: String) -> Dictionary:
	var out := {}
	for f in DirAccess.get_files_at(dir):
		out[f] = FileAccess.get_file_as_bytes(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		var inner := _snapshot(dir.path_join(d))
		for k in inner:
			out[d + "/" + k] = inner[k]
	return out


func _clear(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_clear(dir.path_join(d))
		DirAccess.remove_absolute(dir.path_join(d))


func test_outputs_contain_only_resources_and_two_runs_are_byte_identical() -> void:
	var out_dir := scratch_dir().path_join("out")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var manifest := _mini_manifest(_non_geometry_scene(), out_dir)
	var report := Baker.new().prepare_catalog(manifest)
	assert_eq(report.errors.size(), 0, "prepare errors: %s" % str(report.errors))
	var first := _snapshot(out_dir)
	first.erase("report.json")
	assert_true(first.has("index.json") and first.has("spruce_a/descriptor.json") and first.has("spruce_a/mesh_selected.tres"), "expected outputs")
	for name: String in first:
		assert_true(name.ends_with(".tres") or name.ends_with(".json"), "only resources/json written: %s" % name)
		var text := (first[name] as PackedByteArray).get_string_from_utf8()
		assert_false(text.contains("[node ") or text.contains("GDScript") or text.contains("DirectionalLight3D"), "%s carries no scene data" % name)
	var stripped: Array = report.assets[0].stripped
	assert_true(stripped.size() >= 7, "stripped nodes are in the report (%d)" % stripped.size())
	_clear(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	Baker.new().prepare_catalog(manifest)
	var second := _snapshot(out_dir)
	second.erase("report.json")
	assert_eq(second.keys(), first.keys(), "same file set")
	for name: String in first:
		assert_true(second.has(name) and first[name] == second[name], "%s is byte-identical across runs" % name)
