class_name BenchPlan
extends RefCounted
## Pure planning and statistics for RenderBench: step matrix, render-setting profiles, a
## deterministic synthetic object set and per-step summaries.

const PROFILES: Array[String] = ["current", "no_shadows", "lean_shadows", "scale_075", "scale_050"]
const CAMERAS: Array[String] = ["overview", "ground"]
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"
const LODGE := "built.lodge.cabin_a"
const MARGIN_M := 4.0
const MAX_TRIES := 10


static func default_steps(counts: PackedInt32Array) -> Array[Dictionary]:
	var steps: Array[Dictionary] = []
	for count in counts:
		for profile in PROFILES:
			for camera in CAMERAS:
				steps.append(_step(count, profile, camera))
	for camera in CAMERAS:
		steps.append(_step(0, "terrain_hidden", camera))
	if not steps.is_empty():
		var again := steps[0].duplicate()
		again["repeat"] = true
		again["id"] = str(again.id) + "-repeat"
		steps.append(again)
	return steps


static func _step(count: int, profile: String, camera: String) -> Dictionary:
	return {"id": "c%d-%s-%s" % [count, profile, camera], "count": count, "profile": profile,
		"camera": camera, "repeat": false}


static func profile_settings(profile: String) -> Dictionary:
	var s := {"shadows": true, "splits": 4, "shadow_distance": 100.0, "terrain_shadows": true,
		"scale": 1.0, "terrain_visible": true}
	match profile:
		"no_shadows":
			s.shadows = false
		"lean_shadows":
			s.splits = 2
			s.shadow_distance = 60.0
			s.terrain_shadows = false
		"scale_075":
			s.scale = 0.75
		"scale_050":
			s.scale = 0.5
		"terrain_hidden":
			s.terrain_visible = false
	return s


static func synth_objects(doc: WorldDocument, catalog: AssetCatalog, count: int, seed: int) -> Array[ObjectRecord]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[ObjectRecord] = []
	for i in count:
		var rec := _synth_one(doc, catalog, rng)
		if rec != null:
			out.append(rec)
	return out


static func _synth_one(doc: WorldDocument, catalog: AssetCatalog, rng: RandomNumberGenerator) -> ObjectRecord:
	var roll := rng.randf()
	var asset := catalog.get_asset(SPRUCE if roll < 0.7 else (BOULDER if roll < 0.95 else LODGE))
	if asset == null:
		return null
	var low := WorldConstants.WORLD_MIN + MARGIN_M
	var high := WorldConstants.WORLD_MAX_SAMPLE - MARGIN_M
	for _try in MAX_TRIES:
		var x := rng.randf_range(low, high)
		var z := rng.randf_range(low, high)
		var y := doc.sample_height(x, z)
		if is_nan(y):
			continue
		var rec := ObjectRecord.new()
		rec.object_id = ObjectRecord.new_uuid_v4()
		rec.asset_id = asset.asset_id
		rec.asset_version = asset.version
		rec.set_position(x, y, z)
		var q := Quaternion(Vector3.UP, rng.randf_range(0.0, TAU))
		rec.rotation_xyzw = PackedFloat64Array([q.x, q.y, q.z, q.w])
		rec.uniform_scale = rng.randf_range(asset.scale_min, asset.scale_max)
		rec.grounding = WorldConstants.GROUNDING_FOLLOW
		rec.height_offset_m = 0.0
		rec.origin = WorldConstants.ORIGIN_MANUAL
		return rec
	return null


static func summarize(frame_ms: PackedFloat64Array, gpu_ms: PackedFloat64Array, cpu_ms: PackedFloat64Array) -> Dictionary:
	var peak := 0.0
	var over_16 := 0
	var over_33 := 0
	for v in frame_ms:
		peak = maxf(peak, v)
		over_16 += 1 if v > 16.7 else 0
		over_33 += 1 if v > 33.4 else 0
	return {"frames": frame_ms.size(), "frame_p50_ms": FrameStats.percentile(frame_ms, 0.5),
		"frame_p95_ms": FrameStats.percentile(frame_ms, 0.95), "frame_p99_ms": FrameStats.percentile(frame_ms, 0.99),
		"frame_max_ms": peak, "over_16_7": over_16, "over_33_4": over_33,
		"gpu_p50_ms": FrameStats.percentile(gpu_ms, 0.5), "gpu_p95_ms": FrameStats.percentile(gpu_ms, 0.95),
		"cpu_p50_ms": FrameStats.percentile(cpu_ms, 0.5), "cpu_p95_ms": FrameStats.percentile(cpu_ms, 0.95)}
