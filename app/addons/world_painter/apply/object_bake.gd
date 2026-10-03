class_name ObjectBake
extends RefCounted
## Placed objects of an accepted world (ADR 0017 A4): one instance of the binding's installed scene per record,
## named by its object id (meta `wp_object_id`), at ObjectRecord.node_transform(anchor) like the editor presents it.
## Records of every origin become individual instances; scatter lives in ScatterBake.


## Adds an "Objects" node under `root`. Returns "" or an error.
static func build(ctx: BakeContext, root: Node3D) -> String:
	var started := Time.get_ticks_usec()
	var group := Node3D.new()
	group.name = "Objects"
	root.add_child(group)
	group.owner = root
	for id in ctx.doc.sorted_object_ids():
		var rec := ctx.doc.get_object(id)
		var def := ctx.doc.assets.definition(rec.binding_id)
		var binding := ctx.doc.assets.get_binding(rec.binding_id)
		if def == null or binding == null:
			return "object %s refers to the unknown binding %s" % [id, rec.binding_id]
		var found := ctx.deliveries.scene_for(binding)
		if found[1] != "":
			return "object %s: %s" % [id, found[1]]
		var node := (found[0] as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
		if node == null:
			return "object %s: the scene of binding %s does not have a Node3D root" % [id, rec.binding_id]
		var remapped := ctx.mapper != null and ctx.mapper.map_nodes(rec.binding_id, node, WPMaterialMapper.asset_id_of(binding)) > 0
		node.name = id
		node.transform = rec.node_transform(def.anchor_local)
		node.set_meta("wp_object_id", id)
		node.set_meta("wp_binding_id", rec.binding_id)
		group.add_child(node)
		node.owner = root
		if remapped:
			root.set_editable_instance(node, true)  # without it the saved scene drops the nested surface overrides
	ctx.stats.objects = ctx.doc.objects.size()
	ctx.time("objects", started)
	return ""
