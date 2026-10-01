class_name WorldLayers
extends Node3D
## Scene layers drawn from document data on top of the terrain: scatter and paths. The session
## and the Mac consumer both own one; it never mutates the document.

var scatter := ScatterRenderer.new()
var paths := PathRenderer.new()


## `registry`/`cache` are the session's render registry and shared cache; without them (tests, tools) the
## scatter renderer loads the committed registry and owns a default cache.
func setup(catalog: AssetCatalog, registry: RenderAssetRegistry = null, cache: RenderAssetCache = null,
		config: RenderConfig = null) -> void:
	scatter.setup(catalog, registry, cache, config)
	if scatter.get_parent() == null:
		add_child(scatter)
	if paths.get_parent() == null:
		add_child(paths)


## Shows the selected path's handles while the Path tool is active (editor session only).
func bind_tools(tools: ToolController) -> void:
	var update := func() -> void: set_path_selection(tools.selected_path_id(), tools.active_tool() == "path")
	tools.path_selection_changed.connect(func(_id: String) -> void: update.call())
	tools.tool_changed.connect(func(_id: String) -> void: update.call())
	update.call()


func set_path_selection(id: String, show_handles: bool) -> void:
	paths.set_selection(id, show_handles)


## Draws `doc` from scratch (world open or replaced).
func rebuild(doc: WorldDocument) -> void:
	scatter.rebuild_all(doc)
	paths.rebuild(doc)


## An applied or reverted change (commit, undo, redo): redraw what it touched.
func present_change(doc: WorldDocument, change: WorldChange) -> void:
	if not change.path_ids().is_empty():
		paths.sync(doc, change.path_ids())
	if not change.height_regions().is_empty():
		paths.mark_rect(change.affected_world_bounds)
	if change.has_scatter():
		scatter.mark_rect(doc.layout.extent_rect())
	if not change.height_regions().is_empty():
		scatter.mark_rect(change.affected_world_bounds, true)


## Live stroke terrain edit: instances under `rect` re-drape.
func heights_changed(rect: Rect2) -> void:
	scatter.mark_rect(rect, true)
	paths.mark_rect(rect)


## ToolContext.scatter_changed target.
func scatter_changed(rect: Rect2, heights_only: bool) -> void:
	scatter.mark_rect(rect, heights_only)
	if heights_only:
		paths.mark_rect(rect)


## ToolContext.path_changed target: paths edited live by a tool (draw, handle drag).
func path_changed(ids: Array) -> void:
	paths.resync(ids)


## Presentation only: hides vegetation scatter (see RenderConfig.rule_is_vegetation).
func set_vegetation_hidden(hidden: bool, rule: Dictionary) -> void:
	scatter.set_vegetation_hidden(hidden, rule)


func set_lod_profile(profile: Dictionary) -> void:
	scatter.set_lod_profile(profile)


func set_camera(camera: Camera3D) -> void:
	scatter.set_camera(camera)


func set_active_area(area: ActiveEditArea) -> void:
	scatter.set_active_area(area)


## Once per frame after the cache poll: scheduled scatter cell builds within `budget_ms`.
func service_frame(budget_ms: float = 1.0) -> void:
	scatter.service_frame(budget_ms)


## Services until no scatter work is pending, at most `max_ms`. Headless tests and the Mac consumer.
func settle_now(max_ms: float = 2000.0) -> bool:
	return scatter.settle_now(max_ms)


func stats() -> Dictionary:
	return scatter.stats()
