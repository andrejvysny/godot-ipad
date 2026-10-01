class_name OverviewClusterBuilder
extends RefCounted
## Deterministic proxy geometry of one overview group (spec §9.2). Pure plain-array logic that runs on a
## WorkerThreadPool task: it never touches nodes, resources or documents.
## Instances are binned into an occupancy grid per kind (canopy / solid); every occupied grid cell keeps its
## max top, min base and average colour and emits one lobe (canopy: 8-sided frustum sized to the grid cell x
## OVERSIZE so neighbours merge; solid: box). Solids wider than the grid cell are emitted individually to
## keep silhouettes. Empty grid cells stay empty. Output is independent of the input order: bins keep only
## max/min/integer sums and lobes are emitted in sorted key order. More than MAX_LOBES lobes aggregate 2x2.
## All vertices are local to `origin` (the group rect's XZ corner, y absolute). Triangles are clockwise
## seen from outside (Godot front faces).

const MAX_LOBES := 1024
const SIDES := 8
const OVERSIZE := 1.15
const TOP_RATIO := 0.35
const MIN_HEIGHT := 0.2
const COLOR_STEPS := 1023.0
const KEY_SHIFT := 12  # grid key = gx << KEY_SHIFT | gz (both < 4096)
const KEY_MASK := 4095
const ROW := 8  # table floats per asset: kind, shape, base_y, height, radius, r, g, b
const KIND_NONE := 0
const KIND_CANOPY := 1
const KIND_SOLID := 2
const SHAPE_CONE := 0
const SHAPE_ELLIPSOID := 1
const SHAPE_BOX := 2
const INDIVIDUAL_TOP_RATIO := {SHAPE_CONE: 0.15, SHAPE_ELLIPSOID: 0.6}


## Mesh data under construction; vertices are local to the group origin.
class Surface extends RefCounted:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var boxes := PackedVector3Array()  # (min, size) per lobe, local
	var lobes: int = 0

	func add_vertex(p: Vector3, n: Vector3, c: Color) -> int:
		vertices.append(p)
		normals.append(n)
		colors.append(c)
		return vertices.size() - 1

	func add_tri(a: int, b: int, c: int) -> void:
		indices.append_array(PackedInt32Array([a, b, c]))

	func to_dict() -> Dictionary:
		return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
			"boxes": boxes, "lobes": lobes, "triangles": int(indices.size() / 3.0)}


## Row of the asset table for a descriptor's overview dictionary.
static func table_row(overview: Dictionary) -> PackedFloat32Array:
	var kinds := {"none": KIND_NONE, "canopy": KIND_CANOPY, "solid": KIND_SOLID}
	var shapes := {"cone": SHAPE_CONE, "ellipsoid": SHAPE_ELLIPSOID, "box": SHAPE_BOX}
	var c: Color = overview.color
	return PackedFloat32Array([kinds[str(overview.kind)], shapes[str(overview.shape)], float(overview.base_y_m),
		float(overview.height_m), float(overview.radius_m), c.r, c.g, c.b])


## input: origin Vector2, size_m, cell_m (initial grid cell), positions PackedVector3Array, assets
## PackedInt32Array (row index), scale_xz / scale_y PackedFloat32Array, table PackedFloat32Array.
## Returns {"canopy": surface, "solid": surface, "lobes", "triangles", "cell_m", "min_y", "max_y"}.
static func build(input: Dictionary) -> Dictionary:
	var size: float = input.size_m
	var cell: float = input.cell_m
	var bins := _bin(input, cell)
	while _lobe_count(bins) > MAX_LOBES and cell < size:
		cell *= 2.0
		bins = _bin(input, cell)
	return _emit(input, bins, cell)


## WorkerThreadPool entry: writes {"result", "usec"} into `out`, which the main thread reads after the task ended.
static func run(input: Dictionary, out: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	out["result"] = build(input)
	out["usec"] = Time.get_ticks_usec() - t0


static func empty_result() -> Dictionary:
	var s := Surface.new().to_dict()
	return {"canopy": s, "solid": s.duplicate(), "lobes": 0, "triangles": 0, "cell_m": 0.0, "min_y": 0.0, "max_y": 0.0}


static func _bin(input: Dictionary, cell: float) -> Dictionary:
	var origin: Vector2 = input.origin
	var n_cells := maxi(int(ceilf(float(input.size_m) / cell)), 1)
	var positions: PackedVector3Array = input.positions
	var assets: PackedInt32Array = input.assets
	var sxz: PackedFloat32Array = input.scale_xz
	var sy: PackedFloat32Array = input.scale_y
	var table: PackedFloat32Array = input.table
	var canopy := {}
	var solid := {}
	var individual: Array = []
	for i in positions.size():
		var row: int = assets[i] * ROW
		var kind := int(table[row])
		if kind == KIND_NONE:
			continue
		var p := positions[i]
		var base := p.y + table[row + 2] * sy[i]
		var top := base + table[row + 3] * sy[i]
		var radius := table[row + 4] * sxz[i]
		if kind == KIND_SOLID and radius * 2.0 > cell:
			individual.append(PackedFloat32Array([p.x, p.z, base, top, radius, table[row + 1],
				table[row + 5], table[row + 6], table[row + 7]]))
			continue
		var gx := clampi(floori((p.x - origin.x) / cell), 0, n_cells - 1)
		var gz := clampi(floori((p.z - origin.y) / cell), 0, n_cells - 1)
		var key := (gx << KEY_SHIFT) | gz
		var bins: Dictionary = canopy if kind == KIND_CANOPY else solid
		var acc: PackedFloat64Array = bins[key] if bins.has(key) else PackedFloat64Array([-INF, INF, 0.0, 0.0, 0.0, 0.0, 0.0])
		acc[0] = maxf(acc[0], top)
		acc[1] = minf(acc[1], base)
		acc[2] += roundf(table[row + 5] * COLOR_STEPS)
		acc[3] += roundf(table[row + 6] * COLOR_STEPS)
		acc[4] += roundf(table[row + 7] * COLOR_STEPS)
		acc[5] += 1.0
		acc[6] = maxf(acc[6], radius)
		bins[key] = acc
	individual.sort_custom(_row_less)
	return {"canopy": canopy, "solid": solid, "individual": individual}


static func _lobe_count(bins: Dictionary) -> int:
	return (bins.canopy as Dictionary).size() + (bins.solid as Dictionary).size() + (bins.individual as Array).size()


static func _row_less(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	for k in a.size():
		if a[k] != b[k]:
			return a[k] < b[k]
	return false


static func _emit(input: Dictionary, bins: Dictionary, cell: float) -> Dictionary:
	var origin: Vector2 = input.origin
	var canopy := Surface.new()
	var solid := Surface.new()
	var min_y := INF
	var max_y := -INF
	for kind in [KIND_CANOPY, KIND_SOLID]:
		var grid: Dictionary = bins.canopy if kind == KIND_CANOPY else bins.solid
		var surf: Surface = canopy if kind == KIND_CANOPY else solid
		var keys := PackedInt32Array(grid.keys())
		keys.sort()
		for key in keys:
			var acc: PackedFloat64Array = grid[key]
			var count := acc[5]
			var color := Color(acc[2] / count / COLOR_STEPS, acc[3] / count / COLOR_STEPS, acc[4] / count / COLOR_STEPS)
			var cx := (float(key >> KEY_SHIFT) + 0.5) * cell
			var cz := (float(key & KEY_MASK) + 0.5) * cell
			var top := maxf(float(acc[0]), float(acc[1]) + MIN_HEIGHT)
			if kind == KIND_CANOPY:
				var r := cell * 0.5 * OVERSIZE
				_frustum(surf, cx, cz, float(acc[1]), top, r, r * TOP_RATIO, color)
			else:
				var h := clampf(float(acc[6]), 0.5, cell * 0.5)
				_box(surf, cx - h, cz - h, cx + h, cz + h, float(acc[1]), top, color)
			min_y = minf(min_y, float(acc[1]))
			max_y = maxf(max_y, top)
	for row: PackedFloat32Array in bins.individual:
		var x := row[0] - origin.x
		var z := row[1] - origin.y
		var top := maxf(row[3], row[2] + MIN_HEIGHT)
		var color := Color(row[6], row[7], row[8])
		if int(row[5]) == SHAPE_BOX:
			_box(solid, x - row[4], z - row[4], x + row[4], z + row[4], row[2], top, color)
		else:
			var ratio: float = INDIVIDUAL_TOP_RATIO[int(row[5])]
			_frustum(solid, x, z, row[2], top, row[4], row[4] * ratio, color)
		min_y = minf(min_y, row[2])
		max_y = maxf(max_y, top)
	var result := {"canopy": canopy.to_dict(), "solid": solid.to_dict(), "cell_m": cell,
		"lobes": canopy.lobes + solid.lobes, "min_y": min_y if min_y < INF else 0.0, "max_y": max_y if max_y > -INF else 0.0}
	result["triangles"] = int(result.canopy.triangles) + int(result.solid.triangles)
	return result


## Eight-sided frustum (no bottom face) with a top cap. Cell and individual coordinates are group-local.
static func _frustum(s: Surface, cx: float, cz: float, base: float, top: float, r_bottom: float, r_top: float,
		color: Color) -> void:
	var slope := (r_bottom - r_top) / maxf(top - base, MIN_HEIGHT)
	var bottom_ring := PackedInt32Array()
	var top_ring := PackedInt32Array()
	var cap_ring := PackedInt32Array()
	for k in SIDES:
		var a := TAU * float(k) / float(SIDES)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var n := Vector3(dir.x, slope, dir.z).normalized()
		bottom_ring.append(s.add_vertex(Vector3(cx + dir.x * r_bottom, base, cz + dir.z * r_bottom), n, color))
		top_ring.append(s.add_vertex(Vector3(cx + dir.x * r_top, top, cz + dir.z * r_top), n, color))
		cap_ring.append(s.add_vertex(Vector3(cx + dir.x * r_top, top, cz + dir.z * r_top), Vector3.UP, color))
	var center := s.add_vertex(Vector3(cx, top, cz), Vector3.UP, color)
	for k in SIDES:
		var k2 := (k + 1) % SIDES
		s.add_tri(bottom_ring[k], bottom_ring[k2], top_ring[k2])
		s.add_tri(bottom_ring[k], top_ring[k2], top_ring[k])
		s.add_tri(center, cap_ring[k], cap_ring[k2])
	_note_box(s, cx - r_bottom, base, cz - r_bottom, cx + r_bottom, top, cz + r_bottom)


## Box without a bottom face: top plus four sides.
static func _box(s: Surface, x0: float, z0: float, x1: float, z1: float, base: float, top: float, color: Color) -> void:
	var t := PackedInt32Array([
		s.add_vertex(Vector3(x0, top, z0), Vector3.UP, color), s.add_vertex(Vector3(x1, top, z0), Vector3.UP, color),
		s.add_vertex(Vector3(x1, top, z1), Vector3.UP, color), s.add_vertex(Vector3(x0, top, z1), Vector3.UP, color)])
	s.add_tri(t[0], t[1], t[2])
	s.add_tri(t[0], t[2], t[3])
	# Side faces: (normal, start corner, left corner as seen from outside).
	var faces := [
		[Vector3.RIGHT, Vector2(x1, z0), Vector2(x1, z1)], [Vector3.LEFT, Vector2(x0, z1), Vector2(x0, z0)],
		[Vector3.BACK, Vector2(x1, z1), Vector2(x0, z1)], [Vector3.FORWARD, Vector2(x0, z0), Vector2(x1, z0)]]
	for f: Array in faces:
		var a: Vector2 = f[1]
		var b: Vector2 = f[2]
		var bottom_a := s.add_vertex(Vector3(a.x, base, a.y), f[0], color)
		var bottom_b := s.add_vertex(Vector3(b.x, base, b.y), f[0], color)
		var top_b := s.add_vertex(Vector3(b.x, top, b.y), f[0], color)
		var top_a := s.add_vertex(Vector3(a.x, top, a.y), f[0], color)
		s.add_tri(bottom_a, bottom_b, top_b)
		s.add_tri(bottom_a, top_b, top_a)
	_note_box(s, x0, base, z0, x1, top, z1)


static func _note_box(s: Surface, x0: float, y0: float, z0: float, x1: float, y1: float, z1: float) -> void:
	s.boxes.append(Vector3(x0, y0, z0))
	s.boxes.append(Vector3(x1 - x0, y1 - y0, z1 - z0))
	s.lobes += 1
