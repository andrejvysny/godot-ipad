class_name TerrainPreviewUniforms
extends RefCounted
## Shader uniforms of the fixed-area terrain texture preview (world_terrain.gdshader, spec 11.4).
## preview_layer maps material slots 0..3 to a preview array layer, -1 = low tier only.

const SLOTS := 4
const MAX_FEATHER_M := 8.0


static func off() -> Dictionary:
	return {"preview_enabled": false, "preview_area": Vector4(0.0, 0.0, 0.0, 1.5),
		"preview_layer": Vector4i(-1, -1, -1, -1), "preview_albedo_array": null, "preview_normal_array": null}


## "" when the inputs describe a bindable preview.
static func validate(center: Vector2, radius: float, feather: float, albedo: Texture2DArray,
		normal: Texture2DArray, layer_map: PackedInt32Array) -> String:
	if not center.is_finite() or not is_finite(radius) or radius <= 0.0:
		return "preview area needs a finite centre and a positive radius"
	if not is_finite(feather) or feather < 0.0 or feather > MAX_FEATHER_M or feather > radius:
		return "preview feather must be within [0, min(radius, %s)] m" % MAX_FEATHER_M
	if albedo == null or normal == null:
		return "preview arrays are missing"
	if albedo.get_layers() != normal.get_layers() or albedo.get_layers() < 1:
		return "preview albedo and normal arrays must have the same layer count"
	if layer_map.size() != SLOTS:
		return "preview layer map needs %d entries" % SLOTS
	var used := false
	for layer in layer_map:
		if layer < -1 or layer >= albedo.get_layers():
			return "preview layer %d is outside the array" % layer
		used = used or layer >= 0
	return "" if used else "preview layer map selects no layer"


static func build(center: Vector2, radius: float, feather: float, albedo: Texture2DArray,
		normal: Texture2DArray, layer_map: PackedInt32Array) -> Dictionary:
	return {"preview_enabled": true, "preview_area": Vector4(center.x, center.y, radius, feather),
		"preview_layer": Vector4i(layer_map[0], layer_map[1], layer_map[2], layer_map[3]),
		"preview_albedo_array": albedo, "preview_normal_array": normal}
