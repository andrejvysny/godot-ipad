class_name WorldLayers
extends Node3D
## Scene layers drawn from document data on top of the terrain (scatter now; the path renderer
## joins later). The session and the Mac consumer both own one; it never mutates the document.

var scatter := ScatterRenderer.new()


func setup(catalog: AssetCatalog) -> void:
	scatter.setup(catalog)
	if scatter.get_parent() == null:
		add_child(scatter)


## Draws `doc` from scratch (world open or replaced).
func rebuild(doc: WorldDocument) -> void:
	scatter.rebuild_all(doc)


## An applied or reverted change (commit, undo, redo): redraw what it touched.
func present_change(_doc: WorldDocument, change: WorldChange) -> void:
	if change.has_scatter():
		scatter.mark_all()
	elif not change.height_regions().is_empty():
		scatter.mark_rect(change.affected_world_bounds, true)


## Live stroke terrain edit: instances under `rect` re-drape.
func heights_changed(rect: Rect2) -> void:
	scatter.mark_rect(rect, true)


## ToolContext.scatter_changed target.
func scatter_changed(rect: Rect2, heights_only: bool) -> void:
	scatter.mark_rect(rect, heights_only)


func stats() -> Dictionary:
	return scatter.stats()
