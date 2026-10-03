class_name RuntimeGlbLoader
extends RefCounted
## Turns verified portable GLB bytes into one baked ArrayMesh in asset space (INT-SPEC §6, IP-SPEC §4). The GLB is
## judged by RuntimeGlbValidator before any scene exists; GLTFDocument then runs on the main thread, and only
## while `can_run_heavy` allows (no editing operation active). The generated scene is baked (node transforms
## applied, surfaces merged per material, materials converted to opaque/cutout StandardMaterial3D) and freed.
## It never calls ResourceLoader on a downloaded file and never loads scenes, scripts or shaders.

const BLEND_NOTE := "%d blended material(s) became cutout"
const FOREIGN_NOTE := "%d unsupported material(s) replaced by a plain material"
const VERTEX_BYTES := 32
const INDEX_BYTES := 4


## One load outcome. `mesh` is null unless `ok`.
class Result extends RefCounted:
	var ok := false
	var error := ""
	var mesh: ArrayMesh
	var aabb := AABB()
	var triangles := 0
	var surfaces := 0
	var materials_used := 0
	var max_texture_dim := 0
	var gpu_bytes := 0
	var scatter_ok := false
	var disclosures := PackedStringArray()


## `() -> bool`: whether heavy main-thread work may start now (unset means always).
var can_run_heavy := Callable()


## Coroutine: `var r: RuntimeGlbLoader.Result = await loader.load_glb(bytes, cancel)`. A cancelled token (anything
## with is_cancelled()) ends it with error "cancelled" before or after the scene work; nothing is retained.
func load_glb(glb: PackedByteArray, cancel: RefCounted = null) -> Result:
	var res := Result.new()
	var checked := RuntimeGlbValidator.validate(glb)
	if not bool(checked.ok):
		res.error = str(checked.error)
		return res
	while can_run_heavy.is_valid() and not bool(can_run_heavy.call()):
		if _cancelled(cancel):
			res.error = "cancelled"
			return res
		await _next_frame()
	if _cancelled(cancel):
		res.error = "cancelled"
		return res
	var root := _generate(glb)
	if root == null:
		res.error = "the GLB could not be parsed"
		return res
	var baked := _bake(root, res)
	root.free()
	if baked == null or baked.get_surface_count() == 0:
		res.error = "the GLB has no triangle geometry"
		return res
	if _cancelled(cancel):
		res.error = "cancelled"
		return res
	_finish(res, baked, checked.stats)
	return res


static func _cancelled(token: RefCounted) -> bool:
	return token != null and bool(token.call("is_cancelled"))


func _next_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame


static func _generate(glb: PackedByteArray) -> Node:
	var state := GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var doc := GLTFDocument.new()
	if doc.append_from_buffer(glb, "", state, 0) != OK:
		return null
	return doc.generate_scene(state)


func _finish(res: Result, baked: ArrayMesh, stats: Dictionary) -> void:
	res.ok = true
	res.mesh = baked
	res.aabb = baked.get_aabb()
	res.surfaces = baked.get_surface_count()
	res.materials_used = int(stats.materials_used)
	res.max_texture_dim = int(stats.max_texture_dim)
	var bytes := int(stats.texture_bytes)
	for s in res.surfaces:
		var indices := baked.surface_get_array_index_len(s)
		var vertices := baked.surface_get_array_len(s)
		bytes += vertices * VERTEX_BYTES + indices * INDEX_BYTES
		res.triangles += (indices if indices > 0 else vertices) / 3
	res.gpu_bytes = bytes
	res.scatter_ok = res.triangles <= RuntimeGlbValidator.SCATTER_MAX_TRIANGLES \
			and RuntimeGlbValidator.scatter_budget_ok(stats)


## One ArrayMesh surface per distinct source material, node transforms applied (asset space).
func _bake(root: Node, res: Result) -> ArrayMesh:
	var groups := {}  # material key -> {"st": SurfaceTool, "material": Material, "normals": bool}
	var order: Array = []
	_collect(root, Transform3D.IDENTITY, groups, order)
	var out := ArrayMesh.new()
	var blended := 0
	var foreign := 0
	for key: Variant in order:
		var g: Dictionary = groups[key]
		var st: SurfaceTool = g.st
		if not bool(g.normals):
			st.deindex()
			st.generate_normals()
		var converted := _convert(g.material, res)
		blended += int(converted.blended)
		foreign += int(converted.foreign)
		st.set_material(converted.material)
		st.commit(out)
	if blended > 0:
		res.disclosures.append(BLEND_NOTE % blended)
	if foreign > 0:
		res.disclosures.append(FOREIGN_NOTE % foreign)
	return out


func _collect(node: Node, parent_xf: Transform3D, groups: Dictionary, order: Array) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var material: Material = mi.get_surface_override_material(s)
			if material == null:
				material = mi.mesh.surface_get_material(s)
			var key: int = material.get_instance_id() if material != null else 0
			if not groups.has(key):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[key] = {"st": st, "material": material, "normals": true}
				order.append(key)
			var g: Dictionary = groups[key]
			if mi.mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_NORMAL == 0:
				g.normals = false
			(g.st as SurfaceTool).append_from(mi.mesh, s, xf)
	for child in node.get_children():
		_collect(child, xf, groups, order)


## {"material": StandardMaterial3D, "blended": bool, "foreign": bool}: opaque or cutout, nothing else.
func _convert(source: Material, _res: Result) -> Dictionary:
	if source == null:
		return {"material": StandardMaterial3D.new(), "blended": false, "foreign": false}
	var std := source as StandardMaterial3D
	if std == null:
		var plain := StandardMaterial3D.new()
		var base := source as BaseMaterial3D
		if base != null:
			plain.albedo_color = base.albedo_color
			plain.albedo_texture = base.albedo_texture
		return {"material": plain, "blended": false, "foreign": true}
	var out := std.duplicate() as StandardMaterial3D
	var blended := false
	match out.transparency:
		BaseMaterial3D.TRANSPARENCY_DISABLED, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			pass
		_:
			blended = true
			out.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			out.alpha_scissor_threshold = 0.5
	out.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	return {"material": out, "blended": blended, "foreign": false}
