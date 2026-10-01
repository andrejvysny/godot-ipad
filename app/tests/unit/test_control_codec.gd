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
	assert_true(ControlCodec.is_supported(3 << 27), "base id 3 (sand) is a material slot")
	assert_true(ControlCodec.is_supported(2 << 22), "overlay id 2 (rock) is a material slot")
	assert_false(ControlCodec.is_supported(4 << 27), "base id 4 has no material slot")
	assert_false(ControlCodec.is_supported(5 << 22), "overlay id 5 has no material slot")
	assert_eq(ControlCodec.default_value(), 0x00000001, "default: auto bit only")
	assert_true(ControlCodec.is_supported(ControlCodec.default_value()))


# --- v2 paint rules (docs/editor-v2.md §4) -----------------------------------------------

const OTHER := 0x00003FFE  # nav, hole, reserved, uv scale, uv rotation: never owned by paint


func _ctl(is_auto: bool, base: int, overlay: int, blend: int) -> int:
	return ControlCodec.encode(OTHER, {"auto": is_auto, "base_id": base, "overlay_id": overlay, "blend": blend})


## {s: start [auto, base, overlay, blend], layer, c, e: expected [auto, base, overlay, blend]}
func test_paint_layer_rule_table() -> void:
	var cases: Array[Dictionary] = [
		{"n": "rule 1 same overlay", "s": [true, 0, 1, 51], "layer": 1, "c": 0.5, "e": [true, 0, 1, 153]},
		{"n": "rule 1 manual", "s": [false, 0, 1, 51], "layer": 1, "c": 1.0, "e": [false, 0, 1, 255]},
		{"n": "rule 2 empty blend", "s": [true, 0, 0, 0], "layer": 2, "c": 0.4, "e": [true, 0, 2, 102]},
		{"n": "rule 2 keeps stored base under auto", "s": [true, 3, 0, 0], "layer": 1, "c": 1.0, "e": [true, 3, 1, 255]},
		{"n": "rule 2 manual", "s": [false, 2, 0, 0], "layer": 3, "c": 1.0, "e": [false, 2, 3, 255]},
		{"n": "rule 3 manual base fades", "s": [false, 2, 1, 200], "layer": 2, "c": 0.5, "e": [false, 2, 1, 100]},
		{"n": "rule 3 needs manual: auto base goes to rule 4", "s": [true, 2, 1, 128], "layer": 2, "c": 0.25,
				"e": [true, 2, 1, 128]},
		{"n": "rule 4 strong overlay collapses", "s": [true, 0, 1, 192], "layer": 3, "c": 0.2, "e": [false, 1, 3, 64]},
		{"n": "rule 4 collapse manual", "s": [false, 0, 1, 255], "layer": 2, "c": 1.0, "e": [false, 1, 2, 255]},
		{"n": "rule 4 below the weaker share keeps the sample", "s": [true, 0, 1, 191], "layer": 2, "c": 0.2, "e": [true, 0, 1, 191]},
		{"n": "rule 4 50/50 low coverage keeps", "s": [true, 0, 1, 128], "layer": 2, "c": 0.25, "e": [true, 0, 1, 128]},
		{"n": "rule 4 50/50 just below threshold", "s": [true, 0, 1, 128], "layer": 2, "c": 0.33, "e": [true, 0, 1, 128]},
		{"n": "rule 4 50/50 just above threshold swaps weaker", "s": [true, 0, 1, 128], "layer": 2, "c": 0.34, "e": [false, 1, 2, 129]},
		{"n": "rule 4 50/50 c 0.5", "s": [true, 0, 1, 128], "layer": 2, "c": 0.5, "e": [false, 1, 2, 170]},
		{"n": "rule 4 50/50 c 0.8", "s": [true, 0, 1, 128], "layer": 2, "c": 0.8, "e": [false, 1, 2, 227]},
		{"n": "rule 4 strong auto base is kept", "s": [true, 0, 1, 64], "layer": 3, "c": 0.5, "e": [true, 0, 3, 146]},
		{"n": "zero coverage keeps the value", "s": [true, 0, 1, 128], "layer": 2, "c": 0.0, "e": [true, 0, 1, 128]},
	]
	for k in cases:
		var s: Array = k.s
		var e: Array = k.e
		var got := ControlCodec.paint_layer(_ctl(s[0], s[1], s[2], s[3]), k.layer, k.c)
		assert_eq(got, _ctl(e[0], e[1], e[2], e[3]), str(k.n))


func test_erase_paint_rule_table() -> void:
	var cases: Array[Dictionary] = [
		{"n": "auto fades", "s": [true, 0, 1, 200], "c": 0.5, "e": [true, 0, 1, 100]},
		{"n": "auto full erase", "s": [true, 0, 1, 200], "c": 1.0, "e": [true, 0, 1, 0]},
		{"n": "manual c <= 0.5", "s": [false, 2, 1, 200], "c": 0.25, "e": [false, 2, 1, 100]},
		{"n": "manual c == 0.5 boundary", "s": [false, 2, 1, 200], "c": 0.5, "e": [false, 2, 1, 0]},
		{"n": "manual c > 0.5 restores auto", "s": [false, 2, 1, 200], "c": 0.8, "e": [true, 2, 2, 102]},
		{"n": "manual full erase", "s": [false, 2, 1, 255], "c": 1.0, "e": [true, 2, 2, 0]},
		{"n": "zero coverage keeps the value", "s": [false, 2, 1, 200], "c": 0.0, "e": [false, 2, 1, 200]},
	]
	for k in cases:
		var s: Array = k.s
		var e: Array = k.e
		assert_eq(ControlCodec.erase_paint(_ctl(s[0], s[1], s[2], s[3]), k.c), _ctl(e[0], e[1], e[2], e[3]), str(k.n))


func test_paint_and_erase_preserve_unowned_bits() -> void:
	for start_auto in [true, false]:
		for blend in [0, 100, 200, 255]:
			for c in [0.1, 0.5, 0.9, 1.0]:
				var v := _ctl(start_auto, 1, 2, blend)
				var painted := ControlCodec.paint_layer(v, 3, c)
				var erased := ControlCodec.erase_paint(v, c)
				assert_eq(painted & ~ControlCodec.PAINT_OWNED_MASK & 0xFFFFFFFF, OTHER, "paint bits %s %d %s" % [start_auto, blend, c])
				assert_eq(erased & ~ControlCodec.PAINT_OWNED_MASK & 0xFFFFFFFF, OTHER, "erase bits")
	var all_ones := ControlCodec.paint_layer(0xFFFFFFFF, 2, 0.6)
	assert_eq(all_ones & ControlCodec.U32, all_ones, "result is a uint32")


## Spray (coverage <= 0.35) and light strokes must show a third material on a two-material sample,
## and the new material's share never decreases as coverage grows.
func test_third_material_appears_and_grows_monotonically() -> void:
	for blend in [64, 128, 192]:
		var v := _ctl(false, 0, 1, blend)
		var last_share := 0.0
		var appeared_at := -1.0
		for i in range(1, 101):
			var c := float(i) / 100.0
			var out := ControlCodec.paint_layer(v, 2, c)
			var share := 0.0
			if ControlCodec.get_overlay(out) == 2:
				share = float(ControlCodec.get_blend(out)) / 255.0
			assert_true(share + 1.0 / 255.0 >= last_share, "share monotonic at blend %d c %.2f" % [blend, c])
			last_share = share
			if share > 0.0 and appeared_at < 0.0:
				appeared_at = c
		assert_true(appeared_at > 0.0 and appeared_at <= 0.34, "third material visible by c 0.34 (blend %d: %.2f)" % [blend, appeared_at])
	var spray := ControlCodec.paint_layer(_ctl(false, 0, 1, 128), 2, 0.35)
	assert_eq(ControlCodec.get_overlay(spray), 2, "full spray coverage introduces the material")
