extends RefCounted
## Bakes mesh parts into asset space and merges surfaces that share a material key.
## Mirrored transforms (det < 0) flip the triangle winding and the tangent handedness (Godot front
## faces are clockwise); normals use the inverse transpose. Never recentres or rescales.

const MIN_ABS_DET := 1e-12
const MAX_SURFACES := 8


static func transform_error(xf: Transform3D, node: String) -> String:
	if not xf.is_finite():
		return "node %s: non-finite transform" % node
	var det := xf.basis.determinant()
	if not is_finite(det) or absf(det) < MIN_ABS_DET:
		return "node %s: singular transform (determinant %s)" % [node, det]
	return ""


## key_of: Callable(Material) -> String. Returns {"surfaces": [{"key", "arrays"}], "triangles",
## "aabb", "errors"}; "arrays" is a full Mesh array (indexed triangles).
static func bake(parts: Array, key_of: Callable) -> Dictionary:
	var errors := PackedStringArray()
	var order: Array[String] = []
	var acc := {}
	for part: Dictionary in parts:
		var node: String = part.node
		var xf: Transform3D = part.xform
		var err := transform_error(xf, node)
		var mesh: Mesh = part.mesh
		if err == "" and mesh is ArrayMesh and (mesh as ArrayMesh).get_blend_shape_count() > 0:
			err = "node %s: meshes with blend shapes are not supported" % node
		if err != "":
			errors.append(err)
			continue
		for s in mesh.get_surface_count():
			var key: String = key_of.call(part.materials[s])
			err = _add_surface(acc, order, key, mesh, s, xf, node)
			if err != "":
				errors.append(err)
	var surfaces: Array = []
	var tris := 0
	var box := AABB()
	var first := true
	for key in order:
		var a: Dictionary = acc[key]
		var arrays := _finish(a)
		surfaces.append({"key": key, "arrays": arrays})
		tris += (a.idx as PackedInt32Array).size() / 3
		for v in a.pos as PackedVector3Array:
			box = AABB(v, Vector3.ZERO) if first else box.expand(v)
			first = false
	if surfaces.size() > MAX_SURFACES:
		errors.append("baked mesh has %d material surfaces (limit %d)" % [surfaces.size(), MAX_SURFACES])
	return {"surfaces": surfaces, "triangles": tris, "aabb": box, "errors": errors}


static func _add_surface(acc: Dictionary, order: Array[String], key: String, mesh: Mesh, s: int, xf: Transform3D, node: String) -> String:
	var src: Array
	if mesh is ArrayMesh:
		if (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return "node %s surface %d: only triangle surfaces are supported" % [node, s]
		src = (mesh as ArrayMesh).surface_get_arrays(s)
	elif mesh is PrimitiveMesh:
		src = (mesh as PrimitiveMesh).get_mesh_arrays()
	else:
		return "node %s: unsupported mesh class %s" % [node, mesh.get_class()]
	for slot in [Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
		if src[slot] != null and (src[slot] as Array).size() > 0:
			return "node %s surface %d: skinned meshes are not supported" % [node, s]
	var pos: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = src[Mesh.ARRAY_NORMAL] if src[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	if pos.is_empty() or nrm.size() != pos.size():
		return "node %s surface %d: vertices and normals are required and must match" % [node, s]
	var idx: PackedInt32Array = PackedInt32Array()
	if src[Mesh.ARRAY_INDEX] != null:
		idx = src[Mesh.ARRAY_INDEX]
	else:
		idx.resize(pos.size())
		for i in pos.size():
			idx[i] = i
	if idx.size() % 3 != 0:
		return "node %s surface %d: index count is not a multiple of 3" % [node, s]
	for i in idx:
		if i < 0 or i >= pos.size():
			return "node %s surface %d: index out of range" % [node, s]
	var tang: PackedFloat32Array = src[Mesh.ARRAY_TANGENT] if src[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
	var uv: PackedVector2Array = src[Mesh.ARRAY_TEX_UV] if src[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var col: PackedColorArray = src[Mesh.ARRAY_COLOR] if src[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	if (not tang.is_empty() and tang.size() != pos.size() * 4) or (not uv.is_empty() and uv.size() != pos.size()) \
			or (not col.is_empty() and col.size() != pos.size()):
		return "node %s surface %d: attribute arrays do not match the vertex count" % [node, s]
	if not acc.has(key):
		acc[key] = {"pos": PackedVector3Array(), "nrm": PackedVector3Array(), "tan": PackedFloat32Array(),
			"uv": PackedVector2Array(), "col": PackedColorArray(), "idx": PackedInt32Array(),
			"has_tan": false, "has_uv": false, "has_col": false}
		order.append(key)
	var a: Dictionary = acc[key]
	var base: int = (a.pos as PackedVector3Array).size()
	_backfill(a, base, not tang.is_empty(), not uv.is_empty(), not col.is_empty())
	var basis := xf.basis
	var mirrored := basis.determinant() < 0.0
	var inv_t := basis.inverse().transposed()
	var pos_acc: PackedVector3Array = a.pos
	var nrm_acc: PackedVector3Array = a.nrm
	for i in pos.size():
		var p := xf * pos[i]
		var n := (inv_t * nrm[i]).normalized()
		if not p.is_finite() or not n.is_finite():
			return "node %s surface %d: transform produced non-finite vertex data" % [node, s]
		pos_acc.append(p)
		nrm_acc.append(n)
	a.pos = pos_acc
	a.nrm = nrm_acc
	_append_attributes(a, pos.size(), tang, uv, col, basis, mirrored)
	var idx_acc: PackedInt32Array = a.idx
	for t in idx.size() / 3:
		var i0 := idx[t * 3] + base
		var i1 := idx[t * 3 + 1] + base
		var i2 := idx[t * 3 + 2] + base
		if mirrored:
			var tmp := i1
			i1 = i2
			i2 = tmp
		idx_acc.append(i0)
		idx_acc.append(i1)
		idx_acc.append(i2)
	a.idx = idx_acc
	return ""


static func _backfill(a: Dictionary, base: int, has_tan: bool, has_uv: bool, has_col: bool) -> void:
	if has_tan and not a.has_tan:
		a.has_tan = true
		var tangents: PackedFloat32Array = a.tan
		for i in base:
			tangents.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 1.0]))
		a.tan = tangents
	if has_uv and not a.has_uv:
		a.has_uv = true
		var uvs: PackedVector2Array = a.uv
		uvs.resize(base)
		a.uv = uvs
	if has_col and not a.has_col:
		a.has_col = true
		var cols: PackedColorArray = a.col
		for i in base:
			cols.append(Color.WHITE)
		a.col = cols


static func _append_attributes(a: Dictionary, count: int, tang: PackedFloat32Array, uv: PackedVector2Array,
		col: PackedColorArray, basis: Basis, mirrored: bool) -> void:
	if a.has_tan:
		var out: PackedFloat32Array = a.tan
		for i in count:
			if tang.is_empty():
				out.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 1.0]))
				continue
			var t := (basis * Vector3(tang[i * 4], tang[i * 4 + 1], tang[i * 4 + 2])).normalized()
			var w := tang[i * 4 + 3]
			out.append_array(PackedFloat32Array([t.x, t.y, t.z, -w if mirrored else w]))
		a.tan = out
	if a.has_uv:
		var uvs: PackedVector2Array = a.uv
		if uv.is_empty():
			uvs.resize(uvs.size() + count)
		else:
			uvs.append_array(uv)
		a.uv = uvs
	if a.has_col:
		var cols: PackedColorArray = a.col
		if col.is_empty():
			for i in count:
				cols.append(Color.WHITE)
		else:
			cols.append_array(col)
		a.col = cols


static func _finish(a: Dictionary) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = a.pos
	arrays[Mesh.ARRAY_NORMAL] = a.nrm
	if a.has_tan:
		arrays[Mesh.ARRAY_TANGENT] = a.tan
	if a.has_col:
		arrays[Mesh.ARRAY_COLOR] = a.col
	if a.has_uv:
		arrays[Mesh.ARRAY_TEX_UV] = a.uv
	arrays[Mesh.ARRAY_INDEX] = a.idx
	return arrays


## Vertex + index bytes per docs/render-assets.md §5 (octahedral normals/tangents = 4 bytes each).
static func gpu_bytes(baked: Dictionary) -> int:
	var total := 0
	for s: Dictionary in baked.surfaces:
		var arrays: Array = s.arrays
		var verts := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var stride := 12 + 4
		stride += 4 if arrays[Mesh.ARRAY_TANGENT] != null else 0
		stride += 8 if arrays[Mesh.ARRAY_TEX_UV] != null else 0
		stride += 4 if arrays[Mesh.ARRAY_COLOR] != null else 0
		total += verts * stride + (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() * (2 if verts <= 65535 else 4)
	return total


## material_paths: key -> res:// path of the material .tres each surface references (ext_resource).
static func save_mesh(baked: Dictionary, material_paths: Dictionary, path: String) -> String:
	var mesh := ArrayMesh.new()
	var stubs: Array[StandardMaterial3D] = []
	for s: Dictionary in baked.surfaces:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.arrays)
		var stub := StandardMaterial3D.new()
		stub.take_over_path(material_paths[s.key])
		mesh.surface_set_material(stubs.size(), stub)
		stubs.append(stub)
	var err := ResourceSaver.save(mesh, path)
	for stub in stubs:
		stub.resource_path = ""
	if err != OK:
		return "cannot save %s (error %d)" % [path, err]
	var text := FileAccess.get_file_as_string(path)
	var re := RegEx.new()
	re.compile("\\[ext_resource type=\"(\\w+)\" path=\"([^\"]+)\" id=\"([^\"]+)\"\\]")
	for m in re.search_all(text):
		text = text.replace("id=\"%s\"" % m.get_string(3), "id=\"mat_%s\"" % m.get_string(2).get_file().get_basename())
		text = text.replace("ExtResource(\"%s\")" % m.get_string(3), "ExtResource(\"mat_%s\")" % m.get_string(2).get_file().get_basename())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot rewrite %s" % path
	f.store_string(text)
	f.close()
	return ""
