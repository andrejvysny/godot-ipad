class_name ScatterResources
extends RenderWorldResources
## RenderWorldResources for the scatter layer: its own owner ("scatter:<epoch>") and its own generation token
## so an object-world epoch change (token "world_epoch") never cancels scatter requests, nor the reverse.


func owner() -> String:
	return "scatter:%d" % epoch


func tokens() -> Dictionary:
	return {"scatter_epoch": epoch}


func next_epoch() -> void:
	cache.cancel_generation("scatter_epoch", epoch)
	cache.release(owner())
	epoch += 1
	_requested.clear()
	awaiting.clear()


## A key that fails the structural scatter budget stays a placeholder box in the scatter layer.
func rep_for(asset_id: String, wanted_role: String, priority: int) -> String:
	if not registry.is_scatter_eligible(asset_id):
		return PLACEHOLDER
	return super(asset_id, wanted_role, priority)
