class_name OverviewFixture
extends RefCounted
## ObjectPresenter + OverviewRenderer + camera on a 1 km world rect without a terrain, for the object LOD and
## overview tests. The camera uses the reference fov so metric distance equals effective distance. Frames are
## driven by hand: presenter.service_frame, overview.set_blockers, overview.service.

const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"
const CABIN := "built.lodge.cabin_a"
const GRASS := "nature.cover.grass_tuft_a"
const WORLD := Rect2(-512.0, -512.0, 1024.0, 1024.0)

var tree: SceneTree
var catalog: AssetCatalog
var registry: RenderAssetRegistry
var doc := WorldDocument.new()
var presenter: ObjectPresenter
var world: ObjectRenderWorld
var overview: OverviewRenderer
var camera: Camera3D
var profile := {"near_min_role": "mid", "tree_detail_radius_m": 80.0, "ground_cover_radius_m": 25.0,
	"lod_hysteresis_fraction": 0.2, "settle_ms": 0}
var pins := {}
var selected := AABB()
var _rng := RandomNumberGenerator.new()


func _init(tree_: SceneTree, rect: Rect2 = WORLD) -> void:
	tree = tree_
	catalog = AssetCatalog.load_from()[0]
	registry = RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	presenter = ObjectPresenter.new()
	presenter.setup(catalog, registry)
	tree.root.add_child(presenter)
	world = presenter.render_world()
	camera = Camera3D.new()
	camera.fov = LodPolicy.REFERENCE_FOV_DEG
	tree.root.add_child(camera)
	presenter.set_camera(camera)
	presenter.set_lod_profile(profile)
	overview = OverviewRenderer.new()
	overview.setup(registry, 32.0)
	overview.set_lod_profile(profile)
	overview.set_world_rect(rect)
	tree.root.add_child(overview)
	overview.add_population(world)
	_rng.seed = 2468


func release() -> void:
	for node: Node in [overview, camera, presenter]:
		if is_instance_valid(node):
			tree.root.remove_child(node)
			node.free()


func set_profile(p: Dictionary) -> void:
	profile = p
	presenter.set_lod_profile(p)
	overview.set_lod_profile(p)


func add(asset_id: String, pos: Vector3, yaw: float = 0.0, scale: float = 1.0) -> ObjectRecord:
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.asset_id = asset_id
	r.asset_version = 1
	r.set_position(pos.x, pos.y, pos.z)
	r.set_yaw(yaw)
	r.uniform_scale = scale
	doc.put_object(r)
	return r


## Forest patches: `patches` discs of `per_patch` objects (mostly spruce, some boulders, a cabin per patch) with
## a clearing of `clearing_m` radius in the middle of each. Returns the patch centres.
func add_patches(patches: int, per_patch: int, radius_m: float, clearing_m: float) -> Array[Vector3]:
	var centres: Array[Vector3] = []
	for p in patches:
		var c := Vector3(_rng.randf_range(-420.0, 420.0), 0.0, _rng.randf_range(-420.0, 420.0))
		centres.append(c)
		for i in per_patch:
			var a := _rng.randf() * TAU
			var d := sqrt(_rng.randf_range(clearing_m * clearing_m / (radius_m * radius_m), 1.0)) * radius_m
			var kind := SPRUCE
			if i % 12 == 0:
				kind = BOULDER
			elif i == 0:
				kind = CABIN
			add(kind, c + Vector3(cos(a) * d, 0.0, sin(a) * d), _rng.randf() * TAU, _rng.randf_range(0.8, 1.4))
	return centres


func sync_all() -> void:
	presenter.rebuild(doc)


func sync(id: String) -> void:
	presenter.sync_object(doc, id)


## Camera at `pos` looking at `target` (up is -Z so a straight-down view is valid).
func aim(pos: Vector3, target: Vector3) -> void:
	camera.global_position = pos
	camera.look_at(target, Vector3(0.0, 0.0, -1.0))


## Metric camera distance that gives `effective_m` for the fixture camera (the root viewport is not 820 px high).
func metric(effective_m: float) -> float:
	return effective_m / LodPolicy.effective_distance(1.0, camera.fov, camera.get_viewport().get_visible_rect().size.y)


func frame() -> void:
	presenter.service_frame(1.0)
	overview.set_blockers(pins, selected)
	overview.service(camera)


func busy() -> bool:
	return presenter.has_pending_work() or overview.has_pending_work()


## Frames until `done` returns true; false after `max_ms`.
func run_until(done: Callable, max_ms: int = 15000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		frame()
		if done.call():
			return true
		OS.delay_msec(1)
	return false


func settle(max_ms: int = 15000) -> bool:
	var ok := run_until(func() -> bool: return not busy(), max_ms)
	for i in 3:
		frame()
	return ok


func total_objects() -> int:
	return doc.objects.size()


func active_groups() -> Array:
	var out: Array = []
	for lvl in 2:
		for g: OverviewGroup in overview.groups(lvl):
			if g.active:
				out.append(g)
	return out


## Instances drawn individually (visible batches and the promoted node).
func visible_individuals() -> int:
	return int(world.stats().visible_instances)


## Proxy members of the active groups: every meaningful instance they represent.
func proxied_members() -> int:
	var n := 0
	for g: OverviewGroup in active_groups():
		n += g.members
	return n
