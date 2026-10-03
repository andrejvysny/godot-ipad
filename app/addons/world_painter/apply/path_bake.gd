class_name PathBake
extends RefCounted
## Paths of an accepted world (ADR 0017 A4): the terrain-draped ribbon meshes of PathRibbon, built from the same
## curve sampling the editor draws (PathRenderer.CURVE_STEP_M). A path with no terrain under it produces no node.


static func build(ctx: BakeContext, root: Node3D) -> String:
	var started := Time.get_ticks_usec()
	var group := Node3D.new()
	group.name = "Paths"
	root.add_child(group)
	group.owner = root
	var material := PathRibbon.material(false)
	for id in ctx.doc.sorted_path_ids():
		var rec := ctx.doc.get_path_record(id)
		var curve := PathSpline.sample(rec.points, PathRenderer.CURVE_STEP_M)
		var mesh := PathRibbon.build(ctx.doc, curve, rec.width_m)
		if mesh == null:
			ctx.stats.paths_skipped += 1
			continue
		var node := MeshInstance3D.new()
		node.name = id
		node.mesh = mesh
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.set_meta("wp_path_id", id)
		group.add_child(node)
		node.owner = root
		ctx.stats.paths += 1
	ctx.time("paths", started)
	return ""
