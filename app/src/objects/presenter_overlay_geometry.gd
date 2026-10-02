class_name PresenterOverlayGeometry
extends RefCounted


static func wire_box(box: AABB) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	# get_endpoint bits: 1 = z, 2 = y, 4 = x.
	for i in 8:
		for bit in [1, 2, 4]:
			if i & bit == 0:
				mesh.surface_add_vertex(box.get_endpoint(i))
				mesh.surface_add_vertex(box.get_endpoint(i | bit))
	mesh.surface_end()
	return mesh


static func sphere_marker(radius: float, material: Material) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
