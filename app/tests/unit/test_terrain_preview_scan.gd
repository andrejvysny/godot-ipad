extends TestCase
## Which material slots a preview area uses (spec §11.2: prioritise materials actually used in the area).

const AUTO := WorldConstants.DEFAULT_CONTROL


func _doc(painter: Callable) -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	for loc: Vector2i in doc.regions:
		var r: RegionBuffers = doc.regions[loc]
		for j in WorldConstants.REGION_SAMPLES:
			for i in WorldConstants.REGION_SAMPLES:
				painter.call(r, (loc.x * 256 + i) * 0.5, (loc.y * 256 + j) * 0.5, j * 256 + i)
	doc.invalidate_all_height_ranges()
	return doc


func test_flat_auto_world_uses_only_grass() -> void:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	var w := TerrainPreviewScan.slot_weights(doc, Vector2.ZERO, 20.0)
	assert_true(w[0] > 1000.0, "grass covers the circle: %s" % w)
	assert_eq([w[1], w[2], w[3]], [0.0, 0.0, 0.0])
	assert_eq(TerrainPreviewScan.select_slots(w, 4), PackedInt32Array([0]))


func test_auto_bit_samples_use_the_rule_evaluation() -> void:
	var doc := _doc(func(r: RegionBuffers, x: float, z: float, k: int) -> void:
		if x < 0.0:
			r.heights[k] = -3.0  # below the sand height
		elif x > 10.0:
			r.heights[k] = (x - 10.0) * 1.7320508)  # 60 degree ramp: rock
	var w := TerrainPreviewScan.slot_weights(doc, Vector2(0.0, 0.0), 20.0)
	assert_true(w[3] > 100.0, "sand basin counted: %s" % w)
	assert_true(w[2] > 100.0, "rock slope counted: %s" % w)
	assert_true(w[0] > 100.0, "flat part is grass: %s" % w)
	assert_eq(w[1], 0.0, "no dirt anywhere")
	var slots := TerrainPreviewScan.select_slots(w, 4)
	assert_eq(slots.size(), 3)
	var best := 0
	for slot in 4:
		best = slot if w[slot] > w[best] else best
	assert_eq(slots[0], best, "largest coverage first")
	var rules := doc.rules.clone()
	rules.rock_enabled = false
	rules.sand_enabled = false
	doc.rules = rules
	assert_eq(TerrainPreviewScan.select_slots(TerrainPreviewScan.slot_weights(doc, Vector2.ZERO, 20.0), 4), PackedInt32Array([0]),
		"rules off: everything reads grass")


func test_manual_base_and_overlay_ids_count_with_their_blend() -> void:
	var doc := _doc(func(r: RegionBuffers, x: float, z: float, k: int) -> void:
		if x >= 0.0 and x < 6.0 and absf(z) < 6.0:
			r.control[k] = ControlCodec.encode(0, {"base_id": WorldConstants.MATERIAL_ROCK, "overlay_id": WorldConstants.MATERIAL_DIRT, "blend": 128})
		elif x >= 6.0 and x < 12.0 and absf(z) < 6.0:
			r.control[k] = ControlCodec.encode(AUTO, {"overlay_id": WorldConstants.MATERIAL_SAND, "blend": 255}))
	var w := TerrainPreviewScan.slot_weights(doc, Vector2(6.0, 0.0), 8.0)
	assert_true(w[2] > 10.0 and w[1] > 10.0, "manual base rock + dirt overlay: %s" % w)
	assert_true(w[3] > 10.0, "overlay over an auto sample counts: %s" % w)
	assert_true(w[0] > 1.0, "auto base grass under the overlay edge")


func test_selection_orders_by_coverage_and_respects_the_maximum() -> void:
	var w := PackedFloat32Array([5.0, 50.0, 20.0, 20.0])
	assert_eq(TerrainPreviewScan.select_slots(w, 4), PackedInt32Array([1, 2, 3, 0]), "ties go to the lower id")
	assert_eq(TerrainPreviewScan.select_slots(w, 2), PackedInt32Array([1, 2]))
	assert_eq(TerrainPreviewScan.select_slots(w, 0), PackedInt32Array([1]), "at least one slot")
	assert_eq(TerrainPreviewScan.select_slots(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]), 4), PackedInt32Array([0]),
		"an area without samples falls back to grass")


func test_holes_and_outside_the_world_are_not_counted() -> void:
	var doc := _doc(func(r: RegionBuffers, x: float, z: float, k: int) -> void:
		if x >= 0.0 and x < 6.0 and absf(z) < 6.0:
			r.control[k] = ControlCodec.encode(0, {"base_id": WorldConstants.MATERIAL_ROCK}) | ControlCodec.HOLE_BIT)
	var w := TerrainPreviewScan.slot_weights(doc, Vector2(3.0, 0.0), 2.0)
	assert_eq(w[2], 0.0, "hole samples render nothing")
	var far := TerrainPreviewScan.slot_weights(doc, Vector2(9000.0, 9000.0), 20.0)
	assert_eq(far, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	assert_eq(TerrainPreviewScan.slot_weights(doc, Vector2(NAN, 0.0), 20.0), PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))


func test_scan_cost_is_bounded() -> void:
	var doc := WorldDocument.create_flat(0.0, AUTO)
	var t0 := Time.get_ticks_usec()
	TerrainPreviewScan.slot_weights(doc, Vector2.ZERO, 20.0)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("    preview slot scan r=20 m: %.1f ms" % ms)
	assert_true(ms < 250.0, "scan took %.1f ms" % ms)
