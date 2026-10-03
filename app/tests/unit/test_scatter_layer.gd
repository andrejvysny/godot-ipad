extends TestCase
## scatter.bin v2 structure (binding table), canonical table, byte-exact round trip (docs/world-format.md §12);
## v1 decoding and encoding for schema 2/3 conversion.

const GRASS := "b11111111111111111111111111111111"
const SPRUCE := "b22222222222222222222222222222222"


func _layer() -> ScatterLayer:
	var l := ScatterLayer.new()
	l.add(SPRUCE, 1.5, -2.25, 0.5, 1.25, 1)
	l.add(GRASS, -3.0, 4.0, -1.0, 0.75, 0)
	l.add(SPRUCE, 0.1, 0.2, 0.3, 0.4, 0)  # 0.1 etc. are not f32-exact
	return l


func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b


func _str(s: String) -> PackedByteArray:
	var u := s.to_utf8_buffer()
	return _u32(u.size()) + u


## Hand-built v2 bytes with one binding and `n` instances; callers damage the result.
func _raw(n: int, extra: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var b := "WPSC".to_ascii_buffer() + _u32(2) + _u32(1) + _str(GRASS) + _u32(n)
	for i in n:
		var inst := PackedByteArray()
		inst.resize(20)
		inst.encode_float(4, 1.0)
		b.append_array(inst)
	return b + extra


func test_empty_layer_is_16_bytes() -> void:
	var bytes := ScatterLayer.new().encode()
	assert_eq(bytes, "WPSC".to_ascii_buffer() + _u32(2) + _u32(0) + _u32(0))
	assert_eq(bytes.size(), 16)
	var r := ScatterLayer.decode(bytes)
	assert_empty_string(r[1])
	assert_eq((r[0] as ScatterLayer).count(), 0)


func test_canonical_table_is_sorted_minimal_and_order_preserved() -> void:
	var l := _layer()
	var bytes := l.encode()
	var expect := "WPSC".to_ascii_buffer() + _u32(2) + _u32(2) + _str(GRASS) + _str(SPRUCE) + _u32(3)
	assert_eq(bytes.slice(0, expect.size()), expect, "table sorted byte-wise by binding id")
	assert_eq(bytes.size(), expect.size() + 3 * 20)
	var r := ScatterLayer.decode(bytes)
	assert_empty_string(r[1])
	var back: ScatterLayer = r[0]
	assert_eq(back.binding_ids, PackedStringArray([GRASS, SPRUCE]))
	assert_eq(back.binding_of(0), SPRUCE, "instance order preserved")
	assert_eq(back.binding_of(1), GRASS)
	assert_true(back.equals(l), "equal despite different slot numbering")


func test_unused_slots_are_dropped_from_the_encoding() -> void:
	var l := _layer()
	l.remove_indices(PackedInt32Array([1]))
	assert_eq(l.binding_ids.size(), 2, "slot table keeps the unused slot")
	var back: ScatterLayer = ScatterLayer.decode(l.encode())[0]
	assert_eq(back.binding_ids, PackedStringArray([SPRUCE]), "minimal table")
	assert_eq(back.count(), 2)
	assert_eq(back.x[1], l.x[1])


func test_round_trip_is_byte_exact_with_f32_rounding() -> void:
	var l := _layer()
	var bytes := l.encode()
	var back: ScatterLayer = ScatterLayer.decode(bytes)[0]
	assert_eq(back.encode(), bytes, "decode(encode(x)).encode() == encode(x)")
	assert_eq(l.x[2], PackedFloat32Array([0.1])[0], "stored as float32")
	assert_eq(back.x, l.x)
	assert_eq(back.yaw, l.yaw)
	assert_eq(back.scale, l.scale)
	assert_eq(back.flags, l.flags)


func test_negative_zero_and_denormals_survive() -> void:
	var l := ScatterLayer.new()
	l.add(GRASS, -0.0, 1.4e-45, 0.0, 1.0, 0)
	var bytes := l.encode()
	assert_eq(ScatterLayer.decode(bytes)[0].encode(), bytes)
	assert_eq(bytes.slice(bytes.size() - 16, bytes.size() - 12), PackedByteArray([0, 0, 0, 0x80]), "-0.0 sign bit")


func test_add_stops_at_the_limit() -> void:
	var l := ScatterLayer.new()
	for i in WorldConstants.MAX_SCATTER_INSTANCES:
		l.slot.append(0)
	l.binding_ids.append(GRASS)
	assert_false(l.add(GRASS, 0, 0, 0, 1, 0), "refused at MAX")
	assert_eq(l.count(), WorldConstants.MAX_SCATTER_INSTANCES)


func test_clone_is_deep_and_remove_preserves_order() -> void:
	var l := _layer()
	var c := l.clone()
	c.x[0] = 99.0
	assert_eq(l.x[0], 1.5, "clone does not alias")
	assert_false(l.equals(c))
	l.remove_indices(PackedInt32Array([0, 0, 7, -1]))
	assert_eq(l.count(), 2)
	assert_eq(l.binding_of(0), GRASS)
	assert_eq(l.x[1], PackedFloat32Array([0.1])[0])


func test_malformed_inputs() -> void:
	var valid := _layer().encode()
	var bad_magic := valid.duplicate()
	bad_magic[0] = 0x58
	var bad_version := valid.duplicate()
	bad_version.encode_u32(4, 3)
	var nan := _raw(1)
	nan.encode_float(nan.size() - 8, NAN)  # yaw
	var inf := _raw(1)
	inf.encode_float(inf.size() - 4, INF)  # scale
	var bad_index := _raw(1)
	bad_index.encode_u16(bad_index.size() - 20, 1)
	var bad_flags := _raw(1)
	bad_flags.encode_u16(bad_flags.size() - 18, 2)
	var over := _raw(1)
	over.encode_u32(over.size() - 24, int(WorldLimits.SCHEMA_4.max_scatter_instances) + 1)
	var unused := "WPSC".to_ascii_buffer() + _u32(2) + _u32(1) + _str(GRASS) + _u32(0)
	var unsorted := "WPSC".to_ascii_buffer() + _u32(2) + _u32(2) + _str(SPRUCE) + _str(GRASS) + _u32(0)
	var dup := "WPSC".to_ascii_buffer() + _u32(2) + _u32(2) + _str(GRASS) + _str(GRASS) + _u32(0)
	var not_binding := "WPSC".to_ascii_buffer() + _u32(2) + _u32(1) + _str("a.grass") + _u32(0)
	var v1 := "WPSC".to_ascii_buffer() + _u32(1) + _u32(0) + _u32(0)
	var cases := [
		["bad magic", bad_magic], ["unsupported version", bad_version],
		["trailing", valid + PackedByteArray([0])], ["trailing", _raw(1, PackedByteArray([1, 2]))],
		["truncated", valid.slice(0, valid.size() - 1)], ["truncated", PackedByteArray()],
		["truncated", "WPSC".to_ascii_buffer()], ["non-finite", nan], ["non-finite", inf],
		["binding_index", bad_index], ["flag", bad_flags], ["exceed the limit", over],
		["no instance uses", unused], ["not sorted", unsorted], ["not sorted", dup],
		["is not a binding id", not_binding], ["unsupported version 1", v1],
	]
	for c in cases:
		var r := ScatterLayer.decode(c[1])
		assert_eq(r[0], null, c[0])
		assert_error_contains(r[1], c[0], c[0])
	assert_empty_string(ScatterLayer.decode(_raw(1))[1], "hand-built control case is valid")


## scatter.bin v1 (schema 2/3): the table carries asset ids and versions; the layer keeps the asset ids so
## the codec can map them to bindings, and encode_legacy_v1 reproduces the bytes.
func test_legacy_v1_decode_and_reencode() -> void:
	var v1 := "WPSC".to_ascii_buffer() + _u32(1) + _u32(2) + _str("a.grass") + _u32(2) + _str("nature.tree.spruce_a") \
		+ _u32(1) + _u32(2)
	for i in 2:
		var inst := PackedByteArray()
		inst.resize(20)
		inst.encode_u16(0, 1 - i)
		inst.encode_float(4, 1.0 + i)
		inst.encode_float(16, 1.0)
		v1.append_array(inst)
	var r := ScatterLayer.decode_legacy_v1(v1, 20000)
	assert_empty_string(r[1])
	var layer: ScatterLayer = r[0]
	assert_eq(layer.binding_ids, PackedStringArray(["a.grass", "nature.tree.spruce_a"]))
	assert_eq(r[2], PackedInt32Array([2, 1]))
	assert_eq(layer.binding_of(0), "nature.tree.spruce_a", "order preserved")
	var mapping := {"a.grass": ["a.grass", 2], "nature.tree.spruce_a": ["nature.tree.spruce_a", 1]}
	assert_eq(layer.encode_legacy_v1(mapping), v1, "byte-exact re-encoding")
	assert_error_contains(ScatterLayer.decode(v1)[1], "unsupported version 1", "v2 decoder refuses v1")
	assert_error_contains(ScatterLayer.decode_legacy_v1(_raw(1), 20000)[1], "unsupported version 2", "v1 decoder refuses v2")
