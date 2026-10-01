extends TestCase
## Tint-map rules (docs/editor-v2.md §4).

const DRY := Vector3i(200, 180, 84)
const LUSH := Vector3i(38, 108, 40)
const AUTUMN := Vector3i(192, 110, 48)


func test_presets() -> void:
	assert_eq(TintCodec.PRESETS.size(), 3)
	assert_eq([TintCodec.preset_name(0), TintCodec.preset_name(1), TintCodec.preset_name(2)], ["Dry", "Lush", "Autumn"])
	assert_eq([TintCodec.preset_rgb(0), TintCodec.preset_rgb(1), TintCodec.preset_rgb(2)], [DRY, LUSH, AUTUMN])


func test_pack_round_trip() -> void:
	var v := TintCodec.pack(AUTUMN, 77)
	assert_eq(v, (192 << 24) | (110 << 16) | (48 << 8) | 77)
	assert_eq([TintCodec.rgb_of(v), TintCodec.alpha_of(v)], [AUTUMN, 77])


func test_tint_rule_table() -> void:
	var cases: Array[Dictionary] = [
		{"n": "untinted builds", "s": TintCodec.pack(Vector3i(255, 255, 255), 0), "c": 0.5, "e": TintCodec.pack(DRY, 128)},
		{"n": "untinted full", "s": TintCodec.pack(AUTUMN, 0), "c": 1.0, "e": TintCodec.pack(DRY, 255)},
		{"n": "same colour accumulates", "s": TintCodec.pack(DRY, 100), "c": 0.5, "e": TintCodec.pack(DRY, 178)},
		{"n": "same colour saturates", "s": TintCodec.pack(DRY, 255), "c": 1.0, "e": TintCodec.pack(DRY, 255)},
		{"n": "other colour fades first", "s": TintCodec.pack(LUSH, 200), "c": 0.25, "e": TintCodec.pack(LUSH, 100)},
		{"n": "other colour c == 0.5", "s": TintCodec.pack(LUSH, 200), "c": 0.5, "e": TintCodec.pack(LUSH, 0)},
		{"n": "other colour replaced", "s": TintCodec.pack(LUSH, 200), "c": 0.75, "e": TintCodec.pack(DRY, 128)},
		{"n": "other colour full replace", "s": TintCodec.pack(LUSH, 200), "c": 1.0, "e": TintCodec.pack(DRY, 255)},
	]
	for k in cases:
		assert_eq(TintCodec.tint(k.s, DRY, k.c), k.e, str(k.n))


func test_untint_keeps_colour_and_fades_weight() -> void:
	var s := TintCodec.pack(LUSH, 200)
	assert_eq(TintCodec.untint(s, 0.5), TintCodec.pack(LUSH, 100))
	assert_eq(TintCodec.untint(s, 1.0), TintCodec.pack(LUSH, 0))
	assert_eq(TintCodec.untint(s, 0.0), s)
	assert_eq(TintCodec.untint(TintCodec.pack(LUSH, 0), 1.0), TintCodec.pack(LUSH, 0))
