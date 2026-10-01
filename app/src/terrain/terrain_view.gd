class_name TerrainView
extends Node3D
## Runtime projection of WorldDocument terrain. Two implementations: TerrainAdapter (Terrain3D,
## device and Mac) and SimulatorTerrainPreview (GLES canonical-data mesh; the pinned Simulator
## engine has no Metal/Vulkan). Callers edit the document first, then mark_dirty(kind, region);
## flush() projects the edited bytes. Neither implementation owns authored data.

const MAP_HEIGHT := 0
const MAP_CONTROL := 1
const MAP_COLOR := 2
const MAP_KINDS := [MAP_HEIGHT, MAP_CONTROL, MAP_COLOR]


## Builds the projection from `doc`. Returns "" or an error.
func initialize(_doc: WorldDocument) -> String:
	return "TerrainView.initialize is not implemented"


func replace_document(doc: WorldDocument) -> String:
	return initialize(doc)


func mark_dirty(_kind: int, _loc: Vector2i) -> String:
	return "TerrainView.mark_dirty is not implemented"


## Auto-paint rules evaluated live by the renderer (docs/world-format.md 1.1).
func set_rules(_rules: TerrainRules) -> void:
	pass


## Highlights the areas the auto-paint rules currently paint rock/sand on.
func set_rule_highlight(_on: bool) -> void:
	pass


func get_rule_highlight() -> bool:
	return false


func has_pending_uploads() -> bool:
	return false


func flush() -> void:
	pass


func set_camera(_cam: Camera3D) -> void:
	pass


## Debug views (spec §18.4): "normal", "control_blend", "heightmap".
func set_debug_view(_mode: String) -> String:
	return ""


func get_debug_view() -> String:
	return "normal"


func set_region_grid(_on: bool) -> void:
	pass


## Render benchmark hook: hide the terrain and/or stop it casting shadows. Returns "" or an error.
func set_render_probe(_visible: bool, _cast_shadows: bool) -> String:
	return "render probe is not supported by this terrain view"


## Current probe state so a caller can restore exactly what it found.
func get_render_probe() -> Dictionary:
	return {"visible": true, "cast_shadows": false}


func stats() -> Dictionary:
	return {}


## Edit-to-upload age distribution; empty when the view does not track it.
func presentation_latency() -> Dictionary:
	return {}


## Terrain mesh tuning for benchmarks. Returns "" or an error.
func set_mesh_config(_mesh_size: int, _lods: int) -> String:
	return "mesh tuning is not supported by this terrain view"


## Fixed-area terrain texture preview (spec 11.4). Returns "" or an error; unsupported views error.
func set_texture_preview(_center: Vector2, _radius: float, _feather: float, _albedo: Texture2DArray,
		_normal: Texture2DArray, _layer_map: PackedInt32Array) -> String:
	return "texture preview is not supported by this terrain view"


func clear_texture_preview() -> void:
	pass


func preview_uniforms() -> Dictionary:
	return TerrainPreviewUniforms.off()


## Empty = verified. Entries starting with "NOT RUN" mean the check could not run (not a failure).
func verify_gpu() -> PackedStringArray:
	return PackedStringArray(["NOT RUN: GPU verification is not supported by this terrain view"])
