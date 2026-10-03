class_name BakeContext
extends RefCounted
## Inputs and counters of one bake (ADR 0017 A4). `base_res` is the directory that receives generated/; scenes
## and resources refer to each other through that path, so a staged bake is normalized to its final directory
## afterwards (ApplyTransaction).

const TERRAIN_COLLISION := {"disabled": 0, "dynamic": 1, "full": 3}

var doc: WorldDocument
var base_res := ""
var deliveries: ApplyDeliveries
var tree: SceneTree
## "dynamic" (Terrain3D collision around the game camera), "full" or "disabled".
var terrain_collision := "dynamic"
## Binding ids whose scatter gets static collision (consumer policy opt-in; default none).
var collision_bindings := PackedStringArray()
## Consumer material hook (project setting world_painter/apply/material_mapper); null keeps every material.
var mapper: WPMaterialMapper
var mapper_error := ""
## world_id, authored_hash, source_snapshot_hash and generation_id written into the scene root's metadata.
var identity := {}
var stats := {"regions": 0, "objects": 0, "scatter_nodes": 0, "scatter_instances": {}, "scatter_skipped": 0,
	"paths": 0, "paths_skipped": 0, "seconds": {}}


func _init(p_doc: WorldDocument, p_base_res: String, p_deliveries: ApplyDeliveries) -> void:
	doc = p_doc
	base_res = p_base_res
	deliveries = p_deliveries
	tree = Engine.get_main_loop() as SceneTree


func generated_res() -> String:
	return base_res.path_join(ApplyLayout.GENERATED_DIR)


func generated_abs() -> String:
	return ProjectSettings.globalize_path(generated_res())


func scene_res() -> String:
	return generated_res().path_join(ApplyLayout.WORLD_SCENE)


## Applies the consumer profile settings (SnapshotIdentity.consumer_profile()).
func use_profile(profile: Dictionary) -> void:
	terrain_collision = str(profile.get("terrain_collision", "dynamic"))
	collision_bindings = PackedStringArray(profile.get("scatter_collision_bindings", []))
	var loaded := WPMaterialMapper.from_setting()
	mapper = loaded[0]
	mapper_error = loaded[1]


func time(label: String, started_usec: int) -> void:
	stats.seconds[label] = snappedf(float(Time.get_ticks_usec() - started_usec) / 1000000.0, 0.001)
