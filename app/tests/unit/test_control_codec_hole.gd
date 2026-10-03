extends TestCase
## ControlCodec.encode round-trips the hole bit that decode reports (FG-06 finding).


func test_encode_sets_and_clears_hole_bit() -> void:
	var v := ControlCodec.encode(0x00000001, {"hole": true})
	assert_true(ControlCodec.decode(v).hole, "hole set")
	assert_eq(v & 0xFFFFFFFF & ~ControlCodec.HOLE_BIT, 0x00000001, "other bits kept")
	assert_false(ControlCodec.decode(ControlCodec.encode(v, {"hole": false})).hole, "hole cleared")
