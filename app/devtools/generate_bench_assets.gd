extends SceneTree
## Deterministic benchmark fixture generator (docs/rendering-performance-spec.md §20.1, asset side).
##   godot --headless --path app --script res://devtools/generate_bench_assets.gd
## Writes the logical catalog res://assets/bench/catalog.json with its self-contained source scenes
## and scatter mesh (res://assets/bench/models/), and the preparation INPUTS (tier scenes and
## texture PNGs) to <repo>/build/render_prep_inputs/bench_nature/<asset>/ (git-ignored; the manifest
## app/devtools/render_prep/bench_nature.json references them project-relative as
## ../build/render_prep_inputs/...). Run prepare_render_assets.gd afterwards.

const Baker := preload("res://devtools/render_prep/baker.gd")
const Common := preload("res://devtools/render_prep/bench_common.gd")
const Trees := preload("res://devtools/render_prep/bench_trees.gd")
const Props := preload("res://devtools/render_prep/bench_props.gd")
const Atlas := preload("res://devtools/render_prep/atlas_gen.gd")
const SceneReader := preload("res://devtools/render_prep/scene_reader.gd")
const MeshBaker := preload("res://devtools/render_prep/mesh_baker.gd")
const Writer := preload("res://devtools/render_prep/descriptor_writer.gd")

const MODELS := "res://assets/bench/models/"
const INPUT_ROOT := "../build/render_prep_inputs/bench_nature/"
const GRASS_SCATTER := "res://assets/bench/models/grass_cards_scatter.tres"

const BROADLEAF := {
	"source": {"trunk_segs": 14, "trunk_rings": 6, "branch_segs": 8, "branch_rings": 3, "sub_segs": 6, "subs": 2, "sub_mid_cluster": true, "leaves": 190, "leaf_segs": 3, "mode": "tree", "seed": 11},
	"selected": {"trunk_segs": 10, "trunk_rings": 4, "branch_segs": 6, "branch_rings": 2, "sub_segs": 5, "subs": 2, "sub_mid_cluster": true, "leaves": 46, "leaf_segs": 3, "mode": "tree", "seed": 11},
	"near": {"trunk_segs": 8, "trunk_rings": 3, "branch_segs": 5, "branch_rings": 2, "sub_segs": 4, "subs": 2, "sub_mid_cluster": true, "leaves": 22, "leaf_segs": 2, "mode": "tree", "seed": 11},
	"mid": {"trunk_segs": 8, "trunk_rings": 2, "branch_segs": 4, "branch_rings": 1, "sub_segs": 3, "subs": 1, "sub_mid_cluster": false, "leaves": 12, "leaf_segs": 2, "mode": "tree", "seed": 11},
	"far": {"trunk_segs": 6, "trunk_rings": 1, "mode": "lobes", "seed": 11},
}
const HEAVY := {"trunk_segs": 16, "trunk_rings": 6, "branch_segs": 10, "branch_rings": 3, "sub_segs": 6, "subs": 2, "sub_mid_cluster": true, "leaves": 165, "leaf_segs": 4, "mode": "tree", "seed": 77}
const PINE := {
	"source": {"levels": 28, "radial": 16, "layers": 7, "trunk_segs": 8, "seed": 5},
	"selected": {"levels": 24, "radial": 12, "layers": 7, "trunk_segs": 8, "seed": 5},
	"near": {"levels": 20, "radial": 10, "layers": 5, "trunk_segs": 8, "seed": 5},
	"mid": {"levels": 14, "radial": 8, "layers": 4, "trunk_segs": 6, "seed": 5},
	"far": {"levels": 12, "radial": 10, "layers": 1, "trunk_segs": 6, "seed": 5},
}
const BUSH := {"source": {"cards": 700, "seed": 21}, "selected": {"cards": 600, "seed": 21}, "mid": {"cards": 200, "seed": 21}, "far": {"cards": 50, "seed": 21}}
const ROCK := {"source": {"segs": 40, "rings": 30}, "selected": {"segs": 36, "rings": 28}, "mid": {"segs": 20, "rings": 13}, "far": {"segs": 10, "rings": 7}}
const TOWER := {
	"source": {"sd_base": 8, "sd_body": 5, "sd_wing": 4, "roof_rings": 6},
	"selected": {"sd_base": 8, "sd_body": 4, "sd_wing": 4, "roof_rings": 5},
	"mid": {"sd_base": 3, "sd_body": 2, "sd_wing": 2, "roof_rings": 2},
	"far": {"sd_base": 0, "sd_body": 0, "sd_wing": 0, "roof_rings": 1, "single_material": true},
}
const GRASS := {"source": {"cards": 32, "seed": 31}, "far": {"cards": 8, "seed": 31}}

var _errors: PackedStringArray = []
var _in_dir := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_in_dir = Baker.resolve_input(INPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(MODELS)
	var catalog: Array = []
	catalog.append(_entry_of(_broadleaf(), "bench.tree.broadleaf_geo", "Broadleaf (modeled)", "trees", "broadleaf_geo", [0.6, 1.6, -1.0, 2.0]))
	catalog.append(_entry_of(_pine(), "bench.tree.pine_cards", "Pine (leaf cards)", "trees", "pine_cards", [0.6, 1.6, -1.0, 2.0]))
	catalog.append(_entry_of(_bush(), "bench.shrub.bush_cards", "Bush (leaf cards)", "shrubs", "bush_cards", [0.6, 1.6, -0.5, 1.0]))
	catalog.append(_entry_of(_rock(), "bench.rock.slab_a", "Slab rock", "rocks", "slab_a", [0.5, 2.5, -1.0, 1.0]))
	catalog.append(_entry_of(_tower(), "bench.structure.tower_a", "Tower", "structures", "tower_a", [0.75, 1.5, -2.0, 3.0]))
	catalog.append(_entry_of(_grass(), "bench.cover.grass_cards", "Grass clump (cards)", "ground_cover", "grass_cards", [0.7, 1.3, -0.2, 0.2]))
	catalog.append(_entry_of(_heavy(), "bench.tree.heavy_unprepared", "Heavy tree (no derivative)", "trees", "heavy_unprepared", [0.6, 1.6, -1.0, 2.0]))
	catalog.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.asset_id < b.asset_id)
	var text := Writer.to_json({"catalog_id": "bench_nature", "catalog_version": 1, "assets": catalog}) + "\n"
	var f := FileAccess.open("res://assets/bench/catalog.json", FileAccess.WRITE)
	f.store_string(text)
	f.close()
	for e in _errors:
		printerr("ERROR: " + e)
	print("bench assets generated (%d errors)" % _errors.size())
	quit(1 if not _errors.is_empty() else 0)


# --- Per-asset generation: returns {"short", "source": Node3D} ---------------------------------
func _broadleaf() -> Dictionary:
	for role in ["selected", "near", "mid", "far"]:
		_save_tier("broadleaf_geo", role, Trees.broadleaf(BROADLEAF[role]))
	return {"short": "broadleaf_geo", "scene": Trees.broadleaf(BROADLEAF.source)}


func _heavy() -> Dictionary:
	return {"short": "heavy_unprepared", "scene": Trees.broadleaf(HEAVY)}


func _pine() -> Dictionary:
	var foliage := Atlas.atlas("pine", 128, 1001)
	var bark := Atlas.bark(128, 1002)
	_save_texture("pine_cards", "foliage", foliage, 256, 1024)
	_save_texture("pine_cards", "bark", bark, 128, 512)
	for role in ["selected", "near", "mid", "far"]:
		_save_tier("pine_cards", role, Trees.pine(PINE[role], {}))
	var embed := {"foliage": Common.embed_texture(Atlas.resized(foliage, 512)), "bark": Common.embed_texture(bark)}
	return {"short": "pine_cards", "scene": Trees.pine(PINE.source, embed)}


func _bush() -> Dictionary:
	var leaf := Atlas.atlas("bush", 128, 2001)
	_save_texture("bush_cards", "bush_leaf", leaf, 256, 0)
	for role in ["selected", "mid", "far"]:
		_save_tier("bush_cards", role, Trees.bush(BUSH[role], {}))
	return {"short": "bush_cards", "scene": Trees.bush(BUSH.source, {"bush_leaf": Common.embed_texture(leaf)})}


func _rock() -> Dictionary:
	for role in ["selected", "mid", "far"]:
		_save_tier("slab_a", role, Props.rock(ROCK[role]))
	return {"short": "slab_a", "scene": Props.rock(ROCK.source)}


func _tower() -> Dictionary:
	for role in ["selected", "mid", "far"]:
		_save_tier("tower_a", role, Props.tower(TOWER[role]))
	return {"short": "tower_a", "scene": Props.tower(TOWER.source)}


func _grass() -> Dictionary:
	var atlas := Atlas.atlas("grass", 64, 3001)
	_save_texture("grass_cards", "grass", atlas, 128, 512)
	_save_tier("grass_cards", "far", Props.grass(GRASS.far, {}))
	var tex := Common.embed_texture(atlas)
	var mat := Common.material("grass", Color.WHITE, tex, true)
	var err := Common.save_resource(Props.grass_mesh(GRASS.source, mat), GRASS_SCATTER)
	if err != "":
		_errors.append(err)
	return {"short": "grass_cards", "scene": Props.grass(GRASS.source, {"grass": tex}), "scatter": GRASS_SCATTER}


# --- Output helpers --------------------------------------------------------------------------
func _save_tier(short: String, role: String, root: Node3D) -> void:
	var dir := _in_dir.path_join(short)
	DirAccess.make_dir_recursive_absolute(dir)
	var err := Common.save_scene(root, dir.path_join(role + ".tscn"))
	if err != "":
		_errors.append(err)


## `base` is the image at the low size; preview_size 0 = no preview tier.
func _save_texture(short: String, key: String, base: Image, low_size: int, preview_size: int) -> void:
	var dir := _in_dir.path_join(short)
	DirAccess.make_dir_recursive_absolute(dir)
	var low := base if base.get_width() == low_size else Atlas.resized(base, low_size)
	if low.save_png(dir.path_join("%s_low.png" % key)) != OK:
		_errors.append("cannot write %s low texture" % key)
	if preview_size > 0 and Atlas.resized(base, preview_size).save_png(dir.path_join("%s_preview.png" % key)) != OK:
		_errors.append("cannot write %s preview texture" % key)


## Saves the source scene, measures its baked bounds and returns the catalog entry.
func _entry_of(built: Dictionary, asset_id: String, display: String, category: String, short: String, limits: Array) -> Dictionary:
	var path := MODELS + short + ".tscn"
	var err := Common.save_scene(built.scene, path)
	if err != "":
		_errors.append(err)
		return {"asset_id": asset_id}
	var size_bytes := FileAccess.get_file_as_bytes(path).size()
	print("%s: %d bytes" % [path, size_bytes])
	if size_bytes > 3 * 1024 * 1024:
		_errors.append("%s is %d bytes (limit 3 MiB)" % [path, size_bytes])
	var scene := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var read := SceneReader.read(scene, short)
	var baked := MeshBaker.bake(read.parts, func(_m: Material) -> String: return "k")
	var box: AABB = baked.aabb
	var bmin := Vector3(floorf(box.position.x * 20.0) / 20.0, floorf(box.position.y * 20.0) / 20.0, floorf(box.position.z * 20.0) / 20.0)
	var bmax := Vector3(ceilf(box.end.x * 20.0) / 20.0, ceilf(box.end.y * 20.0) / 20.0, ceilf(box.end.z * 20.0) / 20.0)
	var half := maxf(maxf(-bmin.x, bmax.x), maxf(-bmin.z, bmax.z))
	print("%s: %d triangles, bounds %s..%s" % [asset_id, baked.triangles, bmin, bmax])
	var structure := category == "structures"
	return {
		"asset_id": asset_id, "version": 1, "display_name": display, "category": category,
		"preview_scene": path, "scatter_mesh": built.get("scatter"), "thumbnail": "res://assets/icon.svg",
		"bounds_min": bmin, "bounds_max": bmax, "placement_anchor_local": Vector3.ZERO,
		"footprint_radius_m": snappedf(half * 0.8, 0.05), "scale_min": limits[0], "scale_max": limits[1],
		"height_offset_min_m": limits[2], "height_offset_max_m": limits[3],
		"default_grounding": "WORLD_FIXED" if structure else "FOLLOW_TERRAIN",
		"scatter_allowed": built.has("scatter"),
		"provenance": "Procedural benchmark fixture generated by app/devtools/generate_bench_assets.gd (seeded)",
		"license": "CC0-1.0",
	}
