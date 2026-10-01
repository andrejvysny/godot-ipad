class_name HillsTerrain
extends RefCounted
## Deterministic gentle relief for newly created worlds. A small seeded random height grid is
## upsampled over the whole sample extent with Image bicubic resizing (native code), so a 1 km
## world needs no per-sample GDScript loop. Bicubic overshoot of a grid inside [MIN_M, MAX_M]
## stays far inside the format's [HEIGHT_MIN, HEIGHT_MAX] range.

const DEFAULT_SEED := 20261001
const GRID_CELL_SAMPLES := 128  # one grid cell spans 64 m
const MIN_M := -4.0
const MAX_M := 18.0


## Replaces every region's heights in `doc` (control and tint are left as they are).
static func fill(doc: WorldDocument, seed_value: int) -> void:
	var layout := doc.layout
	var side := layout.region_count * WorldConstants.REGION_SAMPLES  # samples per axis
	var nodes := Vector2i(side.x / GRID_CELL_SAMPLES + 1, side.y / GRID_CELL_SAMPLES + 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var grid := Image.create_empty(nodes.x, nodes.y, false, Image.FORMAT_RF)
	for z in nodes.y:
		for x in nodes.x:
			grid.set_pixel(x, z, Color(rng.randf_range(MIN_M, MAX_M), 0.0, 0.0))
	# One extra row and column keeps the grid corners on the sample extent edges; it is cropped away.
	grid.resize(side.x + 1, side.y + 1, Image.INTERPOLATE_CUBIC)
	var full := grid.get_region(Rect2i(0, 0, side.x, side.y))
	var rs := WorldConstants.REGION_SAMPLES
	for loc in layout.region_locations():
		var origin := (loc - layout.min_region) * rs
		var block := full.get_region(Rect2i(origin.x, origin.y, rs, rs))
		doc.get_region(loc).heights = block.get_data().to_float32_array()
