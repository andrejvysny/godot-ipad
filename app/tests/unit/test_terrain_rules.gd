extends TestCase
## Auto-paint rules: manifest parsing, ranges, exact keys, integral JSON numbers.


func _good() -> Dictionary:
	return {"rock_enabled": true, "rock_slope_deg": 30.0, "sand_enabled": true, "sand_height_dm": -4.0}


func test_defaults_and_round_trip() -> void:
	var d := TerrainRules.defaults()
	assert_true(d.rock_enabled and d.sand_enabled)
	assert_eq(d.rock_slope_deg, 30)
	assert_eq(d.sand_height_dm, -4)
	assert_eq(d.to_dict(), {"rock_enabled": true, "rock_slope_deg": 30, "sand_enabled": true, "sand_height_dm": -4})
	var parsed := TerrainRules.from_dict(JSON.parse_string(JSON.stringify(d.to_dict())))
	assert_empty_string(parsed[1])
	assert_true((parsed[0] as TerrainRules).equals(d), "float-typed JSON numbers accepted")


## material_at is the CPU mirror of the shader rule (hard edges).
func test_material_at_follows_rules() -> void:
	var doc := WorldDocument.create_flat(5.0, ControlCodec.default_value())
	assert_eq(TerrainRules.material_at(doc, 10.0, 10.0), WorldConstants.MATERIAL_GRASS, "flat high ground")
	assert_eq(TerrainRules.material_at(doc, 500.0, 0.0), -1, "outside the world")
	doc.get_region(Vector2i(0, 0)).heights.fill(-1.0)
	assert_eq(TerrainRules.material_at(doc, 10.0, 10.0), WorldConstants.MATERIAL_SAND, "below -0.4 m")
	doc.rules.sand_enabled = false
	assert_eq(TerrainRules.material_at(doc, 10.0, 10.0), WorldConstants.MATERIAL_GRASS, "sand rule off")
	var region := doc.get_region(Vector2i(0, 0))
	for gz in 256:
		for gx in 256:
			region.heights[gz * 256 + gx] = float(gx) * 0.5  # 45 degrees along X
	assert_eq(TerrainRules.material_at(doc, 20.0, 20.0), WorldConstants.MATERIAL_ROCK, "45 degrees > 30")
	doc.rules.rock_slope_deg = 60
	assert_eq(TerrainRules.material_at(doc, 20.0, 20.0), WorldConstants.MATERIAL_GRASS, "45 degrees < 60")
	doc.rules.rock_slope_deg = 10
	doc.rules.rock_enabled = false
	assert_eq(TerrainRules.material_at(doc, 20.0, 20.0), WorldConstants.MATERIAL_GRASS, "rock rule off")


func test_clone_is_independent() -> void:
	var a := TerrainRules.defaults()
	var b := a.clone()
	b.rock_slope_deg = 55
	assert_eq(a.rock_slope_deg, 30)
	assert_false(a.equals(b))
	assert_false(a.equals(null))


func test_bounds_are_inclusive() -> void:
	for pair in [[10.0, -30.0], [60.0, 30.0]]:
		var d := _good()
		d.rock_slope_deg = pair[0]
		d.sand_height_dm = pair[1]
		assert_empty_string(TerrainRules.from_dict(d)[1], str(pair))


func test_rejections() -> void:
	var cases := {
		"rock_slope_deg 9": func(d: Dictionary) -> void: d.rock_slope_deg = 9.0,
		"rock_slope_deg 61": func(d: Dictionary) -> void: d.rock_slope_deg = 61.0,
		"sand_height_dm -31": func(d: Dictionary) -> void: d.sand_height_dm = -31.0,
		"sand_height_dm 31": func(d: Dictionary) -> void: d.sand_height_dm = 31.0,
		"rock_slope_deg must be an integer": func(d: Dictionary) -> void: d.rock_slope_deg = 30.5,
		"sand_height_dm must be an integer": func(d: Dictionary) -> void: d.sand_height_dm = "x",
		"sand_height_dm must be an integer ": func(d: Dictionary) -> void: d.sand_height_dm = NAN,
		"rock_slope_deg must be an integer ": func(d: Dictionary) -> void: d.rock_slope_deg = null,
		"rock_enabled must be a boolean": func(d: Dictionary) -> void: d.rock_enabled = 1.0,
		"sand_enabled must be a boolean": func(d: Dictionary) -> void: d.sand_enabled = "true",
		"missing field 'sand_enabled'": func(d: Dictionary) -> void: d.erase("sand_enabled"),
		"unknown field 'extra'": func(d: Dictionary) -> void: d["extra"] = 1,
	}
	for key in cases:
		var d := _good()
		cases[key].call(d)
		var r := TerrainRules.from_dict(d)
		assert_eq(r[0], null, key)
		assert_error_contains(r[1], String(key).strip_edges(), key)
	for bad: Variant in [null, [], "rules", 5]:
		assert_error_contains(TerrainRules.from_dict(bad)[1], "must be an object", str(bad))
