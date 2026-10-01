class_name BenchWorlds
extends RefCounted
## Builds the in-memory documents of the representative benchmark scenarios (spec §20.1). Never saved.
## Everything is derived from the seed: object ids come from BenchPlan.bench_object_id, forest patches and
## clearings from a seeded RNG, FOLLOW_TERRAIN heights from the document's own terrain. Meaningful objects
## are manual records inside forest patches (clearings stay open); decorative grass is a ScatterLayer in the
## open areas. `overrides` {"objects": n, "scatter": n} replace the counts of scenarios that have objects/scatter (small test variants).

const FIXTURE := "gentle_hills"
const PATCH_MARGIN_M := 24.0
const PATCH_RADIUS_RANGE := Vector2(45.0, 90.0)
const CLEARINGS_PER_PATCH := 2
const MAX_TRIES := 40
const GRASS_CLUSTER_SIZE := 250
const GRASS_CLUSTER_RADIUS_M := 14.0
const CROWN_FRACTION := 0.85


## Returns {"doc", "catalog_kind", "population", "anchors", "build_ms", "error"}; doc is null with an error text
## when a catalog or fixture is missing.
static func build(name: String, editor_catalog: AssetCatalog, bench_catalog: AssetCatalog, seed_value: int,
		overrides: Dictionary = {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var def := BenchScenarios.definition(name)
	if def.is_empty():
		return _failed("Unknown bench scenario '%s'." % name)
	var catalog := bench_catalog if def.catalog == "bench" else editor_catalog
	var made := _terrain(def, catalog)
	if made[1] != "":
		return _failed(str(made[1]))
	var doc: WorldDocument = made[0]
	var objects := int(overrides.get("objects", def.objects)) if int(def.objects) > 0 else 0
	var scatter := int(overrides.get("scatter", def.scatter)) if int(def.scatter) > 0 else 0
	var layout_data := _patch_layout(doc, def, seed_value)
	var by_asset := {}
	if def.has("primitive"):
		for rec in BenchPlan.synth_objects(doc, catalog, objects, seed_value):
			doc.put_object(rec)
		by_asset = {"primitive_catalog_objects": doc.objects.size()}
	elif objects > 0:
		by_asset = _place_objects(doc, catalog, def.mix, objects, seed_value, layout_data)
	if scatter > 0:
		_place_grass(doc, catalog, scatter, seed_value, layout_data)
	var anchors := _anchors(doc, def, layout_data, catalog)
	var population := {"world": str(def.world), "layout": doc.layout.name(), "authored_meaningful": doc.objects.size(),
		"decorative": doc.scatter.count(), "by_asset": by_asset, "patches": (layout_data.patches as Array).size()}
	return {"doc": doc, "catalog_kind": str(def.catalog), "population": population, "anchors": anchors,
		"build_ms": float(Time.get_ticks_usec() - t0) / 1000.0, "error": ""}


static func _failed(message: String) -> Dictionary:
	return {"doc": null, "error": message, "population": {}, "anchors": {}, "build_ms": 0.0, "catalog_kind": ""}


static func _terrain(def: Dictionary, catalog: AssetCatalog) -> Array:
	if catalog == null:
		return [null, "Bench catalog is not loaded."]
	if def.world == "legacy":
		var loaded := SessionWorldOps.load_fixture(FIXTURE, catalog)
		if loaded[1] != "":
			return loaded
		var doc: WorldDocument = loaded[0]
		doc.objects.clear()
		doc.paths.clear()
		doc.scatter = ScatterLayer.new()
		return [doc, ""]
	return SessionWorldOps.new_layout_world(WorldLayout.km1(), "hills", catalog)


## {"patches": [{center: Vector2, radius: float, clearings: [{c: Vector2, r: float}]}]}; empty for scenarios
## without forest patches.
static func _patch_layout(doc: WorldDocument, def: Dictionary, seed_value: int) -> Dictionary:
	var out := {"patches": []}
	var count := int(def.get("patches", 0))
	if count == 0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x5EED
	var rect := doc.layout.world_rect().grow(-PATCH_MARGIN_M)
	var patches: Array = out.patches
	for i in count:
		var radius := rng.randf_range(PATCH_RADIUS_RANGE.x, PATCH_RADIUS_RANGE.y)
		var inner := rect.grow(-radius * 0.5)
		var center := Vector2(rng.randf_range(inner.position.x, inner.end.x), rng.randf_range(inner.position.y, inner.end.y))
		var clearings: Array = []
		for _c in CLEARINGS_PER_PATCH:
			var angle := rng.randf_range(0.0, TAU)
			var dist := rng.randf_range(0.0, 0.55) * radius
			clearings.append({"c": center + Vector2(cos(angle), sin(angle)) * dist, "r": rng.randf_range(0.12, 0.2) * radius})
		patches.append({"center": center, "radius": radius, "clearings": clearings})
	return out


static func in_clearing(patch: Dictionary, p: Vector2) -> bool:
	for c: Dictionary in patch.clearings:
		if p.distance_to(c.c) < float(c.r):
			return true
	return false


static func is_open(layout_data: Dictionary, p: Vector2) -> bool:
	for patch: Dictionary in layout_data.patches:
		if p.distance_to(patch.center) < float(patch.radius) and not in_clearing(patch, p):
			return false
	return true


## A point in a patch (weighted by area) outside its clearings, or inside a clearing when `clearing` is set.
static func _patch_point(rng: RandomNumberGenerator, layout_data: Dictionary, clearing: bool) -> Vector3:
	var patches: Array = layout_data.patches
	var total := 0.0
	for patch: Dictionary in patches:
		total += float(patch.radius) * float(patch.radius)
	for _try in MAX_TRIES:
		var pick := rng.randf() * total
		var chosen: Dictionary = patches[patches.size() - 1]
		for patch: Dictionary in patches:
			pick -= float(patch.radius) * float(patch.radius)
			if pick <= 0.0:
				chosen = patch
				break
		var center: Vector2 = chosen.center
		var radius := float(chosen.radius)
		if clearing:
			var c: Dictionary = (chosen.clearings as Array)[rng.randi() % CLEARINGS_PER_PATCH]
			center = c.c
			radius = float(c.r)
		var angle := rng.randf_range(0.0, TAU)
		var dist := sqrt(rng.randf()) * radius
		var p := center + Vector2(cos(angle), sin(angle)) * dist
		if clearing or not in_clearing(chosen, p):
			return Vector3(p.x, 0.0, p.y)
	var fallback: Dictionary = patches[0]
	return Vector3(fallback.center.x, 0.0, fallback.center.y)


static func _quotas(mix: Array, count: int) -> Array[int]:
	var out: Array[int] = []
	var assigned := 0
	for entry: Array in mix:
		var n := int(floor(float(entry[1]) * float(count)))
		out.append(n)
		assigned += n
	out[0] += count - assigned
	return out


static func _place_objects(doc: WorldDocument, catalog: AssetCatalog, mix: Array, count: int, seed_value: int,
		layout_data: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var quotas := _quotas(mix, count)
	var order: Array[int] = []  # mix index per record, shuffled so assets interleave
	for k in mix.size():
		for _n in quotas[k]:
			order.append(k)
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var t := order[i]
		order[i] = order[j]
		order[j] = t
	var by_asset := {}
	for i in order.size():
		var asset_id := str((mix[order[i]] as Array)[0])
		var rec := _record(doc, catalog.get_asset(asset_id), rng, BenchPlan.bench_object_id(seed_value, i), layout_data)
		doc.put_object(rec)
		by_asset[asset_id] = int(by_asset.get(asset_id, 0)) + 1
	return by_asset


static func _record(doc: WorldDocument, asset: AssetDefinition, rng: RandomNumberGenerator, id: String,
		layout_data: Dictionary) -> ObjectRecord:
	var p := _patch_point(rng, layout_data, asset.asset_id == "bench.structure.tower_a")
	var rec := ObjectRecord.new()
	rec.object_id = id
	rec.asset_id = asset.asset_id
	rec.asset_version = asset.version
	var y := doc.sample_height(p.x, p.z)
	rec.set_position(p.x, 0.0 if is_nan(y) else y, p.z)
	var q := Quaternion(Vector3.UP, rng.randf_range(0.0, TAU))
	rec.rotation_xyzw = PackedFloat64Array([q.x, q.y, q.z, q.w])
	rec.uniform_scale = rng.randf_range(asset.scale_min, asset.scale_max)
	rec.grounding = WorldConstants.GROUNDING_FOLLOW
	rec.height_offset_m = 0.0
	rec.origin = WorldConstants.ORIGIN_MANUAL
	return rec


## Grass clusters of GRASS_CLUSTER_SIZE clumps around centres in the open areas (never inside a forest patch).
static func _place_grass(doc: WorldDocument, catalog: AssetCatalog, count: int, seed_value: int,
		layout_data: Dictionary) -> void:
	var asset := catalog.get_asset(BenchScenarios.GRASS)
	if asset == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x6A55
	var rect := doc.layout.world_rect().grow(-GRASS_CLUSTER_RADIUS_M)
	var limit := int(WorldLimits.for_schema(doc.layout.schema_version()).max_scatter_instances)
	var center := Vector2.ZERO
	var in_cluster := GRASS_CLUSTER_SIZE
	for _i in count:
		if in_cluster >= GRASS_CLUSTER_SIZE:
			center = _open_point(rng, rect, layout_data)
			in_cluster = 0
		in_cluster += 1
		var p := _open_point_near(rng, center, rect, layout_data)
		doc.scatter.add(asset.asset_id, asset.version, p.x, p.y, rng.randf_range(0.0, TAU),
				rng.randf_range(asset.scale_min, asset.scale_max), 0, limit)


static func _open_point(rng: RandomNumberGenerator, rect: Rect2, layout_data: Dictionary) -> Vector2:
	var p := Vector2.ZERO
	for _try in MAX_TRIES:
		p = Vector2(rng.randf_range(rect.position.x, rect.end.x), rng.randf_range(rect.position.y, rect.end.y))
		if is_open(layout_data, p):
			return p
	return p


static func _open_point_near(rng: RandomNumberGenerator, center: Vector2, rect: Rect2, layout_data: Dictionary) -> Vector2:
	var p := center
	for _try in MAX_TRIES:
		var angle := rng.randf_range(0.0, TAU)
		p = center + Vector2(cos(angle), sin(angle)) * (sqrt(rng.randf()) * GRASS_CLUSTER_RADIUS_M)
		if rect.has_point(p) and is_open(layout_data, p):
			return p
	return center


## Where the camera paths look: the densest patch (most meaningful records), the patch farthest from it, and a
## crown height. Worlds without patches use fixed fractions of the world rectangle.
static func _anchors(doc: WorldDocument, def: Dictionary, layout_data: Dictionary, catalog: AssetCatalog) -> Dictionary:
	var rect := doc.layout.world_rect()
	var a := rect.position + rect.size * 0.3
	var b := rect.position + rect.size * 0.7
	var densest := 0
	var patches: Array = layout_data.patches
	if not patches.is_empty():
		var counts: Array[int] = []
		counts.resize(patches.size())
		counts.fill(0)
		for rec: ObjectRecord in doc.objects.values():
			var p := Vector2(rec.position[0], rec.position[2])
			for i in patches.size():
				if p.distance_to((patches[i] as Dictionary).center) < float((patches[i] as Dictionary).radius):
					counts[i] += 1
					break
		for i in counts.size():
			if counts[i] > counts[densest]:
				densest = i
		a = (patches[densest] as Dictionary).center
		var far := densest
		for i in patches.size():
			if a.distance_to((patches[i] as Dictionary).center) > a.distance_to((patches[far] as Dictionary).center):
				far = i
		b = (patches[far] as Dictionary).center
		densest = counts[densest]
	else:
		densest = 0
	return {"focus": a, "far": b, "densest_count": densest, "crown_height_m": _crown_height(def, catalog),
		"rect": rect}


static func _crown_height(def: Dictionary, catalog: AssetCatalog) -> float:
	var best := 3.0
	for entry: Array in def.get("mix", []):
		var asset := catalog.get_asset(str(entry[0]))
		if asset != null and asset.category == "trees":
			best = maxf(best, asset.bounds.size.y * (asset.scale_min + asset.scale_max) * 0.5 * CROWN_FRACTION)
	return best
