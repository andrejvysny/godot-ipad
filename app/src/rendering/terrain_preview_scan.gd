class_name TerrainPreviewScan
extends RefCounted
## Which terrain material slots a preview area actually shows (spec 11.2: prioritise materials used in
## the inspected area). Reads the canonical document only; auto-bit samples use the world-format rule
## evaluation (TerrainRules.material_at), manual samples their base/overlay ids and blend.

const STEP_M := 1.0
const SLOTS := 4


## Per-slot coverage weight (sum of blend weights over the sampled points inside the circle).
static func slot_weights(doc: WorldDocument, center: Vector2, radius: float) -> PackedFloat32Array:
	var weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	if doc == null or not center.is_finite() or not is_finite(radius) or radius <= 0.0:
		return weights
	var steps := int(ceil(radius / STEP_M))
	for iz in range(-steps, steps + 1):
		for ix in range(-steps, steps + 1):
			var offset := Vector2(ix, iz) * STEP_M
			if offset.length() > radius:
				continue
			_accumulate(doc, center + offset, weights)
	return weights


## Slot ids to preview: used slots by descending coverage (ties: lower id), at most `max_count`.
## Never empty: an area without any sample falls back to grass, the default material.
static func select_slots(weights: PackedFloat32Array, max_count: int) -> PackedInt32Array:
	var used: Array[int] = []
	for slot in SLOTS:
		if weights[slot] > 0.0:
			used.append(slot)
	used.sort_custom(func(a: int, b: int) -> bool:
		return weights[a] > weights[b] or (weights[a] == weights[b] and a < b))
	var out := PackedInt32Array()
	for slot in used:
		if out.size() < maxi(1, max_count):
			out.append(slot)
	if out.is_empty():
		out.append(WorldConstants.MATERIAL_GRASS)
	return out


static func _accumulate(doc: WorldDocument, p: Vector2, weights: PackedFloat32Array) -> void:
	var gx := floori(p.x / WorldConstants.SAMPLE_SPACING)
	var gz := floori(p.y / WorldConstants.SAMPLE_SPACING)
	var control := doc.get_control_at_sample(gx, gz)
	if control < 0 or is_nan(doc.sample_height(p.x, p.y)):
		return  # outside the world or a hole: nothing is rendered there
	var blend := float(ControlCodec.get_blend(control)) / 255.0
	var base := TerrainRules.material_at(doc, p.x, p.y) if (control & ControlCodec.AUTO_BIT) != 0 \
			else ControlCodec.get_base(control)
	if base >= 0 and base < SLOTS:
		weights[base] += 1.0 - blend
	var overlay := ControlCodec.get_overlay(control)
	if blend > 0.0 and overlay < SLOTS:
		weights[overlay] += blend
