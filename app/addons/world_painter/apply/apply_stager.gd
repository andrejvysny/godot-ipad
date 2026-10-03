class_name ApplyStager
extends RefCounted
## Bakes a generation into editor-owned staging and proves it before anything is installed (ADR 0017 A5): bake with
## staging paths, reload the saved scene like a game does and compare it with the document, then rewrite the staged
## paths of the text resources to the final directory. The rewrite is a pure prefix substitution and is checked to be
## exactly reversible.

const TEXT_EXTENSIONS := ["tscn", "tres"]


## {error, stats, content}: bakes `doc` into `<staging>/generated` for the final generation directory `final_res`.
static func bake_generated(doc: WorldDocument, staging_id: String, final_res: String, ctx: ApplyContext,
		identity: Dictionary, profile: Dictionary) -> Dictionary:
	var stage_res := ApplyLayout.staging_res(staging_id)
	var bake := BakeContext.new(doc, stage_res, ctx.deliveries)
	bake.tree = ctx.tree
	bake.use_profile(profile)
	bake.identity = identity
	var out := {"error": "", "stats": bake.stats, "content": {}}
	out.error = WorldBaker.bake(bake)
	if out.error == "":
		out.error = _prove(bake, doc, ctx)
	if out.error == "":
		out.error = normalize(bake.generated_abs(), stage_res, final_res)
	out.content = content_of(bake.stats)
	return out


static func content_of(stats: Dictionary) -> Dictionary:
	return {"objects": int(stats.objects), "regions": int(stats.regions), "paths": int(stats.paths),
		"scatter_instances": stats.scatter_instances.duplicate()}


static func _prove(bake: BakeContext, doc: WorldDocument, ctx: ApplyContext) -> String:
	var started := Time.get_ticks_usec()
	var errors := WorldSceneCheck.compare(WorldSceneCheck.summarize(bake.scene_res(), ctx.tree), doc,
			bake.generated_res().path_join("terrain"))
	errors.append_array(WorldSceneCheck.script_errors(FileAccess.get_file_as_string(bake.scene_res())))
	bake.time("validate", started)
	return "" if errors.is_empty() else "the baked world does not reproduce the snapshot: " + "; ".join(errors.slice(0, 3))


## Replaces `from_prefix` by `to_prefix` in every text resource below `generated_abs`. "" or an error.
static func normalize(generated_abs: String, from_prefix: String, to_prefix: String) -> String:
	var rewritten := 0
	for rel: String in ApplyReceipt.hash_tree(generated_abs):
		if not TEXT_EXTENSIONS.has(rel.get_extension()):
			continue
		var path := generated_abs.path_join(rel)
		var text := FileAccess.get_file_as_string(path)
		var changed := text.replace(from_prefix, to_prefix)
		if changed.contains(from_prefix) or changed.replace(to_prefix, from_prefix) != text:
			return "the staged paths of %s cannot be normalized" % rel
		if changed != text:
			var err := StorageFs.write_bytes(path, changed.to_utf8_buffer())
			if err != "":
				return err
			rewritten += 1
	return "" if rewritten > 0 else "no staged path was rewritten (nothing refers to the generated files?)"
