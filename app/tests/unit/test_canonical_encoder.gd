extends TestCase
## Authored hash V2 (docs/world-format.md §7). The known answer below was computed by an
## independent Python implementation of the spec stream, not by this encoder.

const KAT_HASH := "0b3d6e93129ecb17132baf3d634af766e2430bcdc23240fa49864de57fd47d87"
const SPRUCE := "nature.tree.spruce_a"


func _binding(doc: WorldDocument, asset_id: String, version: int) -> String:
	var b := AssetBinding.new()
	b.catalog_id = "poc_nature"
	b.catalog_version = 2
	b.catalog_sha256 = "ab".repeat(32)
	b.asset_id = asset_id
	b.asset_version = version
	b.set_policy(true, "0.5", "2", "-1", "2")
	return doc.assets.add(b)


func _kat_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(2.0, ControlCodec.default_value())
	var spruce := _binding(doc, SPRUCE, 1)
	doc.scatter.add(spruce, 1.5, -2.25, 0.5, 1.25, 1)
	doc.scatter.add(_binding(doc, "a.grass", 2), -3.0, 4.0, -1.0, 0.75, 0)
	var p := PathRecord.new()
	p.path_id = "33333333-3333-4333-8333-333333333333"
	p.width_m = 2.5
	p.points = PackedVector2Array([Vector2(0, 0), Vector2(10.5, -4.25)])
	doc.put_path(p)
	var o := ObjectRecord.new()
	o.object_id = "11111111-1111-4111-8111-111111111111"
	o.binding_id = spruce
	o.set_position(1.0, 2.0, 3.0)
	doc.put_object(o)
	return doc


## The V2 stream of a schema 2 world, computed from bundled bindings mapped back to catalog ids.
func test_legacy_v2_known_answer() -> void:
	var legacy := CanonicalEncoder.legacy_authored_hash(_kat_doc())
	assert_empty_string(legacy[1])
	assert_eq(legacy[0], KAT_HASH)
	assert_eq(CanonicalEncoder.legacy_authored_bytes(_kat_doc())[0].slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V2\n")


func test_legacy_stream_needs_bundled_bindings_of_one_catalog() -> void:
	var doc := _kat_doc()
	var other := AssetBinding.new()
	other.catalog_id = "other"
	other.catalog_version = 1
	other.catalog_sha256 = "cd".repeat(32)
	other.asset_id = "x"
	other.asset_version = 1
	other.set_policy(false, "1", "1", "0", "0")
	doc.get_object("11111111-1111-4111-8111-111111111111").binding_id = doc.assets.add(other)
	assert_error_contains(CanonicalEncoder.legacy_authored_hash(doc)[1], "more than one catalog")
	var empty := WorldDocument.create_flat(0.0, 0)
	assert_error_contains(CanonicalEncoder.legacy_authored_hash(empty)[1], "no catalog")


## An independent writer of the authored-hash-v4.md stream; the encoder must produce the same bytes.
func _expected_v4(doc: WorldDocument) -> PackedByteArray:
	var out := PackedByteArray()
	var u32 := func(v: int) -> PackedByteArray:
		var b := PackedByteArray()
		b.resize(4)
		b.encode_u32(0, v)
		return b
	var str_of := func(t: String) -> PackedByteArray:
		var u := t.to_utf8_buffer()
		return u32.call(u.size()) + u
	var f64 := func(v: float) -> PackedByteArray:
		var b := PackedByteArray()
		b.resize(8)
		b.encode_double(0, 0.0 if v == 0.0 else v)
		return b
	out.append_array("WPOC-AUTHORED-V4\n".to_ascii_buffer())
	out.append_array(u32.call(4))
	out.append_array(CanonicalEncoder.sha256(doc.assets.encode_referenced(doc)[0]))
	out.append_array(f64.call(0.5))
	out.append_array(u32.call(256))
	var layout := doc.layout
	for v in [layout.min_region.x, layout.min_region.y]:
		var b := PackedByteArray()
		b.resize(4)
		b.encode_s32(0, v)
		out.append_array(b)
	out.append_array(u32.call(layout.region_count.x))
	out.append_array(u32.call(layout.region_count.y))
	out.append(1 if doc.rules.rock_enabled else 0)
	var slope := PackedByteArray()
	slope.resize(4)
	slope.encode_s32(0, doc.rules.rock_slope_deg)
	out.append_array(slope)
	out.append(1 if doc.rules.sand_enabled else 0)
	var sand := PackedByteArray()
	sand.resize(4)
	sand.encode_s32(0, doc.rules.sand_height_dm)
	out.append_array(sand)
	out.append_array(u32.call(layout.region_total()))
	for loc in layout.region_locations():
		for v in [loc.x, loc.y]:
			var b := PackedByteArray()
			b.resize(4)
			b.encode_s32(0, v)
			out.append_array(b)
		var r := doc.get_region(loc)
		out.append_array(CanonicalEncoder.sha256(r.height_bytes()))
		out.append_array(CanonicalEncoder.sha256(r.control_bytes()))
		out.append_array(CanonicalEncoder.sha256(r.color_bytes()))
	out.append_array(CanonicalEncoder.sha256(doc.scatter.encode()))
	out.append_array(CanonicalEncoder.sha256(PathRecord.encode_all(doc.paths)))
	out.append_array(u32.call(doc.objects.size()))
	for id in doc.sorted_object_ids():
		var o := doc.get_object(id)
		out.append_array(str_of.call(o.object_id))
		out.append_array(str_of.call(o.binding_id))
		for v in o.position:
			out.append_array(f64.call(v))
		for v in o.rotation_xyzw:
			out.append_array(f64.call(v))
		out.append_array(f64.call(o.uniform_scale))
		out.append_array(str_of.call(o.grounding))
		out.append_array(f64.call(o.height_offset_m))
		out.append_array(str_of.call(o.origin))
		out.append_array(str_of.call(o.scatter_operation_id))
	return out


func test_v4_stream_follows_the_contract_layout() -> void:
	for doc in [_kat_doc(), WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, WorldLayout.km1())]:
		assert_eq(CanonicalEncoder.authored_bytes(doc), _expected_v4(doc))
	assert_eq(CanonicalEncoder.authored_bytes(_kat_doc()).slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V4\n")


func test_every_authored_layer_changes_the_hash() -> void:
	var base := CanonicalEncoder.authored_hash(_kat_doc())
	assert_ne(base, "")
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
		"object binding": func(d: WorldDocument) -> void: d.get_object("11111111-1111-4111-8111-111111111111").binding_id = d.scatter.binding_of(1),
		"binding policy": func(d: WorldDocument) -> void: d.get_object("11111111-1111-4111-8111-111111111111").binding_id = _binding_with_policy(d),
	}
	for key in edits:
		var d := _kat_doc()
		edits[key].call(d)
		assert_ne(CanonicalEncoder.authored_hash(d), base, key)


func _binding_with_policy(doc: WorldDocument) -> String:
	var b := AssetBinding.new()
	b.catalog_id = "poc_nature"
	b.catalog_version = 2
	b.catalog_sha256 = "ab".repeat(32)
	b.asset_id = SPRUCE
	b.asset_version = 1
	b.set_policy(true, "0.5", "2.5", "-1", "2")  # a different scale policy of the same asset version
	return doc.assets.add(b)


func test_unused_scatter_slots_unused_bindings_and_ids_do_not_change_the_hash() -> void:
	var a := _kat_doc()
	var b := _kat_doc()
	b.world_id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
	b.document_revision = 99
	b.scatter.add(_binding(b, "zzz.unused", 1), 0, 0, 0, 1, 0)
	b.scatter.remove_indices(PackedInt32Array([2]))
	_binding_with_policy(b)  # registered, never referenced
	assert_eq(CanonicalEncoder.authored_hash(b), CanonicalEncoder.authored_hash(a))
