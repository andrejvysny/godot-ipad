extends TestCase
## Scatter meshes of the bundled catalog: loadable ArrayMesh, vertex colours, triangle budgets.

const BUDGETS := {
	"nature.tree.spruce_a": 200,
	"nature.rock.boulder_a": 80,
	"nature.cover.grass_tuft_a": 60,
	"nature.cover.fern_a": 60,
	"nature.cover.wildflowers_a": 60,
	"nature.rock.pebbles_a": 60,
}


func _triangles(mesh: ArrayMesh) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var idx: Variant = arrays[Mesh.ARRAY_INDEX]
	if idx != null and (idx as PackedInt32Array).size() > 0:
		return (idx as PackedInt32Array).size() / 3
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func test_every_scatter_asset_has_a_budgeted_mesh() -> void:
	var cat: AssetCatalog = AssetCatalog.load_from()[0]
	var seen := 0
	for id in cat.sorted_ids():
		var a := cat.get_asset(id)
		if not a.scatter_allowed:
			continue
		seen += 1
		assert_true(BUDGETS.has(id), "%s has a budget" % id)
		assert_ne(a.scatter_mesh, "", "%s has a scatter mesh" % id)
		var mesh := load(a.scatter_mesh) as ArrayMesh
		if not assert_true(mesh != null, "%s loads as ArrayMesh" % id):
			continue
		assert_eq(mesh.get_surface_count(), 1, "%s surface count" % id)
		var arrays := mesh.surface_get_arrays(0)
		assert_true(arrays[Mesh.ARRAY_COLOR] != null, "%s has vertex colours" % id)
		var tris := _triangles(mesh)
		assert_true(tris > 0 and tris <= int(BUDGETS[id]), "%s: %d triangles within %d" % [id, tris, BUDGETS[id]])
		var mat := mesh.surface_get_material(0) as StandardMaterial3D
		assert_true(mat != null and mat.vertex_color_use_as_albedo, "%s vertex-colour material" % id)
	assert_eq(seen, BUDGETS.size(), "six scatter assets")
