extends TestCase
## TE-01 / TE-02 known vectors for the Terrain3D 1.0.2 control layout.


func test_known_vector_decode() -> void:
	# base 3, overlay 17, blend 200, uv rot 5, uv scale 6, reserved bit 4, nav, auto
	var v := (3 << 27) | (17 << 22) | (200 << 14) | (5 << 10) | (6 << 7) | (1 << 4) | 0x2 | 0x1
	var d := ControlCodec.decode(v)
	assert_eq(d.base_id, 3, "base")
	assert_eq(d.overlay_id, 17, "overlay")
	assert_eq(d.blend, 200, "blend")
	assert_eq(d.auto, true, "auto")
	assert_eq(d.hole, false, "hole")
	assert_eq(d.other_bits, (5 << 10) | (6 << 7) | (1 << 4) | 0x2, "other bits")


func test_encode_preserves_unrelated_bits() -> void:
	var existing := 0xFFFFFFFF
	var v := ControlCodec.encode(existing, {"blend": 7})
	assert_eq(ControlCodec.get_blend(v), 7, "blend")
	assert_eq(v | ControlCodec.FIELD_MASK_BLEND, 0xFFFFFFFF, "other bits untouched")
	var p := ControlCodec.encode_paint(0xFFFFFFFF, 128)
	assert_eq(ControlCodec.get_base(p), 0, "paint base grass")
	assert_eq(ControlCodec.get_overlay(p), 1, "paint overlay dirt")
	assert_eq(ControlCodec.get_blend(p), 128, "paint blend")
	assert_eq(p & ControlCodec.AUTO_BIT, 0, "auto cleared")
	var others := ~ControlCodec.PAINT_OWNED_MASK & 0xFFFFFFFF
	assert_eq(p & others, 0xFFFFFFFF & others, "reserved/uv/hole/nav bits preserved")


func test_matches_terrain3d_util_when_available() -> void:
	if not ClassDB.class_exists("Terrain3DUtil"):
		return
	for v in [0x0, 0x12345678, 0xFFFFFFFF, 0x7FC00001, 0x80000000, (1 << 22) | (255 << 14)]:
		assert_eq(ControlCodec.get_base(v), int(ClassDB.class_call_static("Terrain3DUtil", "get_base", v)), "base %x" % v)
		assert_eq(ControlCodec.get_overlay(v), int(ClassDB.class_call_static("Terrain3DUtil", "get_overlay", v)), "overlay %x" % v)
		assert_eq(ControlCodec.get_blend(v), int(ClassDB.class_call_static("Terrain3DUtil", "get_blend", v)), "blend %x" % v)


func test_nan_like_patterns_survive_image_round_trip() -> void:
	var patterns := [0x7FC00001, 0xFFFFFFFF, 0x7F800000, 0xFF800000, 0x7FBFFFFF, 0x00000001, 0x80000000]
	var ctrl := PackedInt32Array()
	ctrl.resize(WorldConstants.REGION_SAMPLE_COUNT)
	for i in ctrl.size():
		ctrl[i] = patterns[i % patterns.size()]
	var img := ControlCodec.control_to_image(ctrl)
	assert_eq(img.get_format(), Image.FORMAT_RF, "format")
	var back := ControlCodec.image_to_control(img)
	assert_true(back == ctrl, "bit patterns preserved through Image")
	for i in patterns.size():
		assert_eq(back[i] & 0xFFFFFFFF, patterns[i], "pattern %d" % i)


func test_quantize_and_dirt_blend() -> void:
	assert_eq(ControlCodec.quantize_blend(0.0), 0)
	assert_eq(ControlCodec.quantize_blend(1.0), 255)
	assert_eq(ControlCodec.quantize_blend(0.5), 128)
	assert_eq(ControlCodec.quantize_blend(-3.0), 0)
	assert_near(ControlCodec.dirt_blend01(ControlCodec.encode_paint(0, 255)), 1.0, 1e-9)
	assert_near(ControlCodec.dirt_blend01(ControlCodec.grass_value()), 0.0, 1e-9)


func test_supported_layout() -> void:
	assert_true(ControlCodec.is_supported(ControlCodec.grass_value()))
	assert_false(ControlCodec.is_supported(2 << 27), "base id 2 has no material slot")
	assert_false(ControlCodec.is_supported(5 << 22), "overlay id 5 has no material slot")
