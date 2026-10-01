extends TestCase
## Procedural brush alphas (docs/editor-v2.md §3).


func test_soft_circle_matches_continuous_falloff() -> void:
	for q: float in [0.0, 0.3, 0.5, 0.9, 0.999]:
		assert_near(BrushAlpha.weight("soft", "circle", q * 4.0, 0.0, Vector2.ZERO, 4.0),
				BrushMath.falloff(q), 1e-12, "q=%s" % q)
	assert_true(BrushAlpha.is_exact_soft("soft", "circle"))
	assert_false(BrushAlpha.is_exact_soft("soft", "stamp"))


func test_every_shape_is_bounded_and_zero_outside() -> void:
	for shape: String in BrushAlpha.SHAPES:
		for mode: String in BrushAlpha.MODES:
			assert_eq(BrushAlpha.weight(shape, mode, 4.0, 0.0, Vector2.ZERO, 4.0), 0.0, "%s/%s edge" % [shape, mode])
			assert_eq(BrushAlpha.weight(shape, mode, 9.0, 3.0, Vector2.ZERO, 4.0), 0.0, "%s/%s outside" % [shape, mode])
			for i in 50:
				var w := BrushAlpha.weight(shape, mode, cos(i) * 3.5, sin(i * 1.3) * 3.5, Vector2.ZERO, 4.0, 0.4)
				assert_true(w >= 0.0 and w <= 1.0, "%s/%s in range" % [shape, mode])


func test_shape_profiles() -> void:
	assert_eq(BrushAlpha.shape_weight("hard", 0.5, 0.0), 1.0, "hard core")
	assert_near(BrushAlpha.shape_weight("hard", 0.91, 0.0), 0.5, 1e-9, "hard rim midpoint")
	assert_near(BrushAlpha.shape_weight("ring", 0.66, 0.0), 1.0, 1e-12, "ring peak")
	assert_true(BrushAlpha.shape_weight("ring", 0.0, 0.0) < 0.01, "ring centre empty")
	assert_near(BrushAlpha.shape_weight("splat", 0.0, 0.0), 1.0, 1e-12, "splat centre blob")
	assert_eq(BrushAlpha.shape_weight("streak", 0.0, 0.5), 0.0, "streak is thin across")
	assert_true(BrushAlpha.shape_weight("streak", 0.6, 0.0) > BrushAlpha.shape_weight("streak", -0.6, 0.0),
			"streak brighter toward +u")


func test_stamp_rotates_with_angle() -> void:
	var along := BrushAlpha.weight("streak", "stamp", 0.0, 2.0, Vector2.ZERO, 4.0, PI * 0.5)
	var across := BrushAlpha.weight("streak", "stamp", 2.0, 0.0, Vector2.ZERO, 4.0, PI * 0.5)
	assert_true(along > 0.3, "streak follows a +Z stroke")
	assert_eq(across, 0.0, "nothing across the rotated streak")


func test_pattern_tiles_in_world_space() -> void:
	var tile := BrushAlpha.pattern_tile(4.0)
	assert_near(tile, 2.8, 1e-12)
	var a := BrushAlpha.weight("hard", "pattern", 0.3 + tile * 0.5, 0.4, Vector2(0.5, 0.0), 4.0)
	var b := BrushAlpha.weight("hard", "pattern", 0.3 + tile * 0.5, 0.4, Vector2(-0.5, 0.0), 4.0)
	assert_near(a, b, 1e-12, "weight depends on world position, not dab centre, inside the fade")
	assert_near(BrushAlpha.pattern_tile(1.0), BrushAlpha.PATTERN_MIN_TILE_M, 1e-12, "minimum tile")


func test_noise_is_deterministic_and_bounded() -> void:
	assert_eq(BrushAlpha.value_noise(3.7, -1.2), BrushAlpha.value_noise(3.7, -1.2))
	for i in 100:
		var n := BrushAlpha.value_noise(i * 0.37, i * -0.91)
		assert_true(n >= 0.0 and n <= 1.0)


func test_preview_image_alpha() -> void:
	var img := BrushAlpha.preview_image("soft", "circle", 32)
	assert_eq(img.get_size(), Vector2i(32, 32))
	assert_true(img.get_pixel(16, 16).a > 0.9, "centre opaque")
	assert_eq(img.get_pixel(0, 0).a, 0.0, "corner transparent")
