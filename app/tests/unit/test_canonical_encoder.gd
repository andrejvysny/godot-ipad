extends TestCase
## Authored hash V2 (docs/world-format.md §7). The known answer below was computed by an
## independent Python implementation of the spec stream, not by this encoder.

const KAT_HASH := "0b3d6e93129ecb17132baf3d634af766e2430bcdc23240fa49864de57fd47d87"
const SPRUCE := "nature.tree.spruce_a"


func _kat_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(2.0, ControlCodec.default_value())
	doc.catalog_id = "poc_nature"
	doc.catalog_version = 2
	doc.catalog_sha256 = "ab".repeat(32)
	doc.scatter.add(SPRUCE, 1, 1.5, -2.25, 0.5, 1.25, 1)
	doc.scatter.add("a.grass", 2, -3.0, 4.0, -1.0, 0.75, 0)
	var p := PathRecord.new()
	p.path_id = "33333333-3333-4333-8333-333333333333"
	p.width_m = 2.5
	p.points = PackedVector2Array([Vector2(0, 0), Vector2(10.5, -4.25)])
	doc.put_path(p)
	var o := ObjectRecord.new()
	o.object_id = "11111111-1111-4111-8111-111111111111"
	o.asset_id = SPRUCE
	o.asset_version = 1
	o.set_position(1.0, 2.0, 3.0)
	doc.put_object(o)
	return doc


func test_known_answer() -> void:
	assert_eq(CanonicalEncoder.authored_hash(_kat_doc()), KAT_HASH)
	assert_eq(CanonicalEncoder.authored_bytes(_kat_doc()).slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V2\n")


func test_every_authored_layer_changes_the_hash() -> void:
	var base := CanonicalEncoder.authored_hash(_kat_doc())
	var edits := {
		"rock_enabled": func(d: WorldDocument) -> void: d.rules.rock_enabled = false,
		"rock_slope": func(d: WorldDocument) -> void: d.rules.rock_slope_deg = 31,
		"sand_enabled": func(d: WorldDocument) -> void: d.rules.sand_enabled = false,
		"sand_height": func(d: WorldDocument) -> void: d.rules.sand_height_dm = -3,
		"color": func(d: WorldDocument) -> void: d.get_region(Vector2i(0, 0)).color[10] = 3,
		"control": func(d: WorldDocument) -> void: d.get_region(Vector2i(0, 0)).control[10] = 5,
		"scatter": func(d: WorldDocument) -> void: d.scatter.x[0] = 1.75,
		"path": func(d: WorldDocument) -> void: d.get_path_record("33333333-3333-4333-8333-333333333333").width_m = 3.0,
		"object": func(d: WorldDocument) -> void: d.get_object("11111111-1111-4111-8111-111111111111").uniform_scale = 1.5,
	}
	for key in edits:
		var d := _kat_doc()
		edits[key].call(d)
		assert_ne(CanonicalEncoder.authored_hash(d), base, key)


func test_unused_scatter_slots_and_ids_do_not_change_the_hash() -> void:
	var a := _kat_doc()
	var b := _kat_doc()
	b.world_id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
	b.document_revision = 99
	b.scatter.add("zzz.unused", 1, 0, 0, 0, 1, 0)
	b.scatter.remove_indices(PackedInt32Array([2]))
	assert_eq(CanonicalEncoder.authored_hash(b), CanonicalEncoder.authored_hash(a))
