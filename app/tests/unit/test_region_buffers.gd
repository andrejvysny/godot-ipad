extends TestCase
## RegionBuffers tint map (docs/world-format.md §1.2).


func test_default_color_is_white_weight_zero() -> void:
	var r := RegionBuffers.new(Vector2i(0, 0))
	assert_eq(r.color.size(), WorldConstants.REGION_MAP_BYTES)
	assert_eq(r.color.slice(0, 4), PackedByteArray([0xFF, 0xFF, 0xFF, 0x00]))
	assert_eq(r.color.slice(r.color.size() - 4), PackedByteArray([0xFF, 0xFF, 0xFF, 0x00]))
	var f := RegionBuffers.filled(Vector2i(-1, 0), 2.0, ControlCodec.default_value())
	assert_eq(f.color, r.color, "filled() gets the default tint")
	assert_eq(f.get_control(5), 1)


func test_duplicate_deep_copies_color() -> void:
	var r := RegionBuffers.new(Vector2i(0, 0))
	var d := r.duplicate_deep()
	d.color[0] = 1
	assert_eq(r.color[0], 0xFF, "original untouched")
	var bytes := r.color_bytes()
	bytes[1] = 9
	assert_eq(r.color[1], 0xFF, "color_bytes() is a copy")


func test_set_from_bytes_validates_all_three_lengths() -> void:
	var good := PackedByteArray()
	good.resize(WorldConstants.REGION_MAP_BYTES)
	var short := good.slice(0, 100)
	var r := RegionBuffers.new(Vector2i(0, 0))
	assert_error_contains(r.set_from_bytes(short, good, good), "height map")
	assert_error_contains(r.set_from_bytes(good, short, good), "control map")
	assert_error_contains(r.set_from_bytes(good, good, short), "color map")
	assert_empty_string(r.set_from_bytes(good, good, good))
	assert_eq(r.color, good)


func test_document_color_sample_packs_rgba() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.default_value())
	assert_eq(doc.get_color_at_sample(0, 0), 0xFFFFFF00)
	var r := doc.get_region(Vector2i(-1, -1))
	r.color[(255 * 256 + 255) * 4 + 3] = 128
	r.color[(255 * 256 + 255) * 4] = 1
	assert_eq(doc.get_color_at_sample(-1, -1), 0x01FFFF80)
	assert_eq(doc.get_color_at_sample(300, 0), -1, "outside the loaded regions")
	var copy := doc.duplicate_deep()
	copy.get_region(Vector2i(-1, -1)).color[0] = 0
	assert_eq(doc.get_region(Vector2i(-1, -1)).color[0], 0xFF)
	assert_true(copy.rules.equals(doc.rules) and copy.rules != doc.rules, "rules cloned")
	assert_true(copy.scatter != doc.scatter, "scatter cloned")
