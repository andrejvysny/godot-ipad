class_name ScatterBuild
extends RefCounted
## Transforms of scatter instances. Y is the bilinear terrain height (an instance without a sample is
## skipped); the tilt flag aligns the instance to the terrain normal. Pure over a document and one
## ScatterCell list: never mutates either.

const FLOATS := 12


## Farthest corner of `aabb` from the mesh origin: a rotation-proof radius for conservative bounds.
static func reach_of(aabb: AABB) -> float:
	var r := 0.0
	for i in 8:
		r = maxf(r, aabb.get_endpoint(i).length())
	return r


static func basis_of(doc: WorldDocument, x: float, z: float, yaw: float, scale_value: float, flags: int) -> Basis:
	var basis := Basis(Vector3.UP, yaw)
	if (flags & ScatterLayer.FLAG_TILT) != 0:
		var normal := doc.sample_normal(x, z)
		if normal.is_finite():
			basis = Basis(Quaternion(Vector3.UP, normal)) * basis
	return basis.scaled(Vector3.ONE * scale_value)


## World transform of one instance, or null without a terrain sample.
static func world_transform(doc: WorldDocument, x: float, z: float, yaw: float, scale_value: float, flags: int) -> Variant:
	var h := doc.sample_height(x, z)
	if is_nan(h):
		return null
	return Transform3D(basis_of(doc, x, z, yaw, scale_value, flags), Vector3(x, h, z))


## {"buffer": PackedFloat32Array (cell-local), "count": int, "aabb": AABB (cell-local, conservative)} of the
## instances of `asset_id` in `cell` that are kept at `density` (decorative cells only; meaningful cells
## pass 1.0). `reach` is reach_of() of the mesh (or placeholder bounds); `place` fits the unit placeholder
## box to the asset bounds when `use_place`.
static func build(doc: WorldDocument, cell: ScatterCell, asset_id: String, origin: Vector3, reach: float,
		use_place: bool, place: Transform3D, density: float, seed_value: int) -> Dictionary:
	var xz: PackedFloat32Array = cell.xz[asset_id]
	var attr: PackedFloat32Array = cell.attr[asset_id]
	var n := xz.size() / 2
	var thin := cell.kind == ScatterCell.DECORATIVE and density < 1.0
	var keys := PackedInt64Array()
	var limit := density * ScatterDensity.RANGE
	if thin:
		keys = ScatterDensity.cell_keys(cell, asset_id, seed_value)
	var out := PackedFloat32Array()
	out.resize(n * FLOATS)
	var o := 0
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in n:
		if thin and float(keys[i]) >= limit:
			continue
		var x := xz[i * 2]
		var z := xz[i * 2 + 1]
		var h := doc.sample_height(x, z)
		if is_nan(h):
			continue
		var s := attr[i * 3 + 1]
		var basis := basis_of(doc, x, z, attr[i * 3], s, int(attr[i * 3 + 2]))
		var p := Vector3(x, h, z)
		var r := reach * s
		lo = Vector3(minf(lo.x, x - r), minf(lo.y, h - r), minf(lo.z, z - r))
		hi = Vector3(maxf(hi.x, x + r), maxf(hi.y, h + r), maxf(hi.z, z + r))
		if use_place:
			var placed := Transform3D(basis, p) * place
			basis = placed.basis
			p = placed.origin
		p -= origin
		out[o] = basis.x.x
		out[o + 1] = basis.y.x
		out[o + 2] = basis.z.x
		out[o + 3] = p.x
		out[o + 4] = basis.x.y
		out[o + 5] = basis.y.y
		out[o + 6] = basis.z.y
		out[o + 7] = p.y
		out[o + 8] = basis.x.z
		out[o + 9] = basis.y.z
		out[o + 10] = basis.z.z
		out[o + 11] = p.z
		o += FLOATS
	out.resize(o)
	var box := AABB() if o == 0 else AABB(lo - origin, hi - lo)
	return {"buffer": out, "count": o / FLOATS, "aabb": box}
