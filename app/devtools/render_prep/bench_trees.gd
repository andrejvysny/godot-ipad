extends RefCounted
## Procedural bench vegetation: a modeled broadleaf (nested, mirrored, non-uniformly scaled
## branches carrying leaf-cluster meshes), and two leaf-card plants (pine, bush). Every tier is
## built by the same code at lower detail, so anchor and extents stay consistent.

const MB := preload("res://devtools/render_prep/mesh_builder.gd")
const Common := preload("res://devtools/render_prep/bench_common.gd")
const Atlas := preload("res://devtools/render_prep/atlas_gen.gd")

const BARK := Color(0.33, 0.23, 0.15)
const LEAF := Color(0.30, 0.50, 0.20)
const LEAF_REF_COUNT := 190.0
const CLUSTER_RADIUS := 0.55
const LEAF_MAX_LEN := 0.25


## level: trunk_segs, trunk_rings, branch_segs, branch_rings, sub_segs, subs, sub_mid_cluster, leaves,
## leaf_segs, mode ("tree" | "lobes"), seed.
static func broadleaf(level: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "BroadleafGeo"
	var bark := Common.material("bark", BARK, null, false, false, true, 0.95)
	var leaves := Common.material("leaves", LEAF, null, false, true, true, 0.8)
	var trunk_mesh := _wood(0.38, 0.14, 4.4, int(level.trunk_segs), int(level.trunk_rings))
	var trunk := Common.add(root, "Trunk", trunk_mesh, bark)
	if level.mode == "lobes":
		_lobes(root, level, bark, leaves)
		return root
	var clusters: Array[ArrayMesh] = []
	for v in 3:
		clusters.append(_cluster(level, v))
	var branch_mesh := _wood(0.13, 0.05, 2.2, int(level.branch_segs), int(level.branch_rings))
	var sub_mesh := _wood(0.06, 0.025, 1.1, int(level.sub_segs), 1)
	for i in 6:
		var scale := Vector3.ONE
		if i == 1:
			scale = Vector3(1.25, 1.0, 0.8)
		elif i == 2:
			scale = Vector3(-1.0, 1.0, 1.0)
		var branch := Common.add(trunk, "Branch%d" % i, branch_mesh, bark,
			Common.to_transform(Vector3(0.0, 2.0 + 0.45 * float(i), 0.0), 1.05 * float(i) + 0.3, deg_to_rad(55.0), scale))
		Common.add(branch, "BranchLeaves%d" % i, clusters[i % 3], leaves, Common.to_transform(Vector3(0.0, 2.2, 0.0), 0.5 * float(i)))
		for j in int(level.subs):
			var sub := Common.add(branch, "Sub%d_%d" % [i, j], sub_mesh, bark,
				Common.to_transform(Vector3(0.0, 0.9 + 0.55 * float(j), 0.0), 1.2 if j == 0 else -1.4, deg_to_rad(45.0)))
			Common.add(sub, "SubLeaves%d_%d" % [i, j], clusters[(i + j + 1) % 3], leaves, Common.to_transform(Vector3(0.0, 1.1, 0.0), float(j)))
			if level.sub_mid_cluster:
				Common.add(sub, "SubMid%d_%d" % [i, j], clusters[(i + j + 2) % 3], leaves, Common.to_transform(Vector3(0.0, 0.55, 0.12), 1.0 + float(j)))
	return root


static func _wood(r0: float, r1: float, length: float, segs: int, rings: int) -> ArrayMesh:
	var b := MB.new()
	b.use_col = true
	b.cylinder(Transform3D.IDENTITY, r0, r1, length, segs, rings, BARK, BARK.lightened(0.15))
	return b.to_mesh()


static func _cluster(level: Dictionary, variant: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(level.seed) * 31 + variant
	var b := MB.new()
	b.use_col = true
	var n := int(level.leaves)
	var size_k := sqrt(LEAF_REF_COUNT / float(n))
	var rc := CLUSTER_RADIUS + LEAF_MAX_LEN - LEAF_MAX_LEN * size_k
	for _i in n:
		var dir := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
		var origin := dir * rc * pow(rng.randf(), 1.0 / 3.0)
		var y_axis := (dir * 0.8 + Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()).normalized()
		var x_axis := y_axis.cross(Vector3.UP).normalized()
		var z_axis := x_axis.cross(y_axis)
		var length := rng.randf_range(0.17, LEAF_MAX_LEN) * size_k
		var col := LEAF.lerp(Color(0.45, 0.62, 0.2), rng.randf())
		b.leaf(origin, Basis(x_axis, y_axis, z_axis), length, length * 0.55, int(level.leaf_segs), 0.35, col, dir * 0.9)
	return b.to_mesh()


static func _lobes(root: Node3D, level: Dictionary, bark: Material, leaves: Material) -> void:
	var b := MB.new()
	b.use_col = true
	b.lobe(Vector3.ZERO, Vector3.ONE, 1, LEAF, 0.06, 1.0)
	var mesh := b.to_mesh()
	var specs := [[0.0, 4.9, 0.0, 1.7, 1.15, 1.7], [1.5, 4.3, 0.3, 0.95, 0.85, 0.95], [-1.4, 4.2, -0.8, 1.05, 0.85, 0.95],
		[0.2, 4.0, 1.7, 0.95, 0.8, 0.95], [-0.4, 4.3, -1.7, 0.95, 0.8, 0.95]]
	var i := 0
	for s: Array in specs:
		Common.add(root, "Lobe%d" % i, mesh, leaves, Common.to_transform(Vector3(s[0], s[1], s[2]), 0.0, 0.0, Vector3(s[3], s[4], s[5])))
		i += 1


# --- Pine: cutout cards around a trunk -----------------------------------------------------
## level: levels, radial, layers, trunk_segs, seed. textures: {"foliage": Texture2D|null, "bark": Texture2D|null}.
static func pine(level: Dictionary, textures: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "PineCards"
	var foliage := Common.material("foliage", Color.WHITE, textures.get("foliage"), true)
	var bark := Common.material("bark", Color.WHITE, textures.get("bark"), false, false, false, 0.95)
	var tb := MB.new()
	tb.cylinder_uv = true
	tb.cylinder(Transform3D.IDENTITY, 0.30, 0.08, 9.8, int(level.trunk_segs), 4, Color.WHITE, Color.WHITE)
	Common.add(root, "Trunk", tb.to_mesh(), bark)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(level.seed)
	var b := MB.new()
	var levels := int(level.levels)
	var radial := int(level.radial)
	for li in levels:
		var t := float(li) / float(levels - 1)
		var y := lerpf(1.3, 9.5, t)
		var reach := lerpf(2.25, 0.35, pow(t, 0.9))
		for j in radial:
			for k in int(level.layers):
				var yaw := TAU * (float(j) + 0.5 * float(k % 2) + rng.randf_range(-0.2, 0.2)) / float(radial) + float(li) * 0.7
				var pitch := deg_to_rad(lerpf(35.0, 12.0, t) + rng.randf_range(-6.0, 6.0))
				var cp := cos(pitch)
				var rr := reach * rng.randf_range(0.7, 1.0)
				var width := clampf(TAU * rr / float(radial) * 1.5, 0.45, 1.6)
				var r_tip := sqrt(maxf(rr * rr - width * width * 0.25, 0.04))
				var base_y := y + 0.05 * float(k) + rng.randf_range(-0.04, 0.04)
				var length := minf(maxf((r_tip - 0.15) / cp, 0.2), (base_y - 0.15) / sin(pitch))
				var base := Vector3(sin(yaw) * 0.15, base_y, cos(yaw) * 0.15)
				b.card(base, Vector3(sin(yaw) * cp, -sin(pitch), cos(yaw) * cp), Vector3(cos(yaw), 0.0, -sin(yaw)), length, width,
					Atlas.cell_rect(rng.randi() % 4), Color.WHITE, Vector3.UP * 0.7)
	Common.add(root, "Foliage", b.to_mesh(), foliage)
	return root


# --- Bush: cards in a hemisphere -------------------------------------------------------------
## level: cards, seed. textures: {"bush_leaf": Texture2D|null}.
static func bush(level: Dictionary, textures: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "BushCards"
	var foliage := Common.material("bush_leaf", Color.WHITE, textures.get("bush_leaf"), true)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(level.seed)
	var b := MB.new()
	var n := int(level.cards)
	var size_k := sqrt(600.0 / float(n))
	for _i in n:
		var yaw := rng.randf_range(0.0, TAU)
		var elev := deg_to_rad(rng.randf_range(12.0, 70.0))
		var rb := rng.randf_range(0.0, 0.15)
		var base := Vector3(sin(yaw) * rb, rng.randf_range(0.04, 0.25), cos(yaw) * rb)
		var width := 0.32 * size_k
		var length := minf(rng.randf_range(0.45, 0.8) * size_k, minf((0.78 - rb - width * 0.5) / cos(elev), (0.95 - base.y) / sin(elev)))
		b.card(base, Vector3(sin(yaw) * cos(elev), sin(elev), cos(yaw) * cos(elev)), Vector3(cos(yaw), 0.0, -sin(yaw)), length, width,
			Atlas.cell_rect(rng.randi() % 4), Color.WHITE, Vector3.UP * 0.7)
	Common.add(root, "Cards", b.to_mesh(), foliage)
	return root
