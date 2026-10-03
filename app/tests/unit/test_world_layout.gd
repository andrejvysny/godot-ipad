extends TestCase
## WorldLayout rules (docs/world-format.md §11.1), WORLD-02 sampling on the km1 layout, and the
## cross-language authored-hash vector (§11.5). Python computes the same vector in
## scripts/tests/test_layout_format.py.

## km1 flat world: the schema 3 stream with the bundled catalog identity (verified on legacy reads) and the
## schema 4 stream (contracts/world-painter/world-v4 km1_flat_empty). Both come from the Python implementation.
const KM1_FLAT_VECTOR := "f1357e481f58e3076704020e211bea87471db121c067170e50b8de88d1816d92"
const KM1_FLAT_VECTOR_V4 := "6295548902d79118d95fcac7c1c9940a326533456dc8edf0b50b5aa0f87b205e"

var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func test_validate_rejects_out_of_range_layouts() -> void:
	assert_empty_string(WorldLayout.validate(Vector2i(-4, -4), Vector2i(8, 8)), "km1")
	assert_empty_string(WorldLayout.validate(Vector2i(-1, -1), Vector2i(2, 2)), "legacy is valid here")
	assert_empty_string(WorldLayout.validate(Vector2i(-8, -8), Vector2i(1, 1)), "min corner")
	assert_empty_string(WorldLayout.validate(Vector2i(7, 7), Vector2i(1, 1)), "max corner")
	assert_empty_string(WorldLayout.validate(Vector2i(0, -8), Vector2i(8, 8)), "touches both limits")
	var bad := {
		"count 0 x": [Vector2i(0, 0), Vector2i(0, 1)],
		"count 0 z": [Vector2i(0, 0), Vector2i(1, 0)],
		"count 9 x": [Vector2i(-4, -4), Vector2i(9, 1)],
		"count 9 z": [Vector2i(-4, -4), Vector2i(1, 9)],
		"count negative": [Vector2i(0, 0), Vector2i(-1, 2)],
		"min -9 x": [Vector2i(-9, 0), Vector2i(1, 1)],
		"min -9 z": [Vector2i(0, -9), Vector2i(1, 1)],
		"min 8": [Vector2i(8, 0), Vector2i(1, 1)],
		"min+count > 8 x": [Vector2i(1, -4), Vector2i(8, 8)],
		"min+count > 8 z": [Vector2i(-4, 5), Vector2i(1, 4)],
		"min 7 count 2": [Vector2i(7, 0), Vector2i(2, 1)],
	}
	for key in bad:
		assert_ne(WorldLayout.validate(bad[key][0], bad[key][1]), "", key)
		assert_eq(WorldLayout.create(bad[key][0], bad[key][1]), null, key)


func test_presets_and_derived_values() -> void:
	var legacy := WorldLayout.legacy()
	assert_true(legacy.is_legacy())
	assert_eq(legacy.schema_version(), 4, "every layout is written as schema 4")
	assert_eq(legacy.legacy_schema_version(), 2)
	assert_eq(legacy.name(), "legacy")
	var legacy_locations: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]
	assert_eq(legacy.region_locations(), legacy_locations, "legacy order: Z then X")
	assert_eq(legacy.global_sample_min(), Vector2i(-256, -256))
	assert_eq(legacy.global_sample_max(), Vector2i(255, 255))
	assert_eq(legacy.world_min(), Vector2(-128.0, -128.0))
	assert_eq(legacy.world_max_sample(), Vector2(127.5, 127.5))
	assert_eq(legacy.extent_rect(), Rect2(-128.0, -128.0, 256.0, 256.0))
	assert_eq(WorldLayout.km1().extent_rect(), Rect2(-512.0, -512.0, 1024.0, 1024.0))
	var km := WorldLayout.km1()
	assert_eq(km.schema_version(), 4)
	assert_eq(km.legacy_schema_version(), 3)
	assert_eq(km.name(), "km1")
	assert_eq(km.region_total(), 64)
	assert_eq(km.region_locations()[0], Vector2i(-4, -4))
	assert_eq(km.region_locations()[1], Vector2i(-3, -4), "X varies fastest")
	assert_eq(km.region_locations()[8], Vector2i(-4, -3))
	assert_eq(km.region_locations()[63], Vector2i(3, 3))
	assert_eq(km.global_sample_min(), Vector2i(-1024, -1024))
	assert_eq(km.global_sample_max(), Vector2i(1023, 1023))
	assert_eq(km.world_min(), Vector2(-512.0, -512.0))
	assert_eq(km.world_max_sample(), Vector2(511.5, 511.5))
	assert_eq(km.world_rect(), Rect2(-512.0, -512.0, 1023.5, 1023.5))
	assert_true(km.is_valid_region(Vector2i(-4, 3)) and not km.is_valid_region(Vector2i(4, 0)) and not km.is_valid_region(Vector2i(0, -5)))
	assert_true(km.is_valid_sample(-1024, 1023) and not km.is_valid_sample(-1025, 0) and not km.is_valid_sample(0, 1024))
	assert_true(km.is_inside_world(-512.0, 511.5) and not km.is_inside_world(-512.01, 0.0) and not km.is_inside_world(0.0, 511.51))
	var custom := WorldLayout.create(Vector2i(2, 3), Vector2i(3, 1))
	assert_eq(custom.name(), "custom")
	assert_eq(custom.schema_version(), 4)
	assert_eq(custom.legacy_schema_version(), 3)
	assert_eq(custom.world_min(), Vector2(256.0, 384.0))
	assert_eq(custom.world_max_sample(), Vector2(639.5, 511.5))
	assert_true(custom.equals(WorldLayout.new(Vector2i(2, 3), Vector2i(3, 1))) and not custom.equals(km) and not custom.equals(null))


func test_manifest_round_trip_and_rejections() -> void:
	var km := WorldLayout.km1()
	var back := WorldLayout.from_manifest(JSON.parse_string(JSON.stringify(km.to_manifest())))
	assert_empty_string(back[1])
	assert_true(km.equals(back[0]))
	var legacy := WorldLayout.from_manifest(WorldLayout.legacy().to_manifest())
	assert_true(legacy[0] != null and legacy[0].is_legacy(), "from_manifest does not reject legacy")
	var cases := {
		"object": 5,
		"unknown field": {"min_region": [0, 0], "region_count": [1, 1], "x": 1},
		"missing field": {"min_region": [0, 0]},
		"two integers": {"min_region": [0, 0.5], "region_count": [1, 1]},
		"two integers ": {"min_region": [0], "region_count": [1, 1]},
		"two integers  ": {"min_region": "0,0", "region_count": [1, 1]},
		"two integers   ": {"min_region": [0, 0], "region_count": [1, null]},
		"region_count": {"min_region": [0, 0], "region_count": [0, 1]},
		"min_region": {"min_region": [-9, 0], "region_count": [1, 1]},
	}
	for key in cases:
		var r := WorldLayout.from_manifest(cases[key])
		assert_eq(r[0], null, key)
		assert_error_contains(r[1], String(key).strip_edges(), key)


# --- WORLD-02 ---------------------------------------------------------------------------

func _km_doc() -> WorldDocument:
	return WorldDocument.create_flat(0.0, ControlCodec.grass_value(), WorldLayout.km1())


## Plane h = 0.01 * gx + 0.02 * gz keeps bilinear interpolation exact (up to float32 storage).
func _plane(gx: int, gz: int) -> float:
	return 0.01 * gx + 0.02 * gz


func _stamp_plane(doc: WorldDocument, x: float, z: float) -> void:
	var gx := floori(x / 0.5)
	var gz := floori(z / 0.5)
	for dz in 2:
		for dx in 2:
			var sx := gx + dx
			var sz := gz + dz
			if doc.layout.is_valid_sample(sx, sz):
				var r := doc.get_region(Vector2i(sx >> 8, sz >> 8))
				r.heights[(sz & 255) * 256 + (sx & 255)] = _plane(sx, sz)


func test_km1_flat_document_has_all_regions() -> void:
	var doc := _km_doc()
	assert_eq(doc.regions.size(), 64)
	assert_eq(doc.schema_version, 4)
	assert_eq(doc.layout.name(), "km1")
	assert_eq(doc.duplicate_deep().layout, doc.layout, "duplicate keeps the layout")
	assert_eq(doc.get_height_at_sample(-1024, -1024), 0.0)
	assert_eq(doc.get_control_at_sample(1023, 1023), ControlCodec.grass_value())
	assert_eq(doc.get_color_at_sample(5, 5), 0xFFFFFF00, "default tint FF FF FF 00")


func test_sampling_is_continuous_and_bilinear_at_every_region_seam() -> void:
	var doc := _km_doc()
	var seams := [-384.0, -256.0, -128.0, 0.0, 128.0, 256.0, 384.0]
	var points: Array[Vector2] = []
	for seam: float in seams:
		for off in [-0.25, 0.0, 0.25]:
			for other in [-300.0, 17.25, 255.75]:
				points.append(Vector2(seam + off, other))
				points.append(Vector2(other, seam + off))
	for p in points:
		_stamp_plane(doc, p.x, p.y)
	for p in points:
		var expected := 0.01 * (p.x / 0.5) + 0.02 * (p.y / 0.5)
		assert_near(doc.sample_height(p.x, p.y), expected, 1e-4, "plane at %s" % str(p))
	# Explicit bilinear formula across the x = 0 seam at z = 17.25.
	var tx := 0.5
	var h00 := doc.get_height_at_sample(-1, 34)
	var h10 := doc.get_height_at_sample(0, 34)
	var h01 := doc.get_height_at_sample(-1, 35)
	var h11 := doc.get_height_at_sample(0, 35)
	var by_hand := lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), 0.0)
	assert_near(doc.sample_height(-0.25, 17.0), by_hand, 1e-6, "formula across the seam")


func test_extent_edges_are_exact_and_just_outside_is_nan() -> void:
	var doc := _km_doc()
	_stamp_plane(doc, -512.0, -512.0)
	_stamp_plane(doc, 511.5, 511.5)
	_stamp_plane(doc, 511.5, 100.25)
	_stamp_plane(doc, 100.25, 511.5)
	assert_eq(doc.sample_height(-512.0, -512.0), doc.get_height_at_sample(-1024, -1024), "min edge exact")
	assert_eq(doc.sample_height(511.5, 511.5), doc.get_height_at_sample(1023, 1023), "max edge exact")
	# Max edge with a fractional weight on the other axis clamps the missing +1 neighbour.
	var expected := lerpf(doc.get_height_at_sample(1023, 200), doc.get_height_at_sample(1023, 201), 0.5)
	assert_near(doc.sample_height(511.5, 100.25), expected, 1e-6, "x max edge clamp")
	expected = lerpf(doc.get_height_at_sample(200, 1023), doc.get_height_at_sample(201, 1023), 0.5)
	assert_near(doc.sample_height(100.25, 511.5), expected, 1e-6, "z max edge clamp")
	for p in [Vector2(-512.01, 0.0), Vector2(0.0, -512.01), Vector2(511.51, 0.0), Vector2(0.0, 511.51), Vector2(-600.0, 600.0)]:
		assert_true(is_nan(doc.sample_height(p.x, p.y)), "outside %s" % str(p))
		assert_true(is_nan(doc.sample_normal(p.x, p.y).x), "normal outside %s" % str(p))
	assert_false(is_nan(doc.sample_height(-512.0, 511.5)), "corner")


func test_sample_accessors_cover_exactly_the_layout() -> void:
	var doc := _km_doc()
	for g in [-1024, 1023]:
		assert_false(is_nan(doc.get_height_at_sample(g, 0)), "x %d valid" % g)
		assert_false(is_nan(doc.get_height_at_sample(0, g)), "z %d valid" % g)
		assert_ne(doc.get_control_at_sample(g, g), -1)
	for g in [-1025, 1024]:
		assert_true(is_nan(doc.get_height_at_sample(g, 0)), "x %d outside" % g)
		assert_true(is_nan(doc.get_height_at_sample(0, g)), "z %d outside" % g)
		assert_eq(doc.get_control_at_sample(g, 0), -1)
		assert_eq(doc.get_color_at_sample(0, g), -1)


func test_holes_are_still_no_sample_on_km1() -> void:
	var doc := _km_doc()
	var loc := Vector2i(-4, -4)
	var r := doc.get_region(loc)
	r.control[(3 * 256) + 2] = ControlCodec.grass_value() | ControlCodec.HOLE_BIT
	var x := (-1024 + 2) * 0.5
	var z := (-1024 + 3) * 0.5
	assert_true(is_nan(doc.sample_height(x + 0.1, z + 0.1)), "inside the hole cell")
	assert_false(is_nan(doc.sample_height(x + 1.1, z + 0.1)), "next cell")
	assert_eq(doc.get_height_at_sample(-1022, -1021), 0.0, "raw height unchanged")


func test_non_origin_layout_samples_its_own_extent() -> void:
	var layout := WorldLayout.create(Vector2i(2, 3), Vector2i(1, 1))
	var doc := WorldDocument.create_flat(1.5, ControlCodec.grass_value(), layout)
	assert_eq(doc.regions.size(), 1)
	assert_eq(doc.sample_height(256.0, 384.0), 1.5)
	assert_eq(doc.sample_height(383.5, 511.5), 1.5)
	assert_true(is_nan(doc.sample_height(0.0, 0.0)), "legacy origin is outside this layout")
	assert_true(is_nan(doc.sample_height(255.9, 400.0)))


# --- WORLD-03 limits -------------------------------------------------------------------

func test_limits_table() -> void:
	var v2 := WorldLimits.for_schema(2)
	var v3 := WorldLimits.for_schema(3)
	var v4 := WorldLimits.for_schema(4)
	assert_eq(v2.max_objects, 2000)
	assert_eq(v3.max_objects, 50000)
	assert_eq(v4.max_objects, 50000)
	assert_eq(v2.max_scatter_instances, 20000)
	assert_eq(v3.max_scatter_instances, 100000)
	assert_eq(v4.max_scatter_instances, 100000)
	assert_eq(v3.max_entries, 4 + 1 + 3 * 64, "schema 3 fits 4 fixed files, regions/ and 64 regions")
	assert_eq(v4.max_entries, v3.max_entries + 1, "schema 4 adds asset_locks.json")
	assert_eq(v4.max_lock_bytes, 8 * 1024 * 1024)
	assert_eq(v4.max_bindings, 4096)
	assert_eq(v3.max_regions, 64)
	for key: String in v3:
		if key != "max_entries":
			assert_eq(v4[key], v3[key], "schema 4 keeps the schema 3 limit " + key)
	assert_eq(WorldLimits.zip_envelope(), v4)
	assert_eq(WorldLimits.for_schema(1), {})
	assert_eq(WorldLimits.for_schema(5), {})


func test_validator_applies_the_schema_object_limit() -> void:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value(), WorldLayout.create(Vector2i(0, 0), Vector2i(1, 1)), _catalog)
	for i in 50001:
		var r := ObjectRecord.new()
		r.object_id = "00000000-0000-4000-8000-%012d" % i
		doc.objects[r.object_id] = r
	assert_error_contains("; ".join(WorldValidator.validate(doc, _catalog)), "50001 objects exceed the limit of 50000")
	var legacy := WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, _catalog)
	for i in 2001:
		var r := ObjectRecord.new()
		r.object_id = "00000000-0000-4000-8000-%012d" % i
		legacy.objects[r.object_id] = r
	assert_false("; ".join(WorldValidator.validate(legacy, _catalog)).contains("exceed the limit"),
			"the legacy layout is schema 4 now: the schema 3 object limit applies")


func test_validator_rejects_schema_mismatch_and_uses_layout_extent() -> void:
	var layout := WorldLayout.create(Vector2i(2, 3), Vector2i(1, 1))
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value(), layout, _catalog)
	assert_eq(WorldValidator.validate(doc, _catalog), PackedStringArray(), "valid custom layout")
	var inside := ObjectRecord.new()
	inside.object_id = "11111111-1111-4111-8111-111111111111"
	inside.binding_id = doc.assets.bundled_binding_for("nature.rock.boulder_a")
	inside.set_position(300.0, 0.0, 400.0)
	doc.put_object(inside)
	assert_eq(WorldValidator.validate(doc, _catalog), PackedStringArray(), "object inside the layout extent")
	assert_empty_string(WorldValidator.validate_object(inside, doc.assets, layout))
	assert_error_contains(WorldValidator.validate_object(inside, doc.assets, WorldLayout.legacy()), "outside the world extent", "legacy extent")
	doc.schema_version = 2
	assert_error_contains("; ".join(WorldValidator.validate(doc, _catalog)), "schema_version 2")
	var bad := WorldDocument.create_flat(0.0, ControlCodec.grass_value())
	bad.schema_version = 3
	assert_error_contains("; ".join(WorldValidator.validate(bad, _catalog)), "schema_version 3")


# --- §11.5 vector ----------------------------------------------------------------------

func test_km1_flat_authored_hash_vectors() -> void:
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, WorldLayout.km1(), _catalog)
	assert_eq(CanonicalEncoder.authored_bytes(doc).slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V4\n")
	assert_eq(CanonicalEncoder.authored_hash(doc), KM1_FLAT_VECTOR_V4)
	assert_eq(CanonicalEncoder.legacy_authored_bytes(doc)[0].slice(0, 17).get_string_from_ascii(), "WPOC-AUTHORED-V3\n")
	assert_eq(CanonicalEncoder.legacy_authored_hash(doc)[0], KM1_FLAT_VECTOR, "the schema 3 stream of the same world")
