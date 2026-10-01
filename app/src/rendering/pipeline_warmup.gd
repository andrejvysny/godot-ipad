class_name PipelineWarmup
extends RefCounted
## Session-start pipeline preparation (spec §17): for FRAMES rendered frames, a dedicated Node3D just in front of
## the camera holds one tiny draw per representative combination (every low-tier mesh+material of each READY
## asset as a 1-instance MultiMesh, the selected tier as a MeshInstance3D, the ghost, the placeholder and the
## overview vertex-colour material). Nothing here is presenter, world or document state; the node is freed
## after the last frame. Counter deltas are reported, never promised to be zero.

const FRAMES := 2
const SCALE := 0.001
const DISTANCE_M := 1.0
const ROLES: Array[String] = ["selected", "near", "mid", "far"]
const NODE_NAME := "pipeline_warmup"

var draws := 0
var compilations_delta: Dictionary = {}
var ms := 0.0
var state := "idle"  # idle | running | done | skipped

var _root: Node3D
var _ticks := 0
var _before: Dictionary = {}
var _seen: Dictionary = {}


func is_active() -> bool:
	return _root != null


func node() -> Node3D:
	return _root


## Builds the warm-up draws under `camera`. Returns the number of draws (0 and state "skipped" without a camera).
func start(camera: Camera3D, registry: RenderAssetRegistry, ghost_material: Material, placeholder: Mesh,
		overview_material: Material) -> int:
	if camera == null or _root != null:
		state = "skipped"
		return 0
	var t0 := Time.get_ticks_usec()
	_before = RenderCounters.pipelines()
	_root = Node3D.new()
	_root.name = NODE_NAME
	_root.position = Vector3(0.0, 0.0, -DISTANCE_M)
	camera.add_child(_root)
	for id in registry.ready_ids():
		_add_asset(registry.descriptor(id), ghost_material)
	_add_instance(placeholder, null, "placeholder")
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_add_instance(box, ghost_material, "ghost_box")
	_add_instance(_overview_mesh(overview_material), null, "overview")
	draws = _root.get_child_count()
	ms = float(Time.get_ticks_usec() - t0) / 1000.0
	state = "running"
	return draws


## Once per session frame. The first call happens before the first frame with the nodes is drawn, so the nodes
## stay for FRAMES draws and are freed on the call after. `abort` frees them at once (a render bench started).
func tick(abort: bool = false) -> void:
	if _root == null:
		return
	_ticks += 1
	if abort or _ticks > FRAMES:
		_finish("skipped" if abort else "done")


func status() -> Dictionary:
	return {"draws": draws, "compilations_delta": compilations_delta, "ms": ms, "state": state}


func _finish(final_state: String) -> void:
	_root.get_parent().remove_child(_root)
	_root.free()
	_root = null
	state = final_state
	var after := RenderCounters.pipelines()
	for key: String in after:
		compilations_delta[key] = int(after[key]) - int(_before.get(key, 0))


func _add_asset(d: RenderAssetDescriptor, ghost_material: Material) -> void:
	for role in ROLES:
		var mesh := _load_role(d, role)
		if mesh != null and _first("mm", d, role):
			_add_multimesh(mesh, "%s_%s" % [d.asset_id, role])
	var selected := _load_role(d, "selected")
	if selected != null and _first("mi", d, "selected"):
		_add_instance(selected, null, d.asset_id)
	var ghost := _load_role(d, "ghost")
	if ghost != null and _first("ghost", d, "ghost"):
		_add_instance(ghost, ghost_material, d.asset_id + "_ghost")


## True the first time this mesh file is used for `kind` (aliased roles share a file).
func _first(kind: String, d: RenderAssetDescriptor, role: String) -> bool:
	var key := "%s|%s" % [kind, d.dependency(d.resolve_role(role)).path]
	if _seen.has(key):
		return false
	_seen[key] = true
	return true


func _load_role(d: RenderAssetDescriptor, role: String) -> Mesh:
	var dep := d.dependency(d.resolve_role(role))
	if dep.is_empty() or not ResourceLoader.exists(str(dep.path)):
		return null
	return load(str(dep.path)) as Mesh


func _add_multimesh(mesh: Mesh, label: String) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis.from_scale(Vector3.ONE * SCALE), Vector3.ZERO))
	var node := MultiMeshInstance3D.new()
	node.name = label
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(node)


func _add_instance(mesh: Mesh, material: Material, label: String) -> void:
	if mesh == null:
		return
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.material_override = material
	node.scale = Vector3.ONE * SCALE
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(node)


## One triangle with the overview's vertex format (position, normal, colour, index) and its material.
func _overview_mesh(material: Material) -> Mesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh
