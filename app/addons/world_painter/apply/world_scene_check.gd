class_name WorldSceneCheck
extends RefCounted
## Reloads a baked world.tscn the way a game does (fresh from disk, no cache) and compares it with the source
## document: object ids and transforms, scatter instance counts per binding, terrain buffers. Also reports any
## script reference that does not belong in an exported world (ADR 0017 A4, A6).

const MAP_BYTES := WorldConstants.REGION_MAP_BYTES
const ALLOWED_SCRIPT_PREFIX := "res://addons/world_painter/runtime/"
const FORBIDDEN_PREFIXES := ["res://addons/assetstudio/", "res://addons/world_painter/editor/",
	"res://addons/world_painter/live/", "res://addons/world_painter/preview/", "res://addons/world_painter/apply/"]


## {error, objects: {id: {transform, binding}}, scatter: {binding: instances}, scatter_nodes, paths: [id],
## regions: {Vector2i: {height, control, color}}, collision_mode, data_directory}. Loads without cache and frees what
## it made. The terrain is read from the region files in the Terrain3D node's data directory (this works before a
## SceneTree is ready, e.g. in a command-line script); `terrain_via_tree` instead lets Terrain3D load them in the tree.
static func summarize(scene_res: String, tree: SceneTree, terrain_via_tree: bool = false) -> Dictionary:
	var out := {"error": "", "objects": {}, "scatter": {}, "scatter_nodes": 0, "paths": [], "regions": {},
		"collision_mode": -1, "data_directory": ""}
	var packed := ResourceLoader.load(scene_res, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if packed == null:
		out.error = "cannot load %s" % scene_res
		return out
	var inst := packed.instantiate()
	if terrain_via_tree:
		tree.root.add_child(inst)
	_objects(inst, out)
	_scatter(inst, out)
	_paths(inst, out)
	_terrain(inst, out, terrain_via_tree)
	if terrain_via_tree:
		tree.root.remove_child(inst)
	inst.free()
	return out


static func _objects(root: Node, out: Dictionary) -> void:
	var group := root.get_node_or_null("Objects")
	for child in (group.get_children() if group != null else []):
		out.objects[str(child.get_meta("wp_object_id", child.name))] = {"transform": (child as Node3D).transform,
			"binding": str(child.get_meta("wp_binding_id", ""))}


static func _scatter(root: Node, out: Dictionary) -> void:
	var group := root.get_node_or_null("Scatter")
	for child in (group.get_children() if group != null else []):
		var mm := (child as MultiMeshInstance3D).multimesh
		var binding := str(child.get_meta("wp_binding_id", ""))
		out.scatter[binding] = int(out.scatter.get(binding, 0)) + mm.instance_count
		out.scatter_nodes += 1


static func _paths(root: Node, out: Dictionary) -> void:
	var group := root.get_node_or_null("Paths")
	for child in (group.get_children() if group != null else []):
		out.paths.append(str(child.get_meta("wp_path_id", child.name)))


static func _terrain(root: Node, out: Dictionary, via_tree: bool) -> void:
	var terrain := root.get_node_or_null("Terrain3D") as Terrain3D
	if terrain == null:
		return
	out.collision_mode = terrain.collision_mode
	out.data_directory = terrain.data_directory
	if via_tree:
		if terrain.data == null:
			return
		for loc: Vector2i in terrain.data.get_region_locations():
			out.regions[loc] = _maps_of(terrain.data.get_region(loc))
		return
	for file in DirAccess.get_files_at(ProjectSettings.globalize_path(terrain.data_directory)):
		var loc := TerrainBake.region_of_file(file)
		var region := ResourceLoader.load(terrain.data_directory.path_join(file), "Terrain3DRegion",
				ResourceLoader.CACHE_MODE_IGNORE) as Terrain3DRegion if loc != Vector2i.MAX else null
		if region != null:
			out.regions[loc] = _maps_of(region)


static func _maps_of(region: Terrain3DRegion) -> Dictionary:
	return {"height": CanonicalEncoder.sha256_hex(region.get_height_map().get_data()),
		"control": CanonicalEncoder.sha256_hex(region.get_control_map().get_data()),
		"color": CanonicalEncoder.sha256_hex(region.get_color_map().get_data().slice(0, MAP_BYTES))}


## Errors of `summary` against `doc` (empty = the scene reproduces the document). `terrain_dir` (when given) is the
## directory the Terrain3D node must read its regions from.
static func compare(summary: Dictionary, doc: WorldDocument, terrain_dir: String = "") -> PackedStringArray:
	var errors := PackedStringArray()
	if summary.error != "":
		errors.append(summary.error)
		return errors
	if terrain_dir != "" and summary.data_directory != terrain_dir:
		errors.append("the terrain data directory is %s, expected %s" % [summary.data_directory, terrain_dir])
	_compare_objects(summary, doc, errors)
	_compare_scatter(summary, doc, errors)
	_compare_terrain(summary, doc, errors)
	return errors


static func _compare_objects(summary: Dictionary, doc: WorldDocument, errors: PackedStringArray) -> void:
	var objects: Dictionary = summary.objects
	if objects.size() != doc.objects.size():
		errors.append("scene has %d objects, the world %d" % [objects.size(), doc.objects.size()])
	for id: String in doc.objects:
		var rec := doc.get_object(id)
		var def := doc.assets.definition(rec.binding_id)
		if not objects.has(id):
			errors.append("object %s is missing from the scene" % id)
		elif objects[id].transform != rec.node_transform(def.anchor_local) or objects[id].binding != rec.binding_id:
			errors.append("object %s differs from its record" % id)


static func expected_scatter(doc: WorldDocument) -> Dictionary:
	var counts := {}
	var layer := doc.scatter
	for i in layer.count():
		if not is_nan(doc.sample_height(layer.x[i], layer.z[i])):
			counts[layer.binding_of(i)] = int(counts.get(layer.binding_of(i), 0)) + 1
	return counts


static func _compare_scatter(summary: Dictionary, doc: WorldDocument, errors: PackedStringArray) -> void:
	if summary.scatter != expected_scatter(doc):
		errors.append("scatter instance counts per binding differ: scene %s, world %s" % [
			str(summary.scatter), str(expected_scatter(doc))])


static func _compare_terrain(summary: Dictionary, doc: WorldDocument, errors: PackedStringArray) -> void:
	var regions: Dictionary = summary.regions
	if regions.size() != doc.regions.size():
		errors.append("scene has %d terrain regions, the world %d" % [regions.size(), doc.regions.size()])
	for loc: Vector2i in doc.regions:
		var rb: RegionBuffers = doc.regions[loc]
		var got: Dictionary = regions.get(loc, {})
		if got.get("height", "") != CanonicalEncoder.sha256_hex(rb.height_bytes()):
			errors.append("terrain heights of region %s differ" % loc)
		if got.get("control", "") != CanonicalEncoder.sha256_hex(rb.control_bytes()):
			errors.append("terrain control map of region %s differs" % loc)
		if got.get("color", "") != CanonicalEncoder.sha256_hex(rb.color_bytes()):
			errors.append("terrain tint map of region %s differs" % loc)


## Errors for script references of the saved scene text that an exported world must not carry.
static func script_errors(scene_text: String) -> PackedStringArray:
	var errors := PackedStringArray()
	for line in scene_text.split("\n"):
		if not line.begins_with("[ext_resource"):
			continue
		var path := _attr(line, "path")
		var is_script := _attr(line, "type") == "Script"
		for prefix: String in FORBIDDEN_PREFIXES:
			if path.begins_with(prefix):
				errors.append("scene references %s" % path)
		if is_script and not path.begins_with(ALLOWED_SCRIPT_PREFIX):
			errors.append("scene carries the script %s" % path)
	return errors


static func _attr(line: String, name: String) -> String:
	var marker := ' %s="' % name
	var start := line.find(marker)
	if start < 0:
		return ""
	start += marker.length()
	return line.substr(start, line.find('"', start) - start)
