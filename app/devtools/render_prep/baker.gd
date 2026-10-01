extends RefCounted
## Orchestrates docs/render-assets.md §6 preparation for one manifest (one logical catalog).
## prepare_catalog() writes meshes/materials/textures/descriptors/index and returns the report.

const SceneReader := preload("res://devtools/render_prep/scene_reader.gd")
const MeshBaker := preload("res://devtools/render_prep/mesh_baker.gd")
const MaterialTool := preload("res://devtools/render_prep/material_tool.gd")
const TexturePrep := preload("res://devtools/render_prep/texture_prep.gd")
const Writer := preload("res://devtools/render_prep/descriptor_writer.gd")
const HashStream := preload("res://devtools/render_prep/hash_stream.gd")
const ROLES: Array[String] = ["selected", "near", "mid", "far", "ghost"]
const CATEGORIES: Array[String] = ["tree", "shrub", "rock", "structure", "ground_cover", "prop"]

var require_import := false


## Paths under res:// or user:// are used as given; relative ones are project-root relative
## (so "../build/..." addresses the repository build directory).
static func resolve_input(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://") or path.begins_with("/"):
		return path
	return ProjectSettings.globalize_path("res://").path_join(path).simplify_path()


func prepare_catalog(manifest: Dictionary) -> Dictionary:
	var report := {"catalog_id": manifest.get("catalog_id", ""), "assets": [], "errors": [], "warnings": [], "total_gpu_bytes": 0}
	var errors: Array = report.errors
	var cat := _load_catalog(str(manifest.catalog_dir), errors)
	if not errors.is_empty():
		return report
	var out_root: String = manifest.output_dir
	var entries: Array = []
	var configs: Array = (manifest.assets as Array).duplicate()
	configs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.asset_id < b.asset_id)
	for cfg: Dictionary in configs:
		var res := _prepare_asset(cfg, cat, out_root)
		(report.assets as Array).append(res.report)
		for e in res.report.errors:
			errors.append("%s: %s" % [cfg.asset_id, e])
		for w in res.report.warnings:
			(report.warnings as Array).append("%s: %s" % [cfg.asset_id, w])
		report.total_gpu_bytes = int(report.total_gpu_bytes) + int(res.report.gpu_bytes)
		if res.entry != null:
			entries.append(res.entry)
	if errors.is_empty():
		var index := {"format": "world-painter-render-assets", "schema_version": 1, "catalog_id": cat.catalog_id,
			"catalog_version": cat.catalog_version,
			"prepared_for": {"godot": "4.7.2", "renderer": "mobile", "texture_formats": ["etc2_astc", "s3tc_bptc"]},
			"assets": entries}
		_put(out_root.path_join("index.json"), Writer.to_json(index) + "\n")
	return report


func _load_catalog(dir: String, errors: Array) -> Dictionary:
	var path := dir.path_join("catalog.json")
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or typeof(json.data) != TYPE_DICTIONARY:
		errors.append("cannot read catalog %s" % path)
		return {}
	var by_id := {}
	for a: Dictionary in json.data.assets:
		by_id[a.asset_id] = a
	return {"catalog_id": json.data.catalog_id, "catalog_version": int(json.data.catalog_version), "assets": by_id}


func _prepare_asset(cfg: Dictionary, cat: Dictionary, out_root: String) -> Dictionary:
	var id: String = cfg.asset_id
	var rep := {"asset_id": id, "roles": {}, "stripped": [], "materials": {}, "textures": {}, "gpu_bytes": 0,
		"errors": [], "warnings": []}
	var errs: Array = rep.errors
	if not cat.assets.has(id):
		errs.append("asset is not in the logical catalog")
		return {"report": rep, "entry": null}
	var ca: Dictionary = cat.assets[id]
	var tiers: Dictionary = cfg.tiers
	_check_tiers(tiers, errs)
	if not errs.is_empty():
		return {"report": rep, "entry": null}
	var dir := out_root.path_join(id.get_slice(".", id.count(".")))
	DirAccess.make_dir_recursive_absolute(dir)
	var written := {}
	var textures_cfg: Dictionary = cfg.get("textures", {})

	var baked_roles := _bake_roles(cfg, ca, rep)
	if not errs.is_empty():
		return {"report": rep, "entry": null}
	var mats: Dictionary = baked_roles.materials
	var deps: Array = []
	var tex_desc := _stage_textures(textures_cfg, mats, dir, rep, written, deps)
	_write_materials(mats, textures_cfg, dir, written, deps, errs)
	var reps := {}
	for role in ROLES:
		if tiers[role].has("alias"):
			reps[role] = {"alias": tiers[role].alias}
			continue
		var baked: Dictionary = baked_roles.baked[role]
		var mat_paths := {}
		for k in baked_roles.keys_of[role]:
			mat_paths[k] = dir.path_join(k + ".tres")
		var mesh_file := "mesh_%s.tres" % role
		var err := MeshBaker.save_mesh(baked, mat_paths, dir.path_join(mesh_file))
		if err != "":
			errs.append(err)
			continue
		written[mesh_file] = true
		var gpu := MeshBaker.gpu_bytes(baked)
		var box: AABB = baked.aabb
		reps[role] = {"mesh": "mesh_" + role, "triangles": baked.triangles, "surfaces": baked.surfaces.size(),
			"aabb_min_m": box.position, "aabb_max_m": box.end}
		deps.append(_dep("mesh_" + role, "mesh", mesh_file, dir, gpu, gpu))
		rep.roles[role] = {"triangles": baked.triangles, "surfaces": baked.surfaces.size(), "gpu_bytes": gpu,
			"aabb_min_m": box.position, "aabb_max_m": box.end}
	if not errs.is_empty():
		return {"report": rep, "entry": null}
	deps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.key < b.key)
	for d: Dictionary in deps:
		rep.gpu_bytes = int(rep.gpu_bytes) + int(d.gpu_bytes)
	var desc := _descriptor(cfg, ca, reps, mats, tex_desc, deps, baked_roles.source_hash)
	var desc_text := Writer.to_json(desc) + "\n"
	_put(dir.path_join("descriptor.json"), desc_text)
	written["descriptor.json"] = true
	_cleanup(dir, written)
	var short := id.get_slice(".", id.count("."))
	return {"report": rep, "entry": {"asset_id": id, "asset_version": int(ca.version), "descriptor": short + "/descriptor.json",
		"descriptor_sha256": HashStream.sha256(desc_text.to_utf8_buffer()).hex_encode()}}


func _check_tiers(tiers: Dictionary, errs: Array) -> void:
	for role in ROLES:
		if not tiers.has(role):
			errs.append("tiers missing role '%s'" % role)
			return
	if tiers.size() != ROLES.size():
		errs.append("tiers must have exactly the roles %s" % str(ROLES))
		return
	if tiers.selected.has("alias"):
		errs.append("selected cannot be an alias")
	for role in ROLES:
		var t: Dictionary = tiers[role]
		if t.has("alias"):
			var cur: String = role
			for step in 3:
				if not tiers.has(cur) or not tiers[cur].has("alias"):
					break
				cur = tiers[cur].alias
				if step == 2:
					errs.append("alias chain of '%s' is longer than 2 steps or cyclic" % role)
			if not tiers.has(cur):
				errs.append("role '%s' aliases unknown role" % role)
		elif not (t.has("scene") or t.get("source", false)):
			errs.append("role '%s' needs scene, source or alias" % role)


## Reads and bakes every non-alias role; resolves one material key per distinct material.
func _bake_roles(cfg: Dictionary, ca: Dictionary, rep: Dictionary) -> Dictionary:
	var errs: Array = rep.errors
	var tiers: Dictionary = cfg.tiers
	var tex_keys: Array = (cfg.get("textures", {}) as Dictionary).keys()
	var mats := {}
	var key_of_instance := {}
	var baked := {}
	var keys_of := {}
	for role in ROLES:
		if tiers[role].has("alias"):
			continue
		var path: String = ca.preview_scene if tiers[role].get("source", false) else resolve_input(tiers[role].scene)
		var scene := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if scene == null:
			errs.append("role %s: cannot load scene %s" % [role, path])
			continue
		var read := SceneReader.read(scene, "role " + role)
		for e in read.errors:
			errs.append(e)
		for s: Dictionary in read.stripped:
			s.role = role
			(rep.stripped as Array).append(s)
		var ok := true
		for part: Dictionary in read.parts:
			for m: Variant in part.materials:
				var iid: int = 0 if m == null else (m as Object).get_instance_id()
				if key_of_instance.has(iid):
					continue
				var d := MaterialTool.describe(m as Material, "role %s node %s" % [role, part.node], tex_keys)
				if d.has("error"):
					errs.append(d.error)
					ok = false
					continue
				if mats.has(d.key) and mats[d.key].props_hash != d.props_hash:
					errs.append("role %s: material key '%s' is used with different properties" % [role, d.key])
					ok = false
					continue
				mats[d.key] = d
				key_of_instance[iid] = d.key
		if not ok or not errs.is_empty():
			continue
		var key_of := func(m: Material) -> String: return key_of_instance[0 if m == null else m.get_instance_id()]
		var b := MeshBaker.bake(read.parts, key_of)
		for e in b.errors:
			errs.append("role %s: %s" % [role, e])
		if b.surfaces.is_empty():
			errs.append("role %s: no triangle geometry" % role)
			continue
		baked[role] = b
		keys_of[role] = b.surfaces.map(func(s: Dictionary) -> String: return s.key)
		var box: AABB = b.aabb
		if not (box.size.x > 0.0 and box.size.y > 0.0 and box.size.z > 0.0):
			errs.append("role %s: flat or empty bounds %s" % [role, box])
	var src_bytes := FileAccess.get_file_as_bytes(ca.preview_scene)
	var scatter: Variant = null
	if ca.scatter_mesh != null:
		scatter = FileAccess.get_file_as_bytes(ca.scatter_mesh)
	return {"materials": mats, "baked": baked, "keys_of": keys_of,
		"source_hash": Writer.source_hash(ca.asset_id, int(ca.version), src_bytes, scatter)}


func _stage_textures(textures_cfg: Dictionary, mats: Dictionary, dir: String, rep: Dictionary, written: Dictionary, deps: Array) -> Dictionary:
	var errs: Array = rep.errors
	var out := {}
	var keys: Array = textures_cfg.keys()
	keys.sort()
	for tkey: String in keys:
		var cutout := false
		for mk in mats:
			cutout = cutout or (mats[mk].texture == tkey and mats[mk].alpha_mode == "cutout")
		var entry := {"low": null, "preview": null}
		for tier in ["low", "preview"]:
			var src: Variant = textures_cfg[tkey].get(tier)
			if src == null:
				continue
			var file := "%s_%s.png" % [tkey, tier]
			var r := TexturePrep.stage(resolve_input(src), dir.path_join(file), tier, cutout, "texture " + tkey)
			if r.error != "":
				errs.append(r.error)
				continue
			written[file] = true
			written[file + ".import"] = true
			var dep_key := "tex_%s_%s" % [tkey, tier]
			deps.append({"key": dep_key, "type": "texture", "path": file, "bytes": r.bytes, "sha256": r.sha256,
				"gpu_bytes": r.gpu_bytes, "staging_bytes": r.staging_bytes})
			entry[tier] = {"dependency": dep_key, "width": r.width, "height": r.height, "mipmaps": true}
			var status := TexturePrep.verify_import(dir.path_join(file), r.width, r.height)
			if status == "pending":
				(rep.warnings as Array).append("%s not imported yet" % file)
				if require_import:
					errs.append("%s not imported (run godot --import)" % file)
			elif status != "":
				errs.append(status)
			if not r.coverage.is_empty():
				rep.textures["%s_%s" % [tkey, tier]] = {"coverage": r.coverage, "width": r.width, "height": r.height}
		if entry.low == null:
			errs.append("texture %s has no low tier" % tkey)
		out[tkey] = entry
	return out


func _write_materials(mats: Dictionary, textures_cfg: Dictionary, dir: String, written: Dictionary, deps: Array, errs: Array) -> void:
	var keys: Array = mats.keys()
	keys.sort()
	for k: String in keys:
		var d: Dictionary = mats[k]
		var tex_path := ""
		if d.texture != "":
			tex_path = dir.path_join("%s_low.png" % d.texture)
		var file := k + ".tres"
		if not _put(dir.path_join(file), MaterialTool.tres_text(d, tex_path)):
			errs.append("cannot write %s" % file)
			continue
		written[file] = true
		deps.append(_dep("mat_" + k, "material", file, dir, 0, 0))


func _dep(key: String, type: String, file: String, dir: String, gpu: int, staging: int) -> Dictionary:
	var data := FileAccess.get_file_as_bytes(dir.path_join(file))
	return {"key": key, "type": type, "path": file, "bytes": data.size(),
		"sha256": HashStream.sha256(data).hex_encode(), "gpu_bytes": gpu, "staging_bytes": staging}


func _descriptor(cfg: Dictionary, ca: Dictionary, reps: Dictionary, mats: Dictionary, tex_desc: Dictionary,
		deps: Array, source_hash: String) -> Dictionary:
	var mat_keys: Array = mats.keys()
	mat_keys.sort()
	var materials := {}
	for k: String in mat_keys:
		materials[k] = {"dependency": "mat_" + k, "alpha_mode": mats[k].alpha_mode,
			"texture": null if mats[k].texture == "" else mats[k].texture}
	var d := {
		"format": "world-painter-render-asset", "schema_version": 1, "asset_id": ca.asset_id,
		"asset_version": int(ca.version), "source_content_hash": source_hash, "derivative_hash": "",
		"category": cfg.category, "vegetation": cfg.vegetation, "decorative": cfg.decorative,
		"anchor_local_m": _v3(ca.placement_anchor_local), "bounds_min_m": _v3(ca.bounds_min),
		"bounds_max_m": _v3(ca.bounds_max), "footprint_radius_m": float(ca.footprint_radius_m),
		"representations": reps, "overview": cfg.overview, "materials": materials, "textures": tex_desc,
		"dependencies": deps,
		"provenance": cfg.get("provenance", "Prepared from %s by prepare_render_assets.gd" % ca.preview_scene),
		"license": cfg.get("license", ca.license),
	}
	d.derivative_hash = Writer.derivative_hash(d)
	return d


static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _put(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


func _cleanup(dir: String, written: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		if not written.has(f):
			DirAccess.remove_absolute(dir.path_join(f))
