class_name BenchPlan
extends RefCounted
## Pure planning and statistics for RenderBench: step matrix, render-setting profiles, a
## deterministic synthetic object set and per-step summaries.

## Production profiles never enable shadows; the last entry is a legacy ablation (diagnostic only).
const PROFILES: Array[String] = ["scale_100", "scale_075", "scale_065", "scale_050", "legacy_shadows_diagnostic"]
const CAMERAS: Array[String] = ["overview", "ground"]
const HIDDEN_PROFILE := "terrain_hidden"
## Terrain clipmap mesh_size ablations (spec §13.3, §20.5): accepted like the scale_* names, applied and restored by RenderBench.
const MESH_ABLATIONS := {"terrain_mesh_24": 24, "terrain_mesh_32": 32}
## Explicit same-world diagnostic variants; normal production profile defaults stay unchanged.
## HLOD-only aliases the existing distance-policy baseline: projected tiers and size culling are coupled.
## Size-only combines projected tiers and size culling with HLOD disabled; these are developer interventions.
const COMPARISONS := {
	"comparison_old_distance": {"size_enabled": false, "hlod_enabled": true, "forced_view": "regional", "far_terrain": false},
	"comparison_size_only": {"size_enabled": true, "hlod_enabled": false, "forced_view": "regional", "far_terrain": false},
	"comparison_hlod_only": {"size_enabled": false, "hlod_enabled": true, "forced_view": "regional", "far_terrain": false},
	"comparison_terrain_only": {"size_enabled": true, "hlod_enabled": true, "forced_view": "terrain_only", "far_terrain": false},
	"comparison_combined": {"size_enabled": true, "hlod_enabled": true, "forced_view": "", "far_terrain": false},
	"comparison_far_terrain": {"size_enabled": true, "hlod_enabled": true, "forced_view": "", "far_terrain": true},
}
## Workloads: terrain_only (no objects), primitive (primitive catalog assets), empty_scene_diagnostic
## (terrain hidden). "vegetation" is reserved for the vegetation work package and not produced yet.
const WORKLOAD_TERRAIN_ONLY := "terrain_only"
const WORKLOAD_PRIMITIVE := "primitive"
const WORKLOAD_EMPTY := "empty_scene_diagnostic"
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"
const LODGE := "built.lodge.cabin_a"
const MARGIN_M := 4.0
const MAX_TRIES := 10
const DEFAULT_TARGET_FPS := 60.0
const MISSED_TARGET_FACTOR := 1.5


## `include_hidden` adds the terrain-hidden empty-scene diagnostics. The first step is repeated at the
## end so thermal or cache drift shows up.
static func default_steps(counts: PackedInt32Array, profiles: Array[String] = PROFILES,
		cameras: Array[String] = CAMERAS, include_hidden := true) -> Array[Dictionary]:
	var steps: Array[Dictionary] = []
	for count in counts:
		for profile in profiles:
			for camera in cameras:
				steps.append(_step(count, profile, camera))
	if include_hidden:
		for camera in cameras:
			steps.append(_step(0, HIDDEN_PROFILE, camera))
	if not steps.is_empty():
		var again := steps[0].duplicate()
		again["repeat"] = true
		again["id"] = str(again.id) + "-repeat"
		steps.append(again)
	return steps


static func _step(count: int, profile: String, camera: String) -> Dictionary:
	var workload := WORKLOAD_PRIMITIVE if count > 0 else WORKLOAD_TERRAIN_ONLY
	if profile == HIDDEN_PROFILE:
		workload = WORKLOAD_EMPTY
	return {"id": "c%d-%s-%s" % [count, profile, camera], "count": count, "profile": profile,
		"camera": camera, "workload": workload,
		"diagnostic": profile == HIDDEN_PROFILE or profile == PROFILES[PROFILES.size() - 1] or COMPARISONS.has(profile),
		"comparison_alias_of": "comparison_old_distance" if profile == "comparison_hlod_only" else "",
		"repeat": false}


static func profile_settings(profile: String) -> Dictionary:
	var s := {"shadows": false, "splits": 4, "shadow_distance": 100.0, "terrain_shadows": false,
		"scale": 1.0, "terrain_visible": true}
	match profile:
		"scale_075":
			s.scale = 0.75
		"scale_065":
			s.scale = 0.65
		"scale_050":
			s.scale = 0.5
		"legacy_shadows_diagnostic":
			s.shadows = true
			s.terrain_shadows = true
		HIDDEN_PROFILE:
			s.terrain_visible = false
	if MESH_ABLATIONS.has(profile):
		s["mesh_size"] = int(MESH_ABLATIONS[profile])
	return s


static func comparison_flags(profile: String) -> Dictionary:
	return (COMPARISONS.get(profile, {}) as Dictionary).duplicate()


## Stable lowercase UUID v4 from sha256("wp-bench:<seed>:<index>"): the same inputs always give the
## same id, so LOD or density policies that depend on ids behave identically across runs.
static func bench_object_id(seed: int, index: int) -> String:
	var b := CanonicalEncoder.sha256(("wp-bench:%d:%d" % [seed, index]).to_utf8_buffer()).slice(0, 16)
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


static func synth_objects(doc: WorldDocument, catalog: AssetCatalog, count: int, seed: int) -> Array[ObjectRecord]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[ObjectRecord] = []
	for i in count:
		var rec := _synth_one(doc, catalog, rng, bench_object_id(seed, i))
		if rec != null:
			out.append(rec)
	return out


static func _synth_one(doc: WorldDocument, catalog: AssetCatalog, rng: RandomNumberGenerator, id: String) -> ObjectRecord:
	var roll := rng.randf()
	var asset := catalog.get_asset(SPRUCE if roll < 0.7 else (BOULDER if roll < 0.95 else LODGE))
	if asset == null:
		return null
	var low := doc.layout.world_min() + Vector2(MARGIN_M, MARGIN_M)
	var high := doc.layout.world_max_sample() - Vector2(MARGIN_M, MARGIN_M)
	for _try in MAX_TRIES:
		var x := rng.randf_range(low.x, high.x)
		var z := rng.randf_range(low.y, high.y)
		var y := doc.sample_height(x, z)
		if is_nan(y):
			continue
		var rec := ObjectRecord.new()
		rec.object_id = id
		rec.binding_id = doc.assets.bundled_binding_for(asset.asset_id)
		rec.set_position(x, y, z)
		var q := Quaternion(Vector3.UP, rng.randf_range(0.0, TAU))
		rec.rotation_xyzw = PackedFloat64Array([q.x, q.y, q.z, q.w])
		rec.uniform_scale = rng.randf_range(asset.scale_min, asset.scale_max)
		rec.grounding = WorldConstants.GROUNDING_FOLLOW
		rec.height_offset_m = 0.0
		rec.origin = WorldConstants.ORIGIN_MANUAL
		return rec
	return null


## Percentile of `data`, or null (JSON null) when there is no sample: an empty set is never 0.
static func percentile_or_null(data: PackedFloat64Array, q: float) -> Variant:
	return null if data.is_empty() else FrameStats.percentile(data, q)


## frame_ms are wall-clock frame intervals. gpu_ms/cpu_ms must already hold only AVAILABLE samples;
## the statuses say why they may be empty.
static func summarize(frame_ms: PackedFloat64Array, gpu_ms: PackedFloat64Array, cpu_ms: PackedFloat64Array,
		gpu_status := RenderCounters.AVAILABLE, cpu_status := RenderCounters.AVAILABLE,
		target_fps := DEFAULT_TARGET_FPS) -> Dictionary:
	var target_ms := 1000.0 / target_fps
	var peak := 0.0
	var counts := {"over_16_7": 0, "over_33_4": 0, "missed_target": 0, "hitches_over_50_ms": 0,
		"over_100_ms": 0, "over_250_ms": 0}
	for v in frame_ms:
		peak = maxf(peak, v)
		counts.over_16_7 += 1 if v > 16.7 else 0
		counts.over_33_4 += 1 if v > 33.4 else 0
		counts.missed_target += 1 if v > MISSED_TARGET_FACTOR * target_ms else 0
		counts.hitches_over_50_ms += 1 if v > 50.0 else 0
		counts.over_100_ms += 1 if v > 100.0 else 0
		counts.over_250_ms += 1 if v > 250.0 else 0
	var out := {"frames": frame_ms.size(), "frame_interval_source": "wall_clock_proxy",
		"frame_p50_ms": FrameStats.percentile(frame_ms, 0.5), "frame_p95_ms": FrameStats.percentile(frame_ms, 0.95),
		"frame_p99_ms": FrameStats.percentile(frame_ms, 0.99), "frame_max_ms": peak, "target_ms": target_ms,
		"gpu_samples": gpu_ms.size(), "gpu_status": gpu_status,
		"cpu_samples": cpu_ms.size(), "cpu_status": cpu_status}
	out.merge(counts)
	for q in [["p50", 0.5], ["p95", 0.95], ["p99", 0.99]]:
		out["gpu_%s_ms" % q[0]] = percentile_or_null(gpu_ms, q[1])
		out["cpu_%s_ms" % q[0]] = percentile_or_null(cpu_ms, q[1])
	return out


## Static views are not comparable until scheduled visible work has drained; dynamic paths expose their pending state.
static func measurement_status(camera: String, pending: Dictionary) -> String:
	for key: String in ["objects", "terrain", "scatter", "overview", "cache"]:
		if bool(pending.get(key, false)):
			return "PENDING_ALLOWED" if camera in BenchScenarios.DYNAMIC_CAMERA_KINDS or camera in BenchScenarios.WORKLOAD_KINDS else "NOT_READY"
	return "READY"
