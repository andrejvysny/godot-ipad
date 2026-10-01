extends TestCase
## scatter.bin structure, canonical table, byte-exact round trip (docs/world-format.md §5).


func _layer() -> ScatterLayer:
	var l := ScatterLayer.new()
	l.add("nature.tree.spruce_a", 1, 1.5, -2.25, 0.5, 1.25, 1)
	l.add("a.grass", 2, -3.0, 4.0, -1.0, 0.75, 0)
	l.add("nature.tree.spruce_a", 1, 0.1, 0.2, 0.3, 0.4, 0)  # 0.1 etc. are not f32-exact
	return l


func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b


func _str(s: String) -> PackedByteArray:
	var u := s.to_utf8_buffer()
	return _u32(u.size()) + u


## Hand-built bytes with one asset and `n` instances; `mutate` may damage the result.
func _raw(n: int, extra: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var b := "WPSC".to_ascii_buffer() + _u32(1) + _u32(1) + _str("a.grass") + _u32(1) + _u32(n)
	for i in n:
		var inst := PackedByteArray()
		inst.resize(20)
		inst.encode_float(4, 1.0)
		b.append_array(inst)
	return b + extra


func test_empty_layer_is_16_bytes() -> void:
	var bytes := ScatterLayer.new().encode()
	assert_eq(bytes, "WPSC".to_ascii_buffer() + _u32(1) + _u32(0) + _u32(0))
	assert_eq(bytes.size(), 16)
	var r := ScatterLayer.decode(bytes)
	assert_empty_string(r[1])
	assert_eq((r[0] as ScatterLayer).count(), 0)


func test_canonical_table_is_sorted_minimal_and_order_preserved() -> void:
	var l := _layer()
	var bytes := l.encode()
	var expect := "WPSC".to_ascii_buffer() + _u32(1) + _u32(2) + _str("a.grass") + _u32(2) \
		+ _str("nature.tree.spruce_a") + _u32(1) + _u32(3)
	assert_eq(bytes.slice(0, expect.size()), expect, "table sorted byte-wise by asset id")
	assert_eq(bytes.size(), expect.size() + 3 * 20)
	var r := ScatterLayer.decode(bytes)
	assert_empty_string(r[1])
	var back: ScatterLayer = r[0]
	assert_eq(back.asset_ids, PackedStringArray(["a.grass", "nature.tree.spruce_a"]))
	assert_eq(back.asset_of(0), "nature.tree.spruce_a", "instance order preserved")
	assert_eq(back.asset_of(1), "a.grass")
	assert_eq(back.version_of(1), 2)
	assert_true(back.equals(l), "equal despite different slot numbering")


func test_unused_slots_are_dropped_from_the_encoding() -> void:
	var l := _layer()
	l.remove_indices(PackedInt32Array([1]))
	assert_eq(l.asset_ids.size(), 2, "slot table keeps the unused slot")
	var back: ScatterLayer = ScatterLayer.decode(l.encode())[0]
	assert_eq(back.asset_ids, PackedStringArray(["nature.tree.spruce_a"]), "minimal table")
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
	l.add("a.grass", 1, -0.0, 1.4e-45, 0.0, 1.0, 0)
	var bytes := l.encode()
	assert_eq(ScatterLayer.decode(bytes)[0].encode(), bytes)
	assert_eq(bytes.slice(bytes.size() - 16, bytes.size() - 12), PackedByteArray([0, 0, 0, 0x80]), "-0.0 sign bit")


func test_add_stops_at_the_limit() -> void:
	var l := ScatterLayer.new()
	for i in WorldConstants.MAX_SCATTER_INSTANCES:
		l.slot.append(0)
	l.asset_ids.append("a.grass")
	l.asset_versions.append(1)
	assert_false(l.add("a.grass", 1, 0, 0, 0, 1, 0), "refused at MAX")
	assert_eq(l.count(), WorldConstants.MAX_SCATTER_INSTANCES)


func test_clone_is_deep_and_remove_preserves_order() -> void:
	var l := _layer()
	var c := l.clone()
	c.x[0] = 99.0
	assert_eq(l.x[0], 1.5, "clone does not alias")
	assert_false(l.equals(c))
	l.remove_indices(PackedInt32Array([0, 0, 7, -1]))
	assert_eq(l.count(), 2)
	assert_eq(l.asset_of(0), "a.grass")
	assert_eq(l.x[1], PackedFloat32Array([0.1])[0])


func test_malformed_inputs() -> void:
	var valid := _layer().encode()
	var bad_magic := valid.duplicate()
	bad_magic[0] = 0x58
	var bad_version := valid.duplicate()
	bad_version.encode_u32(4, 2)
	var nan := _raw(1)
	nan.encode_float(nan.size() - 8, NAN)  # yaw
	var inf := _raw(1)
	inf.encode_float(inf.size() - 4, INF)  # scale
	var bad_index := _raw(1)
	bad_index.encode_u16(bad_index.size() - 20, 1)
	var bad_flags := _raw(1)
	bad_flags.encode_u16(bad_flags.size() - 18, 2)
	var over := _raw(1)
	over.encode_u32(over.size() - 24, WorldConstants.MAX_SCATTER_INSTANCES + 1)
	var unused := "WPSC".to_ascii_buffer() + _u32(1) + _u32(1) + _str("a.grass") + _u32(1) + _u32(0)
	var unsorted := "WPSC".to_ascii_buffer() + _u32(1) + _u32(2) + _str("b") + _u32(1) + _str("a") + _u32(1) + _u32(0)
	var dup := "WPSC".to_ascii_buffer() + _u32(1) + _u32(2) + _str("a") + _u32(1) + _str("a") + _u32(1) + _u32(0)
	var cases := [
		["bad magic", bad_magic], ["unsupported version", bad_version],
		["trailing", valid + PackedByteArray([0])], ["trailing", _raw(1, PackedByteArray([1, 2]))],
		["truncated", valid.slice(0, valid.size() - 1)], ["truncated", PackedByteArray()],
		["truncated", "WPSC".to_ascii_buffer()], ["non-finite", nan], ["non-finite", inf],
		["asset_index", bad_index], ["flag", bad_flags], ["exceed the limit", over],
		["no instance uses", unused], ["not sorted", unsorted], ["not sorted", dup],
	]
	for c in cases:
		var r := ScatterLayer.decode(c[1])
		assert_eq(r[0], null, c[0])
		assert_error_contains(r[1], c[0], c[0])
	assert_empty_string(ScatterLayer.decode(_raw(1))[1], "hand-built control case is valid")
