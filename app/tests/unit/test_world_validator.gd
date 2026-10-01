extends TestCase
## IO-07 / IO-09: semantic validation rejects invalid authored data; grounding is report-only.

const SPRUCE_ID := "00000000-0000-4000-8000-000000000001"
const BOULDER_ID := "00000000-0000-4000-8000-000000000002"

var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]


func _record(id: String, asset_id: String, x: float, y: float, z: float) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = id
	r.asset_id = asset_id
	r.asset_version = 1
	r.set_position(x, y, z)
	r.set_yaw(0.5)
	return r


func _valid_doc() -> WorldDocument:
	var doc := WorldDocument.create_flat(2.0, ControlCodec.grass_value())
	doc.catalog_id = _catalog.catalog_id
	doc.catalog_version = _catalog.catalog_version
	doc.catalog_sha256 = _catalog.sha256
	doc.put_object(_record(SPRUCE_ID, "nature.tree.spruce_a", 10.0, 2.0, -5.0))
	var boulder := _record(BOULDER_ID, "nature.rock.boulder_a", -100.0, 2.5, 100.0)
	boulder.height_offset_m = 0.5
	doc.put_object(boulder)
	return doc


func _expect_rejected(doc: WorldDocument, needle: String) -> void:
	var errors := WorldValidator.validate(doc, _catalog)
	if not assert_false(errors.is_empty(), "expected rejection containing '%s'" % needle):
		return
	assert_error_contains("; ".join(errors), needle, needle)


func test_valid_document_passes() -> void:
	assert_eq(WorldValidator.validate(_valid_doc(), _catalog), PackedStringArray())


func test_rejects_bad_heights() -> void:
	for bad in [NAN, INF, -INF, 64.5, -32.001, 1e30]:
		var doc := _valid_doc()
		doc.get_region(Vector2i(0, -1)).heights[1234] = bad
		_expect_rejected(doc, "height[1234]")
	var edges := _valid_doc()
	edges.get_region(Vector2i(0, 0)).heights[0] = WorldConstants.HEIGHT_MIN
	edges.get_region(Vector2i(0, 0)).heights[1] = WorldConstants.HEIGHT_MAX
	edges.get_region(Vector2i(0, 0)).heights[2] = -0.0
	edges.get_region(Vector2i(0, 0)).heights[3] = 1e-38
	assert_eq(WorldValidator.validate(edges, _catalog), PackedStringArray(), "inclusive limits and tiny values")


func test_rejects_unsupported_control_ids() -> void:
	for bad in [2 << ControlCodec.BASE_SHIFT, 3 << ControlCodec.OVERLAY_SHIFT, 0x7FC00001, 0xFFFFFFFF]:
		var doc := _valid_doc()
		doc.get_region(Vector2i(-1, 0)).control[77] = bad
		_expect_rejected(doc, "control[77]")
	var ok := _valid_doc()
	# Reserved, hole, nav, uv bits and base/overlay 1 are all supported.
	ok.get_region(Vector2i(-1, 0)).control[5] = (1 << 27) | (1 << 22) | (255 << 14) | 0x3FFF
	assert_eq(WorldValidator.validate(ok, _catalog), PackedStringArray(), "supported bits")


func test_fast_mask_agrees_with_control_codec() -> void:
	for base in 32:
		for overlay in 32:
			var v := (base << 27) | (overlay << 22)
			var fast_ok := (v & WorldValidator.CONTROL_UNSUPPORTED_FAST_MASK) == 0
			assert_eq(fast_ok, ControlCodec.is_supported(v), "base %d overlay %d" % [base, overlay])


func test_rejects_bad_objects() -> void:
	var cases := {
		"uniform_scale": func(r: ObjectRecord) -> void: r.uniform_scale = 2.5,
		"uniform_scale ": func(r: ObjectRecord) -> void: r.uniform_scale = 0.0,
		"height_offset_m": func(r: ObjectRecord) -> void: r.height_offset_m = 5.0,
		"unknown asset": func(r: ObjectRecord) -> void: r.asset_id = "nature.tree.baobab",
		"incompatible": func(r: ObjectRecord) -> void: r.asset_version = 2,
		"outside the world extent": func(r: ObjectRecord) -> void: r.position[0] = 127.75,
		"outside the world extent ": func(r: ObjectRecord) -> void: r.position[2] = -128.5,
		"non-finite": func(r: ObjectRecord) -> void: r.position[1] = NAN,
		"unit quaternion": func(r: ObjectRecord) -> void: r.rotation_xyzw = PackedFloat64Array([0, 0, 0, 1.001]),
		"grounding": func(r: ObjectRecord) -> void: r.grounding = "SNAPPED",
		"origin": func(r: ObjectRecord) -> void: r.origin = "IMPORTED",
		"scatter_operation_id": func(r: ObjectRecord) -> void: r.scatter_operation_id = "abc",
	}
	for key in cases:
		var doc := _valid_doc()
		cases[key].call(doc.get_object(SPRUCE_ID))
		_expect_rejected(doc, String(key).strip_edges())


func test_rejects_catalog_identity_and_region_set() -> void:
	var doc := _valid_doc()
	doc.catalog_sha256 = "ab".repeat(32)
	_expect_rejected(doc, "incompatible catalog content hash")
	doc = _valid_doc()
	doc.catalog_version = 2
	_expect_rejected(doc, "incompatible catalog")
	doc = _valid_doc()
	doc.catalog_id = "other"
	_expect_rejected(doc, "incompatible catalog")
	doc = _valid_doc()
	doc.regions.erase(Vector2i(0, 0))
	_expect_rejected(doc, "missing region")
	doc = _valid_doc()
	doc.regions[Vector2i(1, 0)] = RegionBuffers.new(Vector2i(1, 0))
	_expect_rejected(doc, "unexpected region")
	doc = _valid_doc()
	doc.get_region(Vector2i(0, 0)).heights.resize(10)
	_expect_rejected(doc, "samples")
	doc = _valid_doc()
	doc.schema_version = 2
	_expect_rejected(doc, "schema_version")
	assert_false(WorldValidator.validate(_valid_doc(), null).is_empty(), "null catalog rejected")


func test_grounding_report_only_reports() -> void:
	var doc := _valid_doc()
	var before := CanonicalEncoder.authored_hash(doc)
	var report := WorldValidator.grounding_report(doc, _catalog)
	assert_eq(report.size(), 0, "consistent objects")
	doc.get_object(SPRUCE_ID).position[1] = 2.5
	var fixed := doc.get_object(BOULDER_ID)
	fixed.grounding = WorldConstants.GROUNDING_FIXED
	fixed.position[1] = 40.0
	before = CanonicalEncoder.authored_hash(doc)
	report = WorldValidator.grounding_report(doc, _catalog)
	assert_eq(report.size(), 1, "only the follow-terrain mismatch")
	if report.size() == 1:
		assert_eq(report[0].object_id, SPRUCE_ID)
		assert_near(report[0].expected_y, 2.0, 1e-9)
		assert_near(report[0].actual_y, 2.5, 1e-9)
		assert_near(report[0].delta, 0.5, 1e-9)
	assert_eq(CanonicalEncoder.authored_hash(doc), before, "report never modifies the document")
