class_name TerrainView
extends Node3D
## Runtime projection of WorldDocument terrain. Two implementations: TerrainAdapter (Terrain3D,
## device and Mac) and SimulatorTerrainPreview (GLES canonical-data mesh; the pinned Simulator
## engine has no Metal/Vulkan). Callers edit the document first, then mark_dirty(kind, region);
## flush() projects the edited bytes. Neither implementation owns authored data.

const MAP_HEIGHT := 0
const MAP_CONTROL := 1


## Builds the projection from `doc`. Returns "" or an error.
func initialize(_doc: WorldDocument) -> String:
	return "TerrainView.initialize is not implemented"


func replace_document(doc: WorldDocument) -> String:
	return initialize(doc)


func mark_dirty(_kind: int, _loc: Vector2i) -> String:
	return "TerrainView.mark_dirty is not implemented"


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


func stats() -> Dictionary:
	return {}


## Empty = verified. Entries starting with "NOT RUN" mean the check could not run (not a failure).
func verify_gpu() -> PackedStringArray:
	return PackedStringArray(["NOT RUN: GPU verification is not supported by this terrain view"])
