extends RefCounted
## Procedural bench rock, multipart structure and ground-cover clump.

const MB := preload("res://devtools/render_prep/mesh_builder.gd")
const Common := preload("res://devtools/render_prep/bench_common.gd")
const Atlas := preload("res://devtools/render_prep/atlas_gen.gd")

const STONE := Color(0.5, 0.49, 0.46)
const TIMBER := Color(0.55, 0.38, 0.22)
const SHINGLE := Color(0.3, 0.12, 0.1)
const WALL := Color(0.62, 0.6, 0.56)


## level: segs, rings.
static func rock(level: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "SlabA"
	var mat := Common.material("slab", STONE, null, false, false, true, 0.95)
	var b := MB.new()
	b.use_col = true
	b.displaced_ellipsoid(Vector3(0.0, 0.45, 0.0), Vector3(1.5, 0.62, 1.0), int(level.segs), int(level.rings), 0.12, 0.0, STONE)
	Common.add(root, "Slab", b.to_mesh(), mat)
	return root


## level: sd_base, sd_body, sd_wing, roof_rings, single_material (far tier).
static func tower(level: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "TowerA"
	var stone := Common.material("stone", WALL)
	var timber := Common.material("timber", TIMBER)
	var shingle := Common.material("shingle", SHINGLE)
	if level.get("single_material", false):
		stone = Common.material("stone", WALL)
		timber = stone
		shingle = stone
	var base := Common.add(root, "Base", _box(Vector3(4.2, 1.2, 4.2), int(level.sd_base)), stone, Common.to_transform(Vector3(0.0, 0.6, 0.0)))
	var body := Common.add(base, "Body", _box(Vector3(2.6, 6.0, 2.6), int(level.sd_body)), stone, Common.to_transform(Vector3(0.0, 3.6, 0.0), 0.1))
	Common.add(body, "Roof", _pyramid(2.6, 2.8, int(level.roof_rings)), shingle, Common.to_transform(Vector3(0.0, 4.4, 0.0), PI * 0.25))
	var wing_mesh := _box(Vector3(2.8, 3.0, 2.0), int(level.sd_wing))
	var wing_roof := _prism(Vector3(2.8, 1.4, 2.4))
	for side in 2:
		var scale := Vector3.ONE if side == 0 else Vector3(-1.0, 1.0, 1.0)
		var wing := Common.add(body, "Wing%d" % side, wing_mesh, timber, Common.to_transform(Vector3(2.6 * scale.x, -1.5, 0.0), 0.2, 0.0, scale))
		Common.add(wing, "WingRoof%d" % side, wing_roof, shingle, Common.to_transform(Vector3(0.0, 2.2, 0.0)))
	return root


static func _box(size: Vector3, subdivide: int) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	m.subdivide_width = subdivide
	m.subdivide_height = subdivide
	m.subdivide_depth = subdivide
	return m


static func _pyramid(width: float, height: float, rings: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = width * 0.5 * sqrt(2.0)
	m.height = height
	m.radial_segments = 4
	m.rings = rings
	return m


static func _prism(size: Vector3) -> PrismMesh:
	var m := PrismMesh.new()
	m.size = size
	return m


# --- Grass clump of cutout cards -------------------------------------------------------------
## level: cards, seed. textures: {"grass": Texture2D|null}.
static func grass_mesh(level: Dictionary, mat: Material) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(level.seed)
	var b := MB.new()
	var n := int(level.cards)
	var size_k := sqrt(32.0 / float(n))
	for i in n:
		var yaw := TAU * (float(i) + rng.randf_range(-0.3, 0.3)) / float(n)
		var width := 0.2 * size_k
		var length := rng.randf_range(0.4, 0.52)
		var lean := deg_to_rad(rng.randf_range(8.0, 22.0))
		# Keep the card's outer corner inside the clump radius of the full-detail tier.
		var max_reach := sqrt(maxf(0.235 * 0.235 - width * width * 0.25, 0.0004))
		lean = minf(lean, asin(clampf((max_reach - 0.03) / length, 0.0, 1.0)))
		var base := Vector3(sin(yaw) * 0.03, 0.0, cos(yaw) * 0.03)
		b.card(base, Vector3(sin(yaw) * sin(lean), cos(lean), cos(yaw) * sin(lean)), Vector3(cos(yaw), 0.0, -sin(yaw)), length, width,
			Atlas.cell_rect(i % 4), Color.WHITE, Vector3.UP * 0.8)
	var mesh := b.to_mesh()
	mesh.surface_set_material(0, mat)
	return mesh


static func grass(level: Dictionary, textures: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "GrassCards"
	var mat := Common.material("grass", Color.WHITE, textures.get("grass"), true)
	Common.add(root, "Clump", grass_mesh(level, mat), null)
	return root
