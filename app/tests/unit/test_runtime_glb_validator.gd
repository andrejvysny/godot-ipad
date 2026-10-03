extends TestCase
## RuntimeGlbValidator (INT-SPEC §6, §12): hostile or over-budget GLBs are rejected from the JSON chunk alone,
## before any scene is created; the tiny contract GLBs pass with their measured stats.


func _ok(glb: PackedByteArray) -> Dictionary:
	return RuntimeGlbValidator.validate(glb)


func _rejects(json: Dictionary, needle: String, bin: PackedByteArray = AssetTestKit.fixture_bin()) -> void:
	var r := _ok(AssetTestKit.build_glb(json, bin))
	assert_false(bool(r.ok), "must be rejected: " + needle)
	assert_error_contains(str(r.get("error", "")), needle)


func test_contract_fixtures_pass_with_measured_stats() -> void:
	var r := _ok(AssetTestKit.glb(AssetTestKit.GLB_V1))
	assert_true(bool(r.ok), str(r.get("error")))
	assert_eq(r.stats.triangles, 12)
	assert_eq(r.stats.nodes, 2)
	assert_eq(r.stats.materials_used, 1)
	assert_true(RuntimeGlbValidator.scatter_budget_ok(r.stats))
	var v2 := _ok(AssetTestKit.glb(AssetTestKit.GLB_V2))
	assert_true(bool(v2.ok), str(v2.get("error")))
	assert_eq(v2.stats.triangles, 24)


func test_rejects_container_problems() -> void:
	assert_false(bool(_ok(PackedByteArray([1, 2, 3])).ok))
	var glb := AssetTestKit.glb(AssetTestKit.GLB_V1)
	assert_false(bool(_ok(glb.slice(0, glb.size() - 8)).ok), "truncated file")
	var bad := glb.duplicate()
	bad[4] = 1
	assert_false(bool(_ok(bad).ok), "version 1")
	var broken := glb.duplicate()
	broken[20] = 0x7F
	assert_false(bool(_ok(broken).ok), "damaged JSON")
	var huge := PackedByteArray()
	huge.resize(RuntimeGlbValidator.MAX_BYTES + 1)
	assert_error_contains(str(_ok(huge).error), "limit")


func test_rejects_external_uris() -> void:
	var j := AssetTestKit.fixture_json()
	j.buffers = [{"byteLength": 240, "uri": "mesh.bin"}]
	_rejects(j, "external buffer URI")
	j = AssetTestKit.fixture_json()
	j.images = [{"uri": "https://example.com/t.png"}]
	_rejects(j, "external image URI")
	j = AssetTestKit.fixture_json()
	j.images = [{"uri": "file:///etc/passwd"}]
	_rejects(j, "external image URI")


func test_rejects_unsupported_features() -> void:
	var j := AssetTestKit.fixture_json()
	j.skins = [{"joints": [0]}]
	_rejects(j, "skins")
	j = AssetTestKit.fixture_json()
	j.animations = [{"channels": [], "samplers": []}]
	_rejects(j, "animations")
	j = AssetTestKit.fixture_json()
	j.extensionsRequired = ["KHR_draco_mesh_compression"]
	_rejects(j, "required extension 'KHR_draco_mesh_compression'")


func test_rejects_over_budget_counts() -> void:
	var j := AssetTestKit.fixture_json()
	var nodes: Array = []
	for i in RuntimeGlbValidator.MAX_NODES + 1:
		nodes.append({"name": "n%d" % i})
	nodes[1] = {"mesh": 0}
	j.nodes = nodes
	_rejects(j, "nodes exceed")
	j = AssetTestKit.fixture_json()
	var materials: Array = []
	for i in RuntimeGlbValidator.MAX_MATERIALS + 1:
		materials.append({})
	j.materials = materials
	_rejects(j, "materials exceed")


func test_rejects_over_budget_triangles() -> void:
	var j := AssetTestKit.fixture_json()
	var count := (RuntimeGlbValidator.MAX_TRIANGLES + 1) * 3
	var bin := PackedByteArray()
	bin.resize(count * 4)
	j.buffers = [{"byteLength": bin.size()}]
	j.bufferViews = [{"buffer": 0, "byteOffset": 0, "byteLength": bin.size()}, {"buffer": 0, "byteOffset": 0, "byteLength": 96}]
	j.accessors[0].count = count
	_rejects(j, "triangles exceed", bin)


func test_rejects_accessors_past_their_buffer() -> void:
	var j := AssetTestKit.fixture_json()
	j.accessors[0].count = 100000
	_rejects(j, "reads past its bufferView")
	j = AssetTestKit.fixture_json()
	j.bufferViews[1].byteLength = 100000
	_rejects(j, "outside its buffer")


func test_rejects_non_triangle_primitives() -> void:
	var j := AssetTestKit.fixture_json()
	j.meshes[0].primitives[0].mode = 1
	_rejects(j, "triangle list")


func _with_image(w: int, h: int, count: int = 1) -> Dictionary:
	var png := AssetTestKit.png_header(w, h)
	var bin := AssetTestKit.fixture_bin()
	var offset := bin.size()
	bin.append_array(png)
	var j := AssetTestKit.fixture_json()
	j.buffers = [{"byteLength": bin.size()}]
	j.bufferViews.append({"buffer": 0, "byteOffset": offset, "byteLength": png.size()})
	j.images = []
	for i in count:
		j.images.append({"bufferView": 2, "mimeType": "image/png"})
	return {"json": j, "bin": bin}


func test_rejects_oversized_textures() -> void:
	var big := _with_image(RuntimeGlbValidator.MAX_TEXTURE_DIM + 1, 1)
	_rejects(big.json, "texture limit", big.bin)
	var many := _with_image(4096, 4096, 3)
	_rejects(many.json, "decoded textures exceed", many.bin)


func test_texture_stats_and_scatter_budget() -> void:
	var ok := _with_image(2048, 1024)
	var r := _ok(AssetTestKit.build_glb(ok.json, ok.bin))
	assert_true(bool(r.ok), str(r.get("error")))
	assert_eq(r.stats.max_texture_dim, 2048)
	assert_eq(r.stats.texture_bytes, 2048 * 1024 * 4)
	assert_false(RuntimeGlbValidator.scatter_budget_ok(r.stats), "2048 px exceeds the scatter texture budget")
	var small := _with_image(1024, 512)
	var s := _ok(AssetTestKit.build_glb(small.json, small.bin))
	assert_true(RuntimeGlbValidator.scatter_budget_ok(s.stats))


func test_rejects_unreadable_images() -> void:
	var j := AssetTestKit.fixture_json()
	var bin := AssetTestKit.fixture_bin()
	var offset := bin.size()
	bin.append_array(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	j.buffers = [{"byteLength": bin.size()}]
	j.bufferViews.append({"buffer": 0, "byteOffset": offset, "byteLength": 8})
	j.images = [{"bufferView": 2, "mimeType": "image/png"}]
	_rejects(j, "not a readable PNG or JPEG", bin)
