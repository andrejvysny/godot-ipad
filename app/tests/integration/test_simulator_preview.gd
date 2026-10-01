extends TestCase


func test_preview_preserves_authored_bytes_and_rebuilds_dirty_mesh() -> void:
	var loaded := WorldCodec.read_generation("res://fixtures/gentle_hills", AssetCatalog.load_from()[0])
	assert_eq(loaded[1], "")
	var document: WorldDocument = loaded[0]
	var before := CanonicalEncoder.authored_hash(document)
	var preview := SimulatorTerrainPreview.new()
	tree.root.add_child(preview)
	assert_eq(preview.initialize(document), "")
	assert_eq(CanonicalEncoder.authored_hash(document), before)
	var instance: MeshInstance3D = preview._meshes[Vector2i.ZERO]
	var mesh := instance.mesh
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var reaches_boundary := false
	for vertex in vertices:
		assert_true(vertex.is_finite())
		reaches_boundary = reaches_boundary or vertex.x == 128.0
	assert_true(reaches_boundary, "preview reaches adjacent region without a two-meter gap")
	# Vertices are in world metres, so the preview lines up with canonical picking.
	var probe: Vector3 = vertices[vertices.size() / 2]
	assert_near(probe.y, document.sample_height(probe.x, probe.z), 1e-4, "preview vertex at world position")
	assert_eq(preview.mark_dirty(TerrainView.MAP_CONTROL, Vector2i.ZERO), "")
	assert_error_contains(preview.mark_dirty(TerrainView.MAP_HEIGHT, Vector2i(5, 5)), "not loaded")
	preview.flush()
	assert_ne(instance.mesh, mesh)
	assert_eq(CanonicalEncoder.authored_hash(document), before)
	tree.root.remove_child(preview)
	preview.free()
