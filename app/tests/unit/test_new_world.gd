extends TestCase
## New 1 km worlds (SessionWorldOps.new_layout_world): layout, identity, deterministic relief,
## generation cost. Desktop headless timing only.

var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func _make(kind: String, seed_value: int = HillsTerrain.DEFAULT_SEED) -> WorldDocument:
	var made := SessionWorldOps.new_layout_world(WorldLayout.km1(), kind, _catalog, seed_value)
	assert_empty_string(str(made[1]), kind)
	return made[0]


func test_flat_world_is_a_valid_km1_world() -> void:
	var doc := _make("flat")
	assert_true(doc.layout.equals(WorldLayout.km1()))
	assert_eq(doc.schema_version, 4)
	assert_eq(doc.source_schema, 4)
	assert_eq(doc.regions.size(), 64)
	assert_eq(doc.document_revision, 0)
	assert_eq(doc.source_label, "new:km1-flat")
	assert_true(ObjectRecord.is_uuid(doc.world_id))
	assert_true(doc.assets.catalog == _catalog, "bundled bindings resolve against the trusted catalog")
	assert_eq(doc.assets.size(), 0)
	assert_eq(CanonicalEncoder.authored_hash(doc), "6295548902d79118d95fcac7c1c9940a326533456dc8edf0b50b5aa0f87b205e",
			"the km1_flat_empty vector of contracts/world-painter/world-v4")
	assert_true(doc.rules.equals(TerrainRules.defaults()), "default rules")
	assert_true(doc.objects.is_empty() and doc.paths.is_empty() and doc.scatter.count() == 0)
	assert_eq(doc.height_range(), Vector2(0.0, 0.0), "height 0 everywhere")
	assert_eq(doc.get_control_at_sample(-1024, 1023), WorldConstants.DEFAULT_CONTROL)
	assert_eq(doc.get_color_at_sample(1023, -1024), 0xFFFFFF00, "default tint")
	assert_eq(WorldValidator.validate(doc, _catalog), PackedStringArray())


func test_hills_world_is_deterministic_gentle_and_in_range() -> void:
	var t0 := Time.get_ticks_usec()
	var doc := _make("hills")
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("    TIMING new km1 hills world: %.1f ms (desktop headless)" % ms)
	assert_eq(doc.source_label, "new:km1-hills")
	assert_eq(doc.regions.size(), 64)
	var span := doc.height_range()
	assert_true(span.x >= WorldConstants.HEIGHT_MIN and span.y <= WorldConstants.HEIGHT_MAX, "inside the format range %s" % str(span))
	assert_true(span.x >= HillsTerrain.MIN_M - 3.0 and span.y <= HillsTerrain.MAX_M + 3.0, "near the grid range %s" % str(span))
	assert_true(span.y - span.x > 8.0, "real relief %s" % str(span))
	assert_eq(WorldValidator.validate(doc, _catalog), PackedStringArray())
	var again := _make("hills")
	assert_ne(again.world_id, doc.world_id, "fresh world id")
	assert_eq(CanonicalEncoder.authored_hash(again), CanonicalEncoder.authored_hash(doc), "same seed, same terrain")
	for loc in doc.layout.region_locations():
		assert_eq(again.get_region(loc).heights, doc.get_region(loc).heights, "region %s" % str(loc))
	var other := _make("hills", HillsTerrain.DEFAULT_SEED + 1)
	assert_ne(CanonicalEncoder.authored_hash(other), CanonicalEncoder.authored_hash(doc), "other seed differs")


func test_hills_are_continuous_across_every_region_seam() -> void:
	var doc := _make("hills")
	var worst := 0.0
	for g in [-768, -512, -256, 0, 256, 512, 768]:
		for k in [-1000, -333, 0, 17, 600, 1000]:
			worst = maxf(worst, absf(doc.get_height_at_sample(g, k) - doc.get_height_at_sample(g - 1, k)))
			worst = maxf(worst, absf(doc.get_height_at_sample(k, g) - doc.get_height_at_sample(k, g - 1)))
	assert_true(worst < 1.0, "neighbouring samples across seams differ by %.3f m" % worst)


func test_unknown_kind_and_missing_catalog_are_errors() -> void:
	assert_error_contains(str(SessionWorldOps.new_layout_world(WorldLayout.km1(), "volcano", _catalog)[1]), "unknown world kind")
	assert_error_contains(str(SessionWorldOps.new_layout_world(WorldLayout.km1(), "flat", null)[1]), "catalog")


func test_other_layouts_work_too() -> void:
	var custom := WorldLayout.create(Vector2i(2, -3), Vector2i(3, 2))
	var made := SessionWorldOps.new_layout_world(custom, "hills", _catalog)
	assert_empty_string(str(made[1]))
	var doc: WorldDocument = made[0]
	assert_eq(doc.regions.size(), 6)
	assert_eq(doc.source_label, "new:custom-hills")
	assert_eq(WorldValidator.validate(doc, _catalog), PackedStringArray())
