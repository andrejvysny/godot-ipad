extends TestCase
## paths.bin structure, sort order, uuid and range errors (docs/world-format.md §6).

const ID_A := "11111111-1111-4111-8111-111111111111"
const ID_B := "22222222-2222-4222-8222-222222222222"


func _rec(id: String, width: float, pts: PackedVector2Array) -> PathRecord:
	var r := PathRecord.new()
	r.path_id = id
	r.width_m = width
	r.points = pts
	return r


func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b


func _str(s: String) -> PackedByteArray:
	var u := s.to_utf8_buffer()
	return _u32(u.size()) + u


func _f32s(vals: Array) -> PackedByteArray:
	return PackedFloat32Array(vals).to_byte_array()


## One hand-built path record body.
func _body(id: String, width: float, pts: Array) -> PackedByteArray:
	var flat: Array = []
	for p: Vector2 in pts:
		flat.append(p.x)
		flat.append(p.y)
	return _str(id) + _f32s([width]) + _u32(pts.size()) + _f32s(flat)


func _file(bodies: Array, count: int = -1) -> PackedByteArray:
	var b := "WPPA".to_ascii_buffer() + _u32(1) + _u32(bodies.size() if count < 0 else count)
	for x: PackedByteArray in bodies:
		b.append_array(x)
	return b


func test_empty_file_is_12_bytes() -> void:
	var bytes := PathRecord.encode_all({})
	assert_eq(bytes, "WPPA".to_ascii_buffer() + _u32(1) + _u32(0))
	assert_eq(bytes.size(), 12)
	assert_eq((PathRecord.decode_all(bytes)[0] as Dictionary).size(), 0)


func test_round_trip_sorted_and_byte_exact() -> void:
	var a := _rec(ID_A, 1.0, PackedVector2Array([Vector2(0.1, 0.2), Vector2(10, -4.25)]))
	var b := _rec(ID_B, 6.0, PackedVector2Array([Vector2(1, 1), Vector2(2, 2), Vector2(3, 5)]))
	var bytes := PathRecord.encode_all({ID_B: b, ID_A: a})  # dictionary order is irrelevant
	assert_eq(bytes, _file([_body(ID_A, 1.0, [Vector2(0.1, 0.2), Vector2(10, -4.25)]),
		_body(ID_B, 6.0, [Vector2(1, 1), Vector2(2, 2), Vector2(3, 5)])]), "sorted by id, f32")
	var r := PathRecord.decode_all(bytes)
	assert_empty_string(r[1])
	var back: Dictionary = r[0]
	assert_true((back[ID_A] as PathRecord).equals(a))
	assert_true((back[ID_B] as PathRecord).equals(b))
	assert_eq(PathRecord.encode_all(back), bytes, "byte exact")


func test_width_is_held_f32_rounded() -> void:
	var r := _rec(ID_A, 0.1, PackedVector2Array())
	assert_eq(r.width_m, PackedFloat32Array([0.1])[0])
	assert_ne(r.width_m, 0.1)


func test_clone_and_bounds() -> void:
	var a := _rec(ID_A, 2.0, PackedVector2Array([Vector2(-5, 3), Vector2(7, -1)]))
	var c := a.clone()
	c.points[0] = Vector2(9, 9)
	assert_eq(a.points[0], Vector2(-5, 3), "clone does not alias")
	assert_false(a.equals(c))
	assert_eq(a.bounds(), Rect2(-5, -1, 12, 4))


func test_malformed_inputs() -> void:
	var good := _body(ID_A, 2.0, [Vector2(0, 0), Vector2(1, 1)])
	var nan_pt := _body(ID_A, 2.0, [Vector2(0, 0), Vector2(NAN, 1)])
	var cases := [
		["bad magic", "WPPX".to_ascii_buffer() + _u32(1) + _u32(0)],
		["unsupported version", "WPPA".to_ascii_buffer() + _u32(2) + _u32(0)],
		["trailing", _file([good]) + PackedByteArray([0])],
		["truncated", _file([good]).slice(0, 40)],
		["truncated", _file([good], 2)],
		["exceed the limit", "WPPA".to_ascii_buffer() + _u32(1) + _u32(WorldConstants.MAX_PATHS + 1)],
		["not a lowercase UUID", _file([_body("not-a-uuid", 2.0, [Vector2(0, 0), Vector2(1, 1)])])],
		["not a lowercase UUID", _file([_body("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", 2.0, [Vector2(0, 0), Vector2(1, 1)])])],
		["not sorted", _file([_body(ID_B, 2.0, [Vector2(0, 0), Vector2(1, 1)]), good])],
		["not sorted", _file([good, good])],
		["width", _file([_body(ID_A, 0.5, [Vector2(0, 0), Vector2(1, 1)])])],
		["width", _file([_body(ID_A, 6.5, [Vector2(0, 0), Vector2(1, 1)])])],
		["width", _file([_body(ID_A, NAN, [Vector2(0, 0), Vector2(1, 1)])])],
		["points", _file([_body(ID_A, 2.0, [Vector2(0, 0)])])],
		["points", _file([_body(ID_A, 2.0, [])])],
		["not finite", _file([nan_pt])],
	]
	var many: Array = []
	for i in 257:
		many.append(Vector2(i, 0))
	cases.append(["points", _file([_body(ID_A, 2.0, many)])])
	for c in cases:
		var r := PathRecord.decode_all(c[1])
		assert_eq(r[0], null, c[0])
		assert_error_contains(r[1], c[0], c[0])
	assert_empty_string(PathRecord.decode_all(_file([good]))[1], "control case")
