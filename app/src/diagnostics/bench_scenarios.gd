class_name BenchScenarios
extends RefCounted
## Scenario table and step planning of the representative render benchmarks (spec §20.1, §20.2, §20.3).
## Pure data: BenchWorlds builds the documents, BenchCameraPaths the poses, BenchWorkloads the edits.

const TERRAIN_ONLY_LEGACY := "terrain_only_legacy"
const TERRAIN_ONLY_1KM := "terrain_only_1km"
const PRIMITIVE_1K := "primitive_1k"
const PRIMITIVE_5K := "primitive_5k"
const GEOMETRY_FOREST_10K := "geometry_forest_10k"
const CARD_FOREST_10K := "card_forest_10k"
const MIXED_WORLD_10K := "mixed_world_10k"
const MIXED_WORLD_50K := "mixed_world_50k"
const GRASS_50K := "grass_50k"
const ASSET_DIVERSITY := "asset_diversity"

const NAMES: Array[String] = [TERRAIN_ONLY_LEGACY, TERRAIN_ONLY_1KM, PRIMITIVE_1K, PRIMITIVE_5K, GEOMETRY_FOREST_10K,
	CARD_FOREST_10K, MIXED_WORLD_10K, MIXED_WORLD_50K, GRASS_50K]
## Listed in every report instead of being faked (spec §20.1: 1/8/16/32 resource families needed).
const NOT_RUN := {ASSET_DIVERSITY: "needs 8-32 prepared resource/material families; only 6 bench assets are prepared"}
const CAMERA_KINDS: Array[String] = ["overview", "focus", "shallow", "canopy", "path", "travel"]
const WORKLOAD_KINDS: Array[String] = ["edit_sculpt", "edit_move", "preview_cycles"]
const BENCH_PROFILES: Array[String] = ["performance"]
const SUSTAINED_SCENARIO := MIXED_WORLD_10K
const SUSTAINED_PROFILE := "performance"
const SUSTAINED_SEQUENCE: Array[String] = ["overview", "focus", "path", "edit_sculpt", "preview_cycles", "travel"]

const GRASS := "bench.cover.grass_cards"
const MIX_MIXED := [["bench.tree.broadleaf_geo", 0.35], ["bench.tree.pine_cards", 0.35],
	["bench.shrub.bush_cards", 0.18], ["bench.rock.slab_a", 0.10], ["bench.structure.tower_a", 0.02]]


static func _joined(a: Array[String], b: Array[String]) -> Array[String]:
	var out: Array[String] = []
	out.append_array(a)
	out.append_array(b)
	return out


static func kinds() -> Array[String]:
	return _joined(CAMERA_KINDS, WORKLOAD_KINDS)


## Names accepted by --bench-profiles / --bench-cameras / --bench-scenarios (asset_diversity is accepted and
## reported NOT_RUN).
static func profile_names() -> Array[String]:
	var ablations: Array[String] = []
	ablations.append_array(BenchPlan.MESH_ABLATIONS.keys())
	return _joined(_joined(BenchPlan.PROFILES, ablations), RenderConfig.PROFILE_NAMES)


static func camera_names() -> Array[String]:
	return _joined(BenchPlan.CAMERAS, kinds())


static func scenario_names() -> Array[String]:
	return _joined(NAMES, [ASSET_DIVERSITY])


static func is_scenario(name: String) -> bool:
	return name in NAMES


## "world": legacy | km1; "catalog": editor | bench (which logical catalog presents it); "primitive": N editor
## objects; "mix": [[asset_id, fraction]] manual records; "objects"/"scatter": exact counts; "patches": forest
## patch count.
static func definition(name: String) -> Dictionary:
	match name:
		TERRAIN_ONLY_LEGACY:
			return {"world": "legacy", "catalog": "editor", "objects": 0, "scatter": 0}
		TERRAIN_ONLY_1KM:
			return {"world": "km1", "catalog": "bench", "objects": 0, "scatter": 0}
		PRIMITIVE_1K:
			return {"world": "legacy", "catalog": "editor", "primitive": 1000, "objects": 1000, "scatter": 0}
		PRIMITIVE_5K:
			return {"world": "legacy", "catalog": "editor", "primitive": 5000, "objects": 5000, "scatter": 0}
		GEOMETRY_FOREST_10K:
			return {"world": "km1", "catalog": "bench", "objects": 10000, "scatter": 0, "patches": 24,
				"mix": [["bench.tree.broadleaf_geo", 1.0]]}
		CARD_FOREST_10K:
			return {"world": "km1", "catalog": "bench", "objects": 10000, "scatter": 0, "patches": 24,
				"mix": [["bench.tree.pine_cards", 1.0]]}
		MIXED_WORLD_10K:
			return {"world": "km1", "catalog": "bench", "objects": 10000, "scatter": 20000, "patches": 24, "mix": MIX_MIXED}
		MIXED_WORLD_50K:
			return {"world": "km1", "catalog": "bench", "objects": 50000, "scatter": 50000, "patches": 40, "mix": MIX_MIXED}
		GRASS_50K:
			return {"world": "km1", "catalog": "bench", "objects": 0, "scatter": 50000, "patches": 60}
	return {}


## Camera paths and workloads that make sense for a scenario.
static func default_kinds(name: String) -> Array[String]:
	var def := definition(name)
	var out: Array[String] = []
	for kind in kinds():
		var needs_objects := kind in ["shallow", "canopy", "edit_move"]
		if needs_objects and int(def.get("objects", 0)) == 0:
			continue
		out.append(kind)
	return out


## scenario x profile x kind. `profiles` may mix real profiles and legacy ablation names; `only_kinds` (may be
## empty) filters kinds. The first step is repeated at the end so thermal or cache drift shows up.
static func plan_steps(scenarios: Array[String], profiles: Array[String], only_kinds: Array[String]) -> Array[Dictionary]:
	var steps: Array[Dictionary] = []
	for scenario in scenarios:
		for profile in profiles:
			for kind in default_kinds(scenario):
				if only_kinds.is_empty() or kind in only_kinds:
					steps.append(step(scenario, profile, kind))
	if not steps.is_empty():
		var again := steps[0].duplicate()
		again["repeat"] = true
		again["id"] = str(again.id) + "-repeat"
		steps.append(again)
	return steps


static func step(scenario: String, profile: String, kind: String) -> Dictionary:
	var workload := kind if kind in WORKLOAD_KINDS else "camera_path"
	return {"id": "%s-%s-%s" % [scenario, profile, kind], "scenario": scenario, "profile": profile, "camera": kind,
		"workload": workload, "diagnostic": profile == BenchPlan.PROFILES[BenchPlan.PROFILES.size() - 1], "repeat": false}


static func is_real_profile(profile: String) -> bool:
	return RenderConfig.PROFILE_NAMES.has(profile)
