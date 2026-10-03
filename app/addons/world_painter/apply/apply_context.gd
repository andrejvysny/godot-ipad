class_name ApplyContext
extends RefCounted
## Everything an Apply, a rollback, `bake --locked` and `verify` read from their surroundings: the project, the
## trusted catalog, the installed AssetStudio deliveries and (in the editor only) the unsaved-scene and importer
## state. Tests replace the pieces they need.

var project_root := ApplyLayout.project_root()
var catalog: AssetCatalog
var deliveries: ApplyDeliveries
var tree: SceneTree
## `() -> PackedStringArray` of res:// scenes with unsaved changes; empty outside the editor.
var unsaved_scenes := Callable()
## `() -> bool`: the editor importer or filesystem scan is running; false outside the editor.
var import_busy := Callable()


static func for_project(p_tree: SceneTree = null) -> ApplyContext:
	var ctx := ApplyContext.new()
	ctx.tree = p_tree if p_tree != null else Engine.get_main_loop() as SceneTree
	ctx.catalog = AssetCatalog.load_from()[0]
	ctx.deliveries = ApplyDeliveries.for_project(ctx.project_root)
	ctx.deliveries.catalog = ctx.catalog
	return ctx


func unsaved() -> PackedStringArray:
	return unsaved_scenes.call() if unsaved_scenes.is_valid() else PackedStringArray()


func importing() -> bool:
	return bool(import_busy.call()) if import_busy.is_valid() else false
