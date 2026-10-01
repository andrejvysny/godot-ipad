class_name TerrainAdapter
extends TerrainView
## The only code that mutates Terrain3D (spec §4.1, §11.1). Terrain3D region Images are
## a runtime projection of WorldDocument bytes: the document is edited first, callers then
## mark_dirty(kind, region) and the adapter copies the document bytes into the region
## Image in place and re-uploads only the edited regions of that map kind.
##
## Pinned Terrain3D 1.0.2 behavior this relies on (terrain_3d_data.cpp update_maps):
## update_maps(type, false, false) re-uploads only regions whose `edited` flag is set and
## emits height_maps_changed / control_maps_changed once per such region; it does not
## recompute height ranges, so the adapter does that before uploading heights.
## Changing an Image alone never refreshes the GPU texture array.

## Index = value of the shader's debug_view uniform.
const DEBUG_VIEWS := ["normal", "control_blend", "heightmap", "normals"]
const UPLOAD_TYPES := [Terrain3DRegion.TYPE_HEIGHT, Terrain3DRegion.TYPE_CONTROL, Terrain3DRegion.TYPE_COLOR]
const UPLOAD_STATS := ["uploads_height", "uploads_control", "uploads_color"]
const SHADER_PATH := "res://src/terrain/world_terrain.gdshader"

var _terrain: Terrain3D
var _camera: Camera3D
var _doc: WorldDocument
var _regions: Dictionary = {}  # Vector2i -> Terrain3DRegion
var _dirty: Array[Dictionary] = [{}, {}, {}]  # per map kind: Vector2i -> true
var _last_upload_frame: PackedInt64Array = PackedInt64Array([-1, -1, -1])
var _rules: TerrainRules = TerrainRules.defaults()
var _rule_highlight := false
var _stats: Dictionary = {}
var _debug_view := "normal"
var _region_grid := false
var _original_render_layers := -1


func _init() -> void:
	# Deferred uploads run from _process; they must not stall while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_reset_stats()


func _process(_delta: float) -> void:
	if has_pending_uploads():
		flush()


## Builds (or rebuilds) all Terrain3D regions from `doc`. Must be called inside the tree.
## Call set_camera() before the first physics frame; Terrain3D logs an error otherwise.
func initialize(doc: WorldDocument) -> String:
	if not is_inside_tree():
		return "TerrainAdapter must be inside the scene tree before initialize()"
	var err := _validate_document(doc)
	if err != "":
		return err
	if _terrain == null:
		_create_terrain()
	_load_regions(doc)
	set_rules(doc.rules)
	return ""


## Loads another world into the existing Terrain3D node.
func replace_document(doc: WorldDocument) -> String:
	return initialize(doc)


func mark_dirty(kind: int, loc: Vector2i) -> String:
	if not MAP_KINDS.has(kind):
		return "unknown map kind %d" % kind
	if not _regions.has(loc):
		return "region %s is not loaded" % loc
	_dirty[kind][loc] = true
	return ""


func has_pending_uploads() -> bool:
	return not (_dirty[MAP_HEIGHT].is_empty() and _dirty[MAP_CONTROL].is_empty() and _dirty[MAP_COLOR].is_empty())


## Uploads dirty regions, at most once per map kind per process frame. Work for a kind that
## already uploaded this frame stays pending and is flushed by _process on the next frame.
func flush() -> void:
	if not has_pending_uploads() or _terrain == null:
		return
	var t0 := Time.get_ticks_usec()
	var frame := Engine.get_process_frames()
	var uploaded := false
	for kind: int in MAP_KINDS:
		if _dirty[kind].is_empty() or _last_upload_frame[kind] == frame:
			continue
		_upload(kind)
		_last_upload_frame[kind] = frame
		uploaded = true
	if uploaded:
		_stats.last_flush_ms = (Time.get_ticks_usec() - t0) / 1000.0


## Pushes the world's auto-paint rules to the shader. Cheap; call on every rules change.
func set_rules(rules: TerrainRules) -> void:
	_rules = rules.clone() if rules != null else TerrainRules.defaults()
	_apply_rule_uniforms()


func set_rule_highlight(on: bool) -> void:
	_rule_highlight = on
	_apply_rule_uniforms()


func get_rule_highlight() -> bool:
	return _rule_highlight


func set_camera(cam: Camera3D) -> void:
	_camera = cam
	if _terrain != null and cam != null:
		_terrain.set_camera(cam)


func set_debug_view(mode: String) -> String:
	if not DEBUG_VIEWS.has(mode):
		return "unknown debug view '%s' (expected one of %s)" % [mode, DEBUG_VIEWS]
	_debug_view = mode
	_apply_debug_state()
	return ""


func get_debug_view() -> String:
	return _debug_view


func set_region_grid(on: bool) -> void:
	_region_grid = on
	_apply_debug_state()


func get_terrain() -> Terrain3D:
	return _terrain


func get_document() -> WorldDocument:
	return _doc


## Render benchmark hook: hides the terrain (render_layers 0, original restored) and/or stops
## it casting shadows.
func set_render_probe(visible_now: bool, cast_shadows: bool) -> String:
	if _terrain == null:
		return "Terrain is not initialized."
	if _original_render_layers < 0:
		_original_render_layers = _terrain.render_layers
	_terrain.render_layers = _original_render_layers if visible_now else 0
	_terrain.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else RenderingServer.SHADOW_CASTING_SETTING_OFF
	return ""


## uploads_* count region layers re-uploaded by partial flushes since initialize.
func stats() -> Dictionary:
	return _stats.duplicate()


## Compares every Terrain3D region image with the document bytes. Pending (unflushed)
## edits are reported as mismatches by design.
func verify_matches_document(doc: WorldDocument) -> PackedStringArray:
	var out := PackedStringArray()
	if _terrain == null or _terrain.data == null:
		out.append("terrain is not initialized")
		return out
	var data := _terrain.data
	for loc in data.get_region_locations():
		if not doc.regions.has(loc):
			out.append("Terrain3D has region %s that the document does not" % loc)
	for loc in doc.sorted_region_locations():
		var region: Terrain3DRegion = data.get_region(loc)
		if region == null or region.deleted:
			out.append("region %s missing in Terrain3D" % loc)
			continue
		var rb := doc.get_region(loc)
		_compare_map(out, loc, "height", region.get_height_map(), rb.height_bytes())
		_compare_map(out, loc, "control", region.get_control_map(), rb.control_bytes())
		_compare_map(out, loc, "color", region.get_color_map(), rb.color_bytes(), Image.FORMAT_RGBA8)
	return out


## Reads back every uploaded Terrain3D texture-array layer and compares it with the document
## bytes. Proves the GPU texture layers == document (upload path); it does not prove shader
## binding or rendered pixels. Layer i belongs to data.get_region_locations()[i].
## Empty = verified; "NOT RUN: ..." entries mean the check could not run.
func verify_gpu() -> PackedStringArray:
	if _terrain == null or _terrain.data == null or _doc == null:
		return PackedStringArray(["NOT RUN: terrain is not initialized"])
	if has_pending_uploads():
		flush()
	if has_pending_uploads():
		return PackedStringArray(["NOT RUN: uploads pending; retry next frame"])
	var data := _terrain.data
	var h_rid := data.get_height_maps_rid()
	var c_rid := data.get_control_maps_rid()
	if RenderingServer.get_rendering_device() == null or not h_rid.is_valid() or not c_rid.is_valid():
		return PackedStringArray(["NOT RUN: no rendering device (headless)"])
	var out := PackedStringArray()
	var locs := data.get_region_locations()
	for i in locs.size():
		var loc: Vector2i = locs[i]
		var rb := _doc.get_region(loc)
		if rb == null:
			out.append("region %s exists in Terrain3D but not in the document" % loc)
			continue
		_compare_map(out, loc, "GPU height", RenderingServer.texture_2d_layer_get(h_rid, i), rb.height_bytes())
		_compare_map(out, loc, "GPU control", RenderingServer.texture_2d_layer_get(c_rid, i), rb.control_bytes())
	for loc: Vector2i in _doc.regions:
		if not locs.has(loc):
			out.append("region %s is in the document but missing from Terrain3D" % loc)
	return out


# --- internals ---------------------------------------------------------------------------

func _create_terrain() -> void:
	var t := Terrain3D.new()
	t.name = "Terrain3D"
	# Default true would reload assets from their (empty) resource path on enter-tree and
	# clear the procedural textures on ready.
	t.free_editor_textures = false
	t.region_size = Terrain3D.SIZE_256
	t.vertex_spacing = WorldConstants.SAMPLE_SPACING
	var mat := Terrain3DMaterial.new()
	mat.auto_shader = false
	# Set the project shader before any parameter: parameters belong to the active shader.
	mat.shader_override = load(SHADER_PATH) as Shader
	mat.shader_override_enabled = true
	mat.set_shader_param("blend_sharpness", TerrainMaterials.BLEND_SHARPNESS)
	# set_material/set_assets create the collision manager, so the mode sticks before the
	# node enters the tree and no collision shapes are ever built.
	t.material = mat
	t.assets = TerrainMaterials.create_assets()
	t.collision_mode = Terrain3DCollision.DISABLED
	add_child(t)
	_terrain = t
	if _camera != null:
		t.set_camera(_camera)
	_apply_debug_state()
	_apply_rule_uniforms()


func _load_regions(doc: WorldDocument) -> void:
	var data := _terrain.data
	for loc in _regions:
		if not doc.regions.has(loc):
			data.remove_region(_regions[loc], false)
	_regions.clear()
	for loc in doc.sorted_region_locations():
		var region := _build_region(doc.get_region(loc))
		# Replaces any region already stored at loc; the old one is released.
		data.add_region(region, false)
		_regions[loc] = region
	data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)
	data.calc_height_range(true)
	_doc = doc
	_dirty = [{}, {}, {}]
	_last_upload_frame = PackedInt64Array([-1, -1, -1])
	_reset_stats()


func _build_region(rb: RegionBuffers) -> Terrain3DRegion:
	var n := WorldConstants.REGION_SAMPLES
	var region := Terrain3DRegion.new()
	region.location = rb.location
	region.region_size = n
	region.vertex_spacing = WorldConstants.SAMPLE_SPACING
	region.set_height_map(Image.create_from_data(n, n, false, Image.FORMAT_RF, rb.height_bytes()))
	region.set_control_map(ControlCodec.control_to_image(rb.control))
	region.set_color_map(Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, rb.color_bytes()))
	return region


## Copies document bytes into the existing region Images (same objects Terrain3DData
## holds), then uploads only those layers.
func _upload(kind: int) -> void:
	var n := WorldConstants.REGION_SAMPLES
	var locs: Array = _dirty[kind].keys()
	for loc in locs:
		var region: Terrain3DRegion = _regions[loc]
		var rb := _doc.get_region(loc)
		if kind == MAP_HEIGHT:
			region.get_height_map().set_data(n, n, false, Image.FORMAT_RF, rb.height_bytes())
			region.calc_height_range()
		elif kind == MAP_CONTROL:
			region.get_control_map().set_data(n, n, false, Image.FORMAT_RF, rb.control_bytes())
		else:
			region.get_color_map().set_data(n, n, false, Image.FORMAT_RGBA8, rb.color_bytes())
		region.edited = true
	if kind == MAP_HEIGHT:
		_terrain.data.calc_height_range(false)
	_terrain.data.update_maps(UPLOAD_TYPES[kind], false, false)
	for loc in locs:
		(_regions[loc] as Terrain3DRegion).edited = false
	_dirty[kind].clear()
	_stats[UPLOAD_STATS[kind]] += locs.size()


## Shader uniforms of the debug views; observable headless like rule_uniforms().
func debug_uniforms() -> Dictionary:
	return {"debug_view": DEBUG_VIEWS.find(_debug_view), "debug_region_grid": _region_grid}


func _apply_debug_state() -> void:
	if _terrain == null or _terrain.material == null:
		return
	# Terrain3D's show_* flags are injections into its generated shader and do nothing under the
	# project shader, so the views are uniforms of world_terrain.gdshader.
	var uniforms := debug_uniforms()
	for key: String in uniforms:
		_terrain.material.set_shader_param(key, uniforms[key])


func _validate_document(doc: WorldDocument) -> String:
	if doc == null:
		return "document is null"
	if doc.regions.is_empty():
		return "document has no terrain regions"
	if not WorldConstants.host_is_little_endian():
		return "host is not little-endian; region bytes cannot be uploaded verbatim"
	for loc in doc.regions:
		if not WorldConstants.is_valid_region(loc):
			return "document region %s is outside the fixed PoC layout" % loc
		var rb: RegionBuffers = doc.regions[loc]
		if rb.heights.size() != WorldConstants.REGION_SAMPLE_COUNT or rb.control.size() != WorldConstants.REGION_SAMPLE_COUNT:
			return "region %s buffers must hold %d samples" % [loc, WorldConstants.REGION_SAMPLE_COUNT]
	return ""


## Shader parameters derived from the rules and highlight flag (degrees, metres). Headless
## runs have no shader parameter list, so this is also the observable source of truth.
func rule_uniforms() -> Dictionary:
	return {
		"rules_rock_enabled": _rules.rock_enabled,
		"rules_rock_slope_deg": float(_rules.rock_slope_deg),
		"rules_sand_enabled": _rules.sand_enabled,
		"rules_sand_height_m": _rules.sand_height_dm / 10.0,
		"rules_highlight": _rule_highlight,
	}


func _apply_rule_uniforms() -> void:
	if _terrain == null or _terrain.material == null:
		return
	var uniforms := rule_uniforms()
	for key: String in uniforms:
		_terrain.material.set_shader_param(key, uniforms[key])


func _compare_map(out: PackedStringArray, loc: Vector2i, label: String, img: Image, expected: PackedByteArray,
		format: Image.Format = Image.FORMAT_RF) -> void:
	var n := WorldConstants.REGION_SAMPLES
	if img == null or img.get_format() != format or img.get_width() != n or img.get_height() != n:
		out.append("region %s %s map has wrong format or size" % [loc, label])
		return
	var actual := img.get_data()
	if actual.size() > expected.size():
		actual = actual.slice(0, expected.size())  # Terrain3D appends color-map mip levels
	if actual == expected:
		return
	var first := -1
	for i in mini(actual.size(), expected.size()):
		if actual[i] != expected[i]:
			first = i >> 2
			break
	out.append("region %s %s bytes differ (first sample index %d)" % [loc, label, first])


func _reset_stats() -> void:
	_stats = {"uploads_height": 0, "uploads_control": 0, "uploads_color": 0, "last_flush_ms": 0.0}
