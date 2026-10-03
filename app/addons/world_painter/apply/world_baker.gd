class_name WorldBaker
extends RefCounted
## Bakes an accepted world (ADR 0017 A4) into `<ctx.base_res>/generated/`: world.tscn (an ordinary Godot scene) and
## terrain/ (Terrain3D regions, material, texture assets). Objects, scatter and paths are built by their own helpers
## from the same code the editor presents them with. The output contains no network, editor or preview script.

const ROOT_NAME := "AcceptedWorld"


## "" or an error. Fills ctx.stats. Must run inside a SceneTree (Terrain3D saves from the tree).
static func bake(ctx: BakeContext) -> String:
	if ctx.tree == null:
		return "no SceneTree to bake in"
	if ctx.mapper_error != "":
		return ctx.mapper_error
	var err := StorageFs.make_dir(ctx.generated_abs())
	if err != "":
		return err
	var root := Node3D.new()
	root.name = ROOT_NAME
	for key: String in ctx.identity:
		root.set_meta("wp_" + key, ctx.identity[key])
	for step: Callable in [TerrainBake.build, ObjectBake.build, ScatterBake.build, PathBake.build]:
		err = step.call(ctx, root)
		if err != "":
			break
	if err == "":
		err = _save(ctx, root)
	root.free()
	return err


static func _save(ctx: BakeContext, root: Node3D) -> String:
	var started := Time.get_ticks_usec()
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		return "cannot pack the baked world"
	if ResourceSaver.save(packed, ctx.scene_res()) != OK:
		return "cannot save %s" % ctx.scene_res()
	ctx.time("scene", started)
	return ""
