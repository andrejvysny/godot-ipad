class_name ScatterPreview
extends RefCounted
## Top-down instance layout of a scatter set on a flat 50 x 35 m patch (docs/editor-v2.md §6, §9): the
## candidate loop of ScatterSetStore sets without a slope filter. Pure and seeded, so the same set and
## seed always give the same instances.

const PATCH := Vector2(50.0, 35.0)
const CELL := 2.0
const MAX_TRIES := 6000
const TRY_FACTOR := 0.6


## Instances {asset_id, x, z, scale} sorted back to front (z ascending); x in [0, 50), z in [0, 35).
static func generate(set_data: Dictionary, catalog: AssetCatalog, seed_value: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var items: Array[Dictionary] = []
	var total := 0.0
	for item: Dictionary in set_data.get("items", []):
		if catalog.get_asset(str(item.asset_id)) != null:
			items.append(item)
			total += float(item.weight)
	if items.is_empty():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var tries := mini(MAX_TRIES, roundi(float(set_data.density) * PATCH.x * PATCH.y * TRY_FACTOR))
	var grid: Dictionary = {}
	for i in tries:
		var candidate := _candidate(rng, items, total, catalog)
		var pos := Vector2(rng.randf() * PATCH.x, rng.randf() * PATCH.y)
		if _is_free(grid, out, pos, maxf(float(set_data.spacing), 0.8 * float(candidate.radius))):
			var key := Vector2i(floori(pos.x / CELL), floori(pos.y / CELL))
			if not grid.has(key):
				grid[key] = []
			(grid[key] as Array).append(out.size())
			out.append({"asset_id": candidate.asset_id, "x": pos.x, "z": pos.y, "scale": candidate.scale})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.z < b.z)
	return out


## Weighted asset pick with a uniform scale of the asset's range and its scaled footprint radius.
static func _candidate(rng: RandomNumberGenerator, items: Array[Dictionary], total: float,
		catalog: AssetCatalog) -> Dictionary:
	var roll := rng.randf() * total
	var chosen := items[items.size() - 1]
	for item in items:
		roll -= float(item.weight)
		if roll <= 0.0:
			chosen = item
			break
	var asset := catalog.get_asset(str(chosen.asset_id))
	var scale := rng.randf_range(asset.scale_min, asset.scale_max)
	return {"asset_id": chosen.asset_id, "scale": scale, "radius": asset.footprint_radius_m * scale}


static func _is_free(grid: Dictionary, placed: Array[Dictionary], pos: Vector2, min_dist: float) -> bool:
	var reach := ceili(min_dist / CELL)
	var cx := floori(pos.x / CELL)
	var cy := floori(pos.y / CELL)
	for dx in range(-reach, reach + 1):
		for dy in range(-reach, reach + 1):
			for index: int in grid.get(Vector2i(cx + dx, cy + dy), []):
				var other := placed[index]
				if Vector2(float(other.x), float(other.z)).distance_to(pos) < min_dist:
					return false
	return true
