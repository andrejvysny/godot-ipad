extends TestCase
## Prepared terrain preview textures (assets/terrain/preview) and their export (spec §11.4, §12.5, §13.2):
## one size/format/mip chain per array, the low tier's mean colour and roughness, VRAM-compressed import
## with all four channels preserved, and an export configuration that ships the shader and the textures.

const DIR := "res://assets/terrain/preview/"
const SHADER := "res://src/terrain/world_terrain.gdshader"
const MAX_PNG_BYTES := 10 * 1048576


func _path(slot: int, kind: String) -> String:
	return "%s%s_%s.png" % [DIR, TerrainMaterials.TEXTURE_NAMES[slot], kind]


func _images(kind: String) -> Array[Image]:
	var out: Array[Image] = []
	for slot in TerrainMaterials.TEXTURE_NAMES.size():
		var tex := load(_path(slot, kind)) as Texture2D
		assert_true(tex != null, "%s loads" % _path(slot, kind))
		if tex != null:
			out.append(tex.get_image())
	return out


func test_all_preview_textures_share_size_format_and_mipmaps_per_array() -> void:
	for kind in ["albedo", "normal"]:
		var images := _images(kind)
		assert_eq(images.size(), 4, kind)
		for img in images:
			assert_true(img != null, kind + " image")
			assert_eq(img.get_size(), Vector2i(1024, 1024))
			assert_true(img.has_mipmaps(), kind + " has mipmaps")
			assert_true(img.is_compressed(), kind + " is VRAM compressed")
			assert_eq(img.get_format(), images[0].get_format(), kind + " format")
			assert_eq(img.get_mipmap_count(), images[0].get_mipmap_count())
		var array := Texture2DArray.new()
		assert_eq(array.create_from_images(images), OK, kind + " builds a Texture2DArray")
		assert_eq(array.get_layers(), 4)


func test_preview_keeps_the_low_tier_mean_colour_and_roughness() -> void:
	for slot in TerrainMaterials.TEXTURE_NAMES.size():
		var albedo := (load(_path(slot, "albedo")) as Texture2D).get_image()
		albedo.decompress()
		var normal := (load(_path(slot, "normal")) as Texture2D).get_image()
		normal.decompress()
		var base: Color = TerrainMaterials.ALBEDO[slot]
		var sum := Vector3.ZERO
		var rough := 0.0
		var n := 0
		for y in range(0, 1024, 8):
			for x in range(0, 1024, 8):
				var c := albedo.get_pixel(x, y)
				sum += Vector3(c.r, c.g, c.b)
				rough += normal.get_pixel(x, y).a
				n += 1
		var mean := sum / n
		assert_near(mean.x, base.r, 0.02, "slot %d mean red" % slot)
		assert_near(mean.y, base.g, 0.02, "slot %d mean green" % slot)
		assert_near(mean.z, base.b, 0.02, "slot %d mean blue" % slot)
		assert_near(rough / n, TerrainMaterials.ROUGHNESS[slot], 0.02, "slot %d roughness (normal alpha)" % slot)
		var centre := normal.get_pixel(512, 512)
		assert_true(centre.b > 0.7, "normal points up (blue is Z): %s" % centre)


func test_import_settings_keep_all_four_channels_and_use_vram_compression() -> void:
	for slot in TerrainMaterials.TEXTURE_NAMES.size():
		for kind in ["albedo", "normal"]:
			var cfg := ConfigFile.new()
			assert_eq(cfg.load(_path(slot, kind) + ".import"), OK)
			var where := "%s %s" % [TerrainMaterials.TEXTURE_NAMES[slot], kind]
			assert_eq(cfg.get_value("params", "compress/mode"), 2, where + " VRAM compressed")
			assert_eq(cfg.get_value("params", "mipmaps/generate"), true, where + " mipmaps")
			assert_eq(cfg.get_value("params", "compress/normal_map"), 2, where + " normal-map conversion disabled")
			assert_eq(cfg.get_value("params", "process/fix_alpha_border"), false, where + " alpha is data")
			assert_eq(cfg.get_value("params", "process/premult_alpha"), false)
			assert_eq(cfg.get_value("params", "detect_3d/compress_to"), 0)


func test_committed_png_size_is_reasonable() -> void:
	var total := 0
	for slot in TerrainMaterials.TEXTURE_NAMES.size():
		for kind in ["albedo", "normal"]:
			var f := FileAccess.open(_path(slot, kind), FileAccess.READ)
			assert_true(f != null, "source PNG present")
			if f != null:
				total += f.get_length()
	print("    preview PNG sources: %.2f MiB" % (total / 1048576.0))
	assert_true(total < MAX_PNG_BYTES, "%d bytes" % total)


# --- export ------------------------------------------------------------------------------------------

static func _filter_matches(path: String, filters: String) -> bool:
	for raw in filters.split(","):
		var pattern := raw.strip_edges()
		if pattern == "":
			continue
		if not pattern.begins_with("res://") and not pattern.begins_with("*"):
			pattern = "res://" + pattern
		if path.matchn(pattern):
			return true
	return false


func test_export_presets_ship_the_shader_and_the_preview_textures() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://export_presets.cfg"), OK)
	var presets := 0
	var required: Array[String] = [SHADER]
	for slot in TerrainMaterials.TEXTURE_NAMES.size():
		for kind in ["albedo", "normal"]:
			required.append(_path(slot, kind))
			required.append(_path(slot, kind) + ".import")
	for section in cfg.get_sections():
		if section.contains(".options") or not section.begins_with("preset."):
			continue
		presets += 1
		var name := str(cfg.get_value(section, "name", section))
		assert_eq(cfg.get_value(section, "export_filter"), "all_resources", name + " exports every resource")
		var excluded := str(cfg.get_value(section, "exclude_filter", ""))
		for path in required:
			assert_false(_filter_matches(path, excluded), "%s must not exclude %s" % [name, path])
		assert_true(_filter_matches("res://tests/x.gd", excluded), name + ": the exclude filter is parsed (tests/* is excluded)")
		assert_true(_filter_matches("res://addons/terrain_3d/extras/shaders/lightweight.gdshader", excluded),
			name + ": upstream extras stay excluded")
	assert_true(presets >= 1, "at least one preset parsed")
	for path in required.slice(0, 1):
		assert_true(FileAccess.file_exists(path), path + " exists")
