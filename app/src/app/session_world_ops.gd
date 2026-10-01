class_name SessionWorldOps
extends RefCounted
## World-level operations of EditorSession that need no scene state. Every function returns
## error strings instead of logging; callers post the messages.

const FIXTURES: Array[String] = ["flat", "gentle_hills", "stress_100"]
const NEW_WORLD_KINDS: Array[String] = ["flat", "hills"]


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


## Returns [doc, error]: a new empty world on `layout` with the trusted catalog identity, default
## rules, a fresh world id and revision 0. "flat" is height 0 everywhere; "hills" is HillsTerrain.
static func new_layout_world(layout: WorldLayout, kind: String, catalog: AssetCatalog,
		seed_value: int = HillsTerrain.DEFAULT_SEED) -> Array:
	if kind not in NEW_WORLD_KINDS:
		return [null, "Unknown world kind '%s'." % kind]
	if catalog == null:
		return [null, "No trusted catalog loaded."]
	var doc := WorldDocument.create_flat(0.0, WorldConstants.DEFAULT_CONTROL, layout)
	doc.catalog_id = catalog.catalog_id
	doc.catalog_version = catalog.catalog_version
	doc.catalog_sha256 = catalog.sha256
	doc.source_label = "new:%s-%s" % [layout.name(), kind]
	if kind == "hills":
		HillsTerrain.fill(doc, seed_value)
	return [doc, ""]


## Replaces the session's world by `make.call()` ([doc, error]) after saving the current one. Returns ""
## or the message that was posted; the current world is untouched on failure.
static func open_replacing(session: EditorSession, make: Callable, opened_text: String) -> String:
	if session.bench_active():
		session.post_message(EditorSession.BENCH_MESSAGE, true)
		return EditorSession.BENCH_MESSAGE
	var opened: Array = make.call()
	if opened[1] != "":
		session.post_message(str(opened[1]), true)
		return str(opened[1])
	session.cancel_active()
	var error := ensure_saved(session.storage, session.document)
	if error != "":
		error = "Cannot open: saving the current world failed. Your world is unchanged."
		session.post_message(error, true)
		return error
	session._replace_document(opened[0])
	session.post_message(opened_text)
	return ""


## Reset view: frames the world (a larger one whole) over its centre.
static func reset_camera(rig: OrbitCameraRig, doc: WorldDocument) -> void:
	rig.set_world_rect(doc.layout.world_rect())
	var height := doc.sample_height(0.0, 0.0)
	rig.reset_to(rig.controller.fixture_pose(0.0 if is_nan(height) else height))


## Latest recoverable world, else a fresh copy of `fixture`. Returns {doc, error, message, is_error,
## checkpoint}; checkpoint is true when the opened world is new and still unsaved.
static func open_start_world(storage: WorldStorage, catalog: AssetCatalog, fixture: String) -> Dictionary:
	var id := storage.latest_world_id()
	var note := ""
	if ObjectRecord.is_uuid(id):
		var recovered := storage.recover_latest_valid(id, catalog)
		note = "Recovery failed: %s. " % recovered.error
		if recovered.doc != null:
			var doc: WorldDocument = recovered.doc
			doc.source_label = "recovered"
			var skipped: Array = recovered.skipped
			var text := "Recovered revision %d" % doc.document_revision
			if not skipped.is_empty():
				text += ", skipped %d invalid checkpoint(s)" % skipped.size()
			return {"doc": doc, "error": "", "message": text, "is_error": false, "checkpoint": false}
	var opened := load_fixture(fixture, catalog)
	if opened[1] != "":
		return {"doc": null, "error": str(opened[1]), "message": "", "is_error": true, "checkpoint": false}
	return {"doc": opened[0], "error": "", "is_error": note != "", "checkpoint": true,
		"message": note + "Opened %s as a new world" % fixture.capitalize()}


## The ToolContext of the session's tools (document, projections, commit and cancel plumbing).
static func make_tool_context(session: EditorSession) -> ToolContext:
	var ctx := ToolContext.new()
	ctx.document = session.document
	ctx.catalog = session.catalog
	ctx.camera = session.rig.get_camera()
	ctx.terrain = session.terrain
	ctx.presenter = session.presenter
	ctx.defaults = session.defaults
	ctx.commit = session.commit
	ctx.request_cancel = func(reason: String) -> void: session.input.cancel_all(reason)
	ctx.diagnostic = session.post_message
	ctx.units_per_point = session.input.mapper.viewport_units_per_point
	ctx.stats = session.frames
	ctx.scatter_changed = session.layers.scatter_changed
	ctx.path_changed = session.layers.path_changed
	return ctx


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


## {} unless --render-bench is given; else {enabled, counts, frames} plus the optional keys warmup, seed,
## profiles, cameras (--bench-counts=0,100 --bench-frames=60 --bench-warmup=30 --bench-seed=7
## --bench-profiles=scale_100,scale_050 --bench-cameras=ground). An invalid value gives {"error": text}.
static func parse_bench_args(args: PackedStringArray) -> Dictionary:
	if not args.has("--render-bench"):
		return {}
	var out := {"enabled": true, "counts": PackedInt32Array(), "frames": 0}
	for arg in args:
		var parts := arg.split("=", true, 1)
		if parts.size() < 2 or not parts[0].begins_with("--bench-"):
			continue
		var error := _parse_bench_arg(out, parts[0], parts[1])
		if error != "":
			return {"error": error}
	return out


static func _parse_bench_arg(out: Dictionary, flag: String, value: String) -> String:
	match flag:
		"--bench-counts":
			for part in value.split(",", false):
				if not part.is_valid_int() or part.to_int() < 0:
					return "Invalid %s value '%s': expected non-negative integers." % [flag, part]
				out.counts.append(part.to_int())
		"--bench-frames", "--bench-warmup":
			var minimum := 1 if flag == "--bench-frames" else 0
			if not value.is_valid_int() or value.to_int() < minimum:
				return "Invalid %s value '%s': expected an integer >= %d." % [flag, value, minimum]
			out["frames" if flag == "--bench-frames" else "warmup"] = value.to_int()
		"--bench-seed":
			if not value.is_valid_int():
				return "Invalid %s value '%s': expected an integer." % [flag, value]
			out["seed"] = value.to_int()
		"--bench-profiles":
			return _parse_bench_names(out, "profiles", flag, value, BenchPlan.PROFILES)
		"--bench-cameras":
			return _parse_bench_names(out, "cameras", flag, value, BenchPlan.CAMERAS)
	return ""


static func _parse_bench_names(out: Dictionary, key: String, flag: String, value: String, allowed: Array[String]) -> String:
	var names: Array[String] = []
	for part in value.split(",", false):
		if part not in allowed:
			return "Invalid %s value '%s': expected %s." % [flag, part, ", ".join(allowed)]
		names.append(part)
	if names.is_empty():
		return "Invalid %s: no names given." % flag
	out[key] = names
	return ""


## Creates, attaches and starts a bench runner; posts and returns the error, "" on success.
static func start_bench(session: EditorSession, path: String, counts: PackedInt32Array, frames: int,
		options: Dictionary) -> String:
	var bench := make_bench(path, counts, frames, options)
	var error := "Render bench module is missing." if bench == null else ""
	if bench != null:
		session.add_child(bench)
		error = bench.call("start", session)
		if error != "":
			bench.queue_free()
	if error != "":
		session.post_message(error, true)
	return error


## Loads the bench runner by path (it is optional tooling) with overrides applied; null if missing.
## options: warmup, seed, profiles, cameras (see parse_bench_args).
static func make_bench(path: String, counts: PackedInt32Array, frames: int, options := {}) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var bench := load(path).new() as Node
	if not counts.is_empty():
		bench.set("counts", counts)
	if frames > 0:
		bench.set("measure_frames", frames)
	for key in ["warmup", "seed", "profiles", "cameras"]:
		if options.has(key):
			bench.set({"warmup": "warmup_frames", "seed": "rng_seed"}.get(key, key), options[key])
	return bench


## Applies an applied or reverted change to the projections (terrain, objects, layers, selection).
static func present_change(session: EditorSession, change: WorldChange) -> void:
	for loc: Vector2i in change.height_regions():
		session.terrain.mark_dirty(TerrainView.MAP_HEIGHT, loc)
	for loc: Vector2i in change.control_regions():
		session.terrain.mark_dirty(TerrainView.MAP_CONTROL, loc)
	for loc: Vector2i in change.color_regions():
		session.terrain.mark_dirty(TerrainView.MAP_COLOR, loc)
	if change.has_rules():
		session.terrain.set_rules(session.document.rules)
	session.presenter.sync_objects(session.document, change.object_ids())
	session.layers.present_change(session.document, change)
	session.tools.validate_selection()


## Writes the input trace and the evidence JSON; returns "" or an error.
static func save_trace_files(session: EditorSession) -> String:
	var stamp := str(Time.get_unix_time_from_system()).replace(".", "-")
	var error := session.input.trace.save("editor-" + stamp + ".json")
	if error != "":
		return error
	var file := FileAccess.open("user://traces/editor-" + stamp + "-evidence.json", FileAccess.WRITE)
	if file == null:
		return "Evidence file could not be written."
	file.store_string(JSON.stringify(evidence(session.input, session.document, session.rig.get_camera(),
			session.frames, RenderCounters.snapshot(session.get_viewport())), "\t"))
	return ""


static func history_status(history: CommandHistory) -> Dictionary:
	return {"can_undo": history.can_undo(), "can_redo": history.can_redo(),
		"undo_label": history.peek_undo_label(), "redo_label": history.peek_redo_label(),
		"history_size": history.size(), "history_bytes": history.total_bytes(), "evicted": history.evicted_count}


static func input_status(input: InputSystem) -> Dictionary:
	return {"provider_label": input.provider_label(), "banner": input.banner_text(),
		"editing_enabled": input.editing_enabled(), "development_input": input.is_development_input(),
		"router_state": input.router.state_name(), "contacts": input.router.contacts().size(),
		"pressure_available": bool(input.active_provider().capabilities().get("pressure", false))}


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
