class_name TerrainBake
extends RefCounted
## Terrain3D of an accepted world (ADR 0017 A4): a node whose data directory holds the regions filled from the
## exact height/control/tint buffers through the same region builder the editor uses (TerrainAdapter.build_region),
## saved with Terrain3D's own save API. Material and texture assets are saved beside the data (text resources, so the
## staged paths can be normalized to the final directory; textures are binary leaves). The world material
## parameters are written as the shader's authored values (headless runs have no shader parameter list).


## Adds the Terrain3D node under `root`. Returns "" or an error.
static func build(ctx: BakeContext, root: Node3D) -> String:
	var started := Time.get_ticks_usec()
	var doc := ctx.doc
	if doc.regions.is_empty() or not WorldConstants.host_is_little_endian():
		return "the world has no terrain regions or the host is not little-endian"
	var custom_error: String = TerrainMaterials.load_custom()[1]
	if custom_error != "":
		return custom_error
	var dir_res := ctx.generated_res().path_join("terrain")
	var err := StorageFs.make_dir(ProjectSettings.globalize_path(dir_res))
	if err != "":
		return err
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.free_editor_textures = false
	terrain.region_size = Terrain3D.SIZE_256
	terrain.vertex_spacing = WorldConstants.SAMPLE_SPACING
	terrain.save_16_bit = false  # exact float32 heights
	err = _attach_resources(terrain, doc, dir_res)
	if err == "":
		terrain.collision_mode = BakeContext.TERRAIN_COLLISION.get(ctx.terrain_collision, 1)
		err = _fill_and_save(ctx, terrain, dir_res)
	if err != "":
		terrain.free()
		return err
	root.add_child(terrain)
	terrain.owner = root
	ctx.stats.regions = doc.regions.size()
	ctx.time("terrain", started)
	return ""


static func shader_parameters(doc: WorldDocument) -> Dictionary:
	var rules := doc.rules
	var low := doc.layout.world_min()
	var high := doc.layout.world_max_sample()
	return {&"blend_sharpness": TerrainMaterials.BLEND_SHARPNESS,
		&"rules_rock_enabled": rules.rock_enabled, &"rules_rock_slope_deg": float(rules.rock_slope_deg),
		&"rules_sand_enabled": rules.sand_enabled, &"rules_sand_height_m": rules.sand_height_dm / 10.0,
		&"rules_highlight": false, &"terrain_world_bounds": Vector4(low.x, low.y, high.x, high.y)}


static func _attach_resources(terrain: Terrain3D, doc: WorldDocument, dir_res: String) -> String:
	var material := TerrainAdapter.create_material()
	material.set("_shader_parameters", shader_parameters(doc))
	var assets := TerrainMaterials.create_assets()
	var files: Array = [[material, "material.tres"], [assets, "assets.tres"]]
	for id in TerrainMaterials.TEXTURE_NAMES.size():
		var asset := assets.get_texture(id)
		files.append([asset.albedo_texture, "textures/%s_albedo.res" % asset.name])
		files.append([asset.normal_texture, "textures/%s_normal.res" % asset.name])
	var err := StorageFs.make_dir(ProjectSettings.globalize_path(dir_res.path_join("textures")))
	# Textures first: Terrain3D warns about textures that are not backed by a file, and the scene should refer to
	# files, not embedded copies. Assets are saved last so they refer to the saved textures.
	files.reverse()
	for entry: Array in files:
		var res: Resource = entry[0]
		res.resource_path = dir_res.path_join(entry[1])
		if err == "" and ResourceSaver.save(res, res.resource_path) != OK:
			err = "cannot save %s" % res.resource_path
	terrain.material = material
	terrain.assets = assets
	return err


## Region files are written with Terrain3DRegion.save (no tree needed: Terrain3D is not usable before the tree is
## ready, e.g. inside a command-line script's _initialize). Terrain3D finds them again by file name.
static func _fill_and_save(ctx: BakeContext, terrain: Terrain3D, dir_res: String) -> String:
	for loc in ctx.doc.sorted_region_locations():
		var region := TerrainAdapter.build_region(ctx.doc.get_region(loc))
		region.calc_height_range()
		if region.save(dir_res.path_join(region_file(loc)), false) != OK:
			return "cannot save the terrain region %s" % loc
	terrain.data_directory = dir_res
	return ""


## Terrain3D's own naming (Util::location_to_filename): "_%02d" for a non-negative coordinate, "%03d" otherwise.
static func region_file(loc: Vector2i) -> String:
	return "terrain3d%s%s.res" % [_axis(loc.x), _axis(loc.y)]


## The location a region file name stands for, or Vector2i.MAX when it is not one.
static func region_of_file(file: String) -> Vector2i:
	var rx := RegEx.create_from_string("^terrain3d(_\\d\\d|-\\d\\d)(_\\d\\d|-\\d\\d)\\.res$")
	var m := rx.search(file)
	if m == null:
		return Vector2i.MAX
	return Vector2i(m.get_string(1).trim_prefix("_").to_int(), m.get_string(2).trim_prefix("_").to_int())


static func _axis(v: int) -> String:
	return "_%02d" % v if v >= 0 else "%03d" % v
