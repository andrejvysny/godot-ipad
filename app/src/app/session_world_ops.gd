class_name SessionWorldOps
extends RefCounted
## World-level operations of EditorSession that need no scene state. Every function returns
## error strings instead of logging; callers post the messages.

const FIXTURES: Array[String] = ["flat", "gentle_hills", "stress_100"]


## Returns [doc, error]. The result is a new working copy: fresh world id, revision 0.
static func load_fixture(fixture: String, catalog: AssetCatalog) -> Array:
	if fixture not in FIXTURES:
		return [null, "Unknown fixture '%s'." % fixture]
	var loaded := WorldCodec.read_generation("res://fixtures/" + fixture, catalog)
	if loaded[1] != "":
		return [null, "Fixture '%s' is invalid: %s" % [fixture, loaded[1]]]
	var doc: WorldDocument = loaded[0]
	doc.world_id = ObjectRecord.new_uuid_v4()
	doc.document_revision = 0
	doc.source_label = "fixture:" + fixture
	return [doc, ""]


## Makes the active revision durable. Returns "" or an error.
static func ensure_saved(storage: WorldStorage, doc: WorldDocument) -> String:
	if storage.status_text(doc.document_revision) == "Saved revision %d" % doc.document_revision:
		return ""
	var res := storage.checkpoint_now(doc)
	if not res.durable:
		return str(res.error) if str(res.error) != "" else "checkpoint was not durable"
	return ""


## Exports the durable revision, then re-imports the package and compares authored hashes.
static func export_verified(storage: WorldStorage, doc: WorldDocument, catalog: AssetCatalog) -> Dictionary:
	var failed := {"path": "", "error": ""}
	failed.error = ensure_saved(storage, doc)
	if failed.error != "":
		failed.error = "Export needs a saved world: " + str(failed.error)
		return failed
	var exported := storage.export_latest(doc.world_id, catalog)
	if exported.error != "":
		failed.error = "Export failed: " + str(exported.error)
		return failed
	var imported := WorldPackage.import_package(exported.path, catalog, storage.import_tmp_root)
	if imported[1] != "":
		failed.error = "Export verification failed: " + str(imported[1])
		return failed
	if CanonicalEncoder.authored_hash(imported[0]) != CanonicalEncoder.authored_hash(doc):
		failed.error = "Export verification failed: package content differs from the active world."
		return failed
	return {"path": exported.path, "error": ""}


static func evidence(input: InputSystem, doc: WorldDocument, camera: Camera3D, frames: FrameStats,
		render: Dictionary) -> Dictionary:
	return {"device_gate": "NOT RUN", "build": WorldCodec.default_created_with(),
		"fingerprint": JSON.parse_string(FileAccess.get_file_as_string("res://config/build_fingerprint.json")),
		"provider": input.active_provider().diagnostics(), "stats": input.stats(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"camera_transform": str(camera.transform), "timing": frames.snapshot(),
		"authored_hash": CanonicalEncoder.authored_hash(doc), "revision": doc.document_revision,
		"object_count": doc.objects.size(), "trace_dropped": input.trace.dropped,
		"render": render}


## {} unless --render-bench is given; else {enabled, counts, frames} (--bench-counts=0,100 --bench-frames=60).
static func parse_bench_args(args: PackedStringArray) -> Dictionary:
	if not args.has("--render-bench"):
		return {}
	var out := {"enabled": true, "counts": PackedInt32Array(), "frames": 0}
	for arg in args:
		if arg.begins_with("--bench-counts="):
			for part in arg.trim_prefix("--bench-counts=").split(",", false):
				out.counts.append(maxi(0, part.to_int()))
		elif arg.begins_with("--bench-frames="):
			out.frames = arg.trim_prefix("--bench-frames=").to_int()
	return out


## Loads the bench runner by path (it is optional tooling) with overrides applied; null if missing.
static func make_bench(path: String, counts: PackedInt32Array, frames: int) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var bench := load(path).new() as Node
	if not counts.is_empty():
		bench.set("counts", counts)
	if frames > 0:
		bench.set("measure_frames", frames)
	return bench


static func hit_text(hit: TerrainHit) -> String:
	if not hit.ok:
		return "no hit"
	return "%.1f, %.1f, %.1f · region (%d, %d)" % [hit.position.x, hit.position.y, hit.position.z,
		hit.region.x, hit.region.y]


## {text, is_error} for TerrainView.verify_gpu() output.
static func gpu_report(diffs: PackedStringArray) -> Dictionary:
	if diffs.is_empty():
		return {"text": "GPU terrain matches the document.", "is_error": false}
	if diffs[0].begins_with("NOT RUN"):
		return {"text": "GPU terrain check " + diffs[0], "is_error": false}
	return {"text": "GPU terrain differs: %s (+%d more)" % [diffs[0], diffs.size() - 1], "is_error": true}


## Copy of a StrokeProbe result with the longest frame gap of that stroke merged in.
static func with_gap(stroke: Dictionary, max_gap_ms: float) -> Dictionary:
	var out := stroke.duplicate()
	if not out.is_empty():
		out["max_gap_ms"] = max_gap_ms
	return out


## Tool-model keys of status(): mode, tool (id), inverted, armed_asset, picking_height.
static func tool_status(tools: ToolController) -> Dictionary:
	return {"mode": tools.mode(), "tool": tools.active_tool(), "inverted": tools.inverted(),
		"armed_asset": tools.armed_asset(), "picking_height": tools.is_picking_height()}


## Mac development keys (docs/editor-v2.md §9): D invert, [ / ] radius -/+ 1 m, Q/E rotate the ghost,
## Esc disarms. True when the key was consumed; Esc is not (the provider's cancel still runs).
static func dev_key(tools: ToolController, key: int) -> bool:
	match key:
		KEY_D:
			tools.set_inverted(not tools.inverted())
		KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
			var mode := tools.mode()
			tools.set_setting(mode, "radius", float(tools.settings(mode).radius) + (1.0 if key == KEY_BRACKETRIGHT else -1.0))
		KEY_Q:
			tools.rotate_ghost(-15.0)
		KEY_E:
			tools.rotate_ghost(15.0)
		KEY_ESCAPE:
			tools.dismiss()
			return false
		_:
			return false
	return true


## Simulator-only keys: P toggles probe/UI and fingers, arrows drag the camera. Cancels any
## contact first so a key never lands mid-stroke.
static func simulator_key(input: InputSystem, viewport: Viewport, key: int) -> void:
	var provider := input.active_provider() as SimulatorInputProvider
	if provider == null:
		return
	if key == KEY_P:
		input.cancel_all("explicit")
		provider.pencil_mode = not provider.pencil_mode
	elif key in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		input.cancel_all("explicit")
		var direction := Vector2.LEFT if key == KEY_LEFT else Vector2.RIGHT
		if key in [KEY_UP, KEY_DOWN]:
			direction = Vector2.UP if key == KEY_UP else Vector2.DOWN
		var center := viewport.get_visible_rect().size * 0.75
		provider.queue_camera_drag(input.mapper.unmap(center), input.mapper.unmap(center + direction * 120))
